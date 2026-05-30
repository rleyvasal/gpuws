import base64
import json
import os
import re
import shutil
import socket
import subprocess
import sys
import time
from pathlib import Path

from IPython.core.magic import register_line_cell_magic
from IPython.display import HTML, Image, clear_output, display
from jupyter_client import BlockingKernelClient

# ── Configuration ─────────────────────────────────────────────────────────────
CONFIG_PATH = Path.home() / ".config" / "gpuws" / "client.json"
_cfg = json.loads(CONFIG_PATH.read_text()) if CONFIG_PATH.exists() else {}

LINUX_USER = _cfg["linux_user"]
WINDOWS_USER = _cfg.get("windows_user", "")
IDENTITY_FILE = _cfg["identity_file"]
LINUX_SSH_PORT = _cfg["linux_ssh_port"]
WINDOWS_SSH_PORT = _cfg.get("windows_ssh_port", 22)
CF_HOSTNAME_LINUX = _cfg["cf_hostname_linux"]
CF_HOSTNAME_WIN = _cfg.get("cf_hostname_win", "")
VENV_PATH = _cfg["venv_path"]
VENV_PYTHON = f"{VENV_PATH}/bin/python"
KERNEL_NAME = _cfg["default_name"]
KERNEL_WORK_DIR = _cfg["work_dir"]
KERNEL_MANAGER = f"/home/{LINUX_USER}/bin/kernel-manager.sh"
KERNEL_RUNTIME = f"~/.local/share/jupyter/runtime/kernel-{KERNEL_NAME}.json"

del _cfg

# ── Helpers ───────────────────────────────────────────────────────────────────
ANSI_RE = re.compile(r"\x1b\[[0-9;]*[a-zA-Z]|\x1b\[[0-9;]*$|\x1b$")


def _run(cmd, check=True, capture_output=False):
    return subprocess.run(
        cmd,
        shell=True,
        check=check,
        capture_output=capture_output,
        text=True,
    )


def _ssh_linux(cmd, capture_output=False):
    return _run(f"ssh gpuws-linux {json.dumps(cmd)}", capture_output=capture_output)


def _ssh_win(cmd, capture_output=False):
    return _run(f"ssh gpuws-windows {json.dumps(cmd)}", capture_output=capture_output)


def _strip_ansi(text):
    return ANSI_RE.sub("", text)


# ── SSH / Cloudflared Checks ──────────────────────────────────────────────────
def install_cloudflared():
    if _run("which cloudflared", check=False).returncode == 0:
        return
    if sys.platform == "darwin":
        print("Please install cloudflared: brew install cloudflared")
        raise SystemExit(1)
    stable_path = Path.home() / ".local" / "bin" / "cloudflared"
    stable_path.parent.mkdir(parents=True, exist_ok=True)
    _run(
        "curl -fsSL "
        "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 "
        f"-o {stable_path} && chmod +x {stable_path}"
    )


def ensure_ssh_aliases():
    ssh_config = Path.home() / ".ssh" / "config"
    content = ssh_config.read_text() if ssh_config.exists() else ""
    missing_linux = "Host gpuws-linux" not in content
    missing_windows = CF_HOSTNAME_WIN and WINDOWS_USER and "Host gpuws-windows" not in content
    if missing_linux or missing_windows:
        print("SSH aliases missing. Run the generated client installer first.")
        raise RuntimeError("Missing gpuws SSH aliases")


# ── Kernel Management ─────────────────────────────────────────────────────────
def ensure_kernel():
    _ssh_linux(f'{KERNEL_MANAGER} create "{KERNEL_NAME}" "{VENV_PYTHON}" "{KERNEL_WORK_DIR}"')


def touch_kernel():
    _ssh_linux(f'{KERNEL_MANAGER} touch "{KERNEL_NAME}"', capture_output=False)


def fetch_kernel_info():
    result = _ssh_linux(f"cat {KERNEL_RUNTIME}", capture_output=True)
    return json.loads(result.stdout)


def start_port_forwarding(kernel_info):
    ports = [kernel_info[k] for k in ("shell_port", "iopub_port", "stdin_port", "control_port", "hb_port")]
    args = ["ssh", "-N"]
    for port in ports:
        args.extend(["-L", f"{port}:127.0.0.1:{port}"])
    args.append("gpuws-linux")
    return subprocess.Popen(args)


# ── Output Display ────────────────────────────────────────────────────────────
def _handle_output(msg, display_handles, progress_handle_box):
    msg_type = msg["msg_type"]
    content = msg.get("content", {})

    if msg_type == "stream":
        text = _strip_ansi(content.get("text", ""))
        if re.search(r"\r(?!\n)", text):
            parts = text.split("\r")
            last_progress = None
            for p in parts:
                p = p.strip()
                if not p:
                    continue
                if p.startswith(("+", "-")):
                    progress_handle_box[0] = None
                    print(p)
                else:
                    last_progress = p
            if last_progress is not None:
                if progress_handle_box[0] is None:
                    progress_handle_box[0] = display(HTML(f"<pre>{last_progress}</pre>"), display_id=True)
                else:
                    progress_handle_box[0].update(HTML(f"<pre>{last_progress}</pre>"))
            return
        print(text, end="")

    elif msg_type == "error":
        tb = "\n".join(content.get("traceback", []))
        display(HTML(f"<pre>{_strip_ansi(tb)}</pre>"))

    elif msg_type == "clear_output":
        clear_output(wait=content.get("wait", False))

    elif msg_type in ("display_data", "update_display_data", "execute_result"):
        data = content.get("data", {})
        did = content.get("transient", {}).get("display_id")
        if "text/html" in data:
            html = HTML(data["text/html"])
            if msg_type == "update_display_data" and did in display_handles:
                display_handles[did].update(html)
            else:
                handle = display(html, display_id=did or True)
                if did:
                    display_handles[did] = handle
        elif "image/png" in data:
            display(Image(base64.b64decode(data["image/png"])))
        elif "image/jpeg" in data:
            display(Image(base64.b64decode(data["image/jpeg"])))
        elif "image/svg+xml" in data:
            display(HTML(data["image/svg+xml"]))
        elif "text/plain" in data:
            print(data["text/plain"])


# ── Remote Execution Manager ──────────────────────────────────────────────────
class RemoteExecutionManager:
    _LOCAL_PREFIXES = (
        "%remote_on",
        "%remote_off",
        "%local",
        "%%local",
        "%remote",
        "%%remote",
        "%restart_windows",
        "%restart_kernel",
        "%kernel_status",
        "%%kernel_status",
        "remote_on(",
        "remote_off(",
        "kernel_status(",
        "await call_tool(",
    )

    def __init__(self):
        self.remote_kc = None
        self._remote_active = False
        self._display_handles = {}
        self._tunnel_proc = None
        self._progress_handle_box = [None]

    def _test_connection(self, kernel_info, timeout=3):
        try:
            sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            sock.settimeout(timeout)
            result = sock.connect_ex(("127.0.0.1", kernel_info["shell_port"]))
            sock.close()
            return result == 0
        except Exception:
            return False

    def _connect_kernel(self, kernel_info):
        kc = BlockingKernelClient()
        local_info = dict(kernel_info, ip="127.0.0.1")
        kc.load_connection_info(local_info)
        kc.start_channels()
        kc.wait_for_ready(timeout=30)
        return kc

    def _transform_cell(self, lines):
        code = "".join(lines)
        stripped = code.strip()
        if stripped.startswith(self._LOCAL_PREFIXES) or "get_ipython()" in code:
            return lines
        self._pending_code = code
        return ["_exec_mgr.execute_remote(_exec_mgr._pending_code)\n"]

    def setup_remote(self):
        if self.remote_kc is not None:
            try:
                self.remote_kc.stop_channels()
            except Exception:
                pass
            self.remote_kc = None

        if not CONFIG_PATH.exists():
            print(f"Config not found at {CONFIG_PATH}")
            return False

        install_cloudflared()
        ensure_ssh_aliases()
        _run("ssh -o StrictHostKeyChecking=accept-new gpuws-linux echo SSH_OK", check=False)

        ensure_kernel()
        kernel_info = fetch_kernel_info()

        if self._test_connection(kernel_info):
            print(f"Reusing existing tunnel to remote kernel '{KERNEL_NAME}'")
        else:
            if self._tunnel_proc and self._tunnel_proc.poll() is None:
                self._tunnel_proc.terminate()
            self._tunnel_proc = start_port_forwarding(kernel_info)
            time.sleep(2)

        self.remote_kc = self._connect_kernel(kernel_info)
        touch_kernel()
        print(f"Remote kernel '{KERNEL_NAME}' ready")
        return True

    def shutdown_remote(self):
        if self.remote_kc is not None:
            try:
                self.remote_kc.stop_channels()
            except Exception:
                pass
        self.remote_kc = None
        if self._tunnel_proc and self._tunnel_proc.poll() is None:
            self._tunnel_proc.terminate()
        self._tunnel_proc = None
        self._display_handles.clear()

    def _output_hook(self, msg):
        _handle_output(msg, self._display_handles, self._progress_handle_box)

    def execute_remote(self, code, verbose=False):
        self._progress_handle_box[0] = None
        if self.remote_kc is None:
            raise RuntimeError("Remote kernel not connected. Run %remote first.")
        touch_kernel()
        try:
            reply = self.remote_kc.execute_interactive(code=code, output_hook=self._output_hook)
        except KeyboardInterrupt:
            print("Interrupted locally, stopping remote job...")
            msg = self.remote_kc.session.msg("interrupt_request")
            self.remote_kc.control_channel.send(msg)
            print("Remote job interrupted")
            raise
        self.remote_kc.last_result = reply
        if verbose:
            return reply

    def remote_on(self):
        if self._remote_active:
            print("Already executing remotely")
            return
        if self.remote_kc is None:
            raise RuntimeError("Remote kernel not connected. Run %remote first.")
        ip = get_ipython()
        ip.input_transformers_cleanup[:] = [
            f
            for f in ip.input_transformers_cleanup
            if not (callable(f) and getattr(f, "__func__", None) and f.__func__.__name__ == "_transform_cell")
        ]
        ip.input_transformers_cleanup.append(self._transform_cell)
        self._remote_active = True
        print("Remote execution enabled — all cells now run remotely")

    def remote_off(self):
        if not self._remote_active:
            print("Already executing locally")
            return
        ip = get_ipython()
        ip.input_transformers_cleanup[:] = [
            f
            for f in ip.input_transformers_cleanup
            if not (callable(f) and getattr(f, "__func__", None) and f.__func__.__name__ == "_transform_cell")
        ]
        self._remote_active = False
        print("Remote execution disabled — cells now run locally")

    def restart_kernel(self):
        if self.remote_kc is None:
            print("No remote kernel connected")
            return
        self.remote_kc.stop_channels()
        self.remote_kc = None
        _ssh_linux(f'{KERNEL_MANAGER} restart "{KERNEL_NAME}"')
        time.sleep(2)
        kernel_info = fetch_kernel_info()
        self.remote_kc = self._connect_kernel(kernel_info)
        touch_kernel()
        print(f"Remote kernel '{KERNEL_NAME}' restarted")

    def kernel_health(self, timeout=5):
        if self.remote_kc is None:
            return False, "not connected"
        try:
            self.remote_kc.kernel_info()
            reply = self.remote_kc.get_shell_msg(timeout=timeout)
            if reply["msg_type"] == "kernel_info_reply":
                return True, "responsive"
            return False, f"unexpected reply: {reply['msg_type']}"
        except Exception as e:
            return False, str(e)


if "_exec_mgr" in globals() and _exec_mgr is not None:
    _exec_mgr.shutdown_remote()

_exec_mgr = RemoteExecutionManager()


# ── remote_run_ ───────────────────────────────────────────────────────────────
def remote_run_(code: str, max_chars: int = 2000) -> str:
    collected = []

    def capturing_hook(msg):
        msg_type = msg["msg_type"]
        content = msg.get("content", {})
        if msg_type == "stream":
            collected.append(_strip_ansi(content.get("text", "")))
        elif msg_type == "error":
            collected.append(_strip_ansi("\n".join(content.get("traceback", []))))
        elif msg_type in ("display_data", "execute_result"):
            data = content.get("data", {})
            if "text/plain" in data:
                collected.append(data["text/plain"])
        _exec_mgr._output_hook(msg)

    touch_kernel()
    _exec_mgr._progress_handle_box[0] = None
    _exec_mgr.remote_kc.execute_interactive(code=code, output_hook=capturing_hook)
    output = "".join(collected)
    if len(output) > max_chars:
        half = max_chars // 2
        output = output[:half] + f"\n\n... [{len(output) - max_chars} chars truncated] ...\n\n" + output[-half:]
    return output


# ── Magics ────────────────────────────────────────────────────────────────────
@register_line_cell_magic
def restart_windows(line, cell=None):
    if not CF_HOSTNAME_WIN or not WINDOWS_USER:
        print("Windows SSH alias is not configured for this client")
        return
    print("Sending restart command to Windows...")
    try:
        _ssh_win("shutdown /r /t 5 /f")
        print("Windows restarting in 5 seconds. Wait ~60-90s then run %remote to reconnect.")
    except Exception as e:
        print(f"Failed: {e}")


@register_line_cell_magic
def remote(line, cell=None):
    if cell is None:
        for attempt in range(3):
            try:
                if _exec_mgr.setup_remote():
                    _exec_mgr.remote_on()
                    return
            except Exception as e:
                print(f"Attempt {attempt + 1}/3 failed: {e}")
                time.sleep(5)
        print("Failed to connect after 3 attempts")
    else:
        _exec_mgr.execute_remote(cell)


@register_line_cell_magic
def local(line, cell=None):
    if cell is None:
        _exec_mgr.remote_off()
    else:
        _exec_mgr._remote_active = False
        try:
            get_ipython().run_cell(cell)
        finally:
            _exec_mgr._remote_active = True


@register_line_cell_magic
def restart_kernel(line, cell=None):
    _exec_mgr.restart_kernel()


@register_line_cell_magic
def kernel_status(line, cell=None):
    print("=" * 40)
    print("KERNEL STATUS")
    print("=" * 40)

    if "_exec_mgr" not in globals() or _exec_mgr is None:
        print("Execution manager not initialized")
        return

    print(f"Config path: {CONFIG_PATH}")
    print(f"Execution mode: {'remote' if _exec_mgr._remote_active else 'local'}")
    print(f"Connected: {'yes' if _exec_mgr.remote_kc else 'no'}")
    print(f"Kernel name: {KERNEL_NAME}")
    print(f"Work dir: {KERNEL_WORK_DIR}")

    if _exec_mgr.remote_kc:
        ok, detail = _exec_mgr.kernel_health()
        print(f"Kernel health: {'OK' if ok else 'FAIL'} ({detail})")

    tunnel_open = False
    if _exec_mgr.remote_kc:
        try:
            info = fetch_kernel_info()
            tunnel_open = _exec_mgr._test_connection(info)
        except Exception:
            pass
    print(f"Tunnel reachable: {'yes' if tunnel_open else 'no'}")
    print("=" * 40)


# ── Auto-connect ──────────────────────────────────────────────────────────────
%remote

print("GPUWS remote kernel loaded")
print("  %remote           connect and enable remote execution for all cells")
print("  %local            switch to local execution")
print("  %%remote          run one cell remotely")
print("  %%local           run one cell locally")
print("  %restart_kernel   restart the remote kernel")
print("  %restart_windows  restart the Windows host")
print("  %kernel_status    show current connection and kernel status")
