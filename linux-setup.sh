#!/usr/bin/env bash
set -euo pipefail

HOST_CONFIG_FILE="${HOME}/.config/gpuws/host.json"
BOOTSTRAP_CONFIG_FILE="${HOME}/.config/gpuws/bootstrap.json"
WINDOWS_BOOTSTRAP_GLOB="/mnt/c/Users/*/.config/gpuws/bootstrap.json"
KERNEL_MANAGER_URL="https://raw.githubusercontent.com/rleyvasal/gpu-dev-setup/main/kernel-manager.sh"

log() {
    echo "$*"
}

step() {
    echo ""
    echo "=== $1 ==="
}

warn() {
    echo "Warning: $*" >&2
}

fail() {
    echo "Error: $*" >&2
    exit 1
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

systemd_usable() {
    command -v systemctl >/dev/null 2>&1 || return 1
    [ -d /run/systemd/system ] || return 1
    systemctl list-units >/dev/null 2>&1 || return 1
}

append_line_once() {
    local line="$1"
    local file="$2"

    touch "$file"
    grep -Fqx "$line" "$file" || echo "$line" >> "$file"
}

json_get() {
    local file="$1"
    local key="$2"

    python3 - "$file" "$key" <<'PY'
import json, pathlib, sys

path = pathlib.Path(sys.argv[1]).expanduser()
key = sys.argv[2]
if not path.exists():
    raise SystemExit(0)

data = json.loads(path.read_text(encoding="utf-8"))
value = data.get(key, "")
if value is None:
    value = ""
print(value)
PY
}

write_host_config() {
    mkdir -p "$(dirname "$HOST_CONFIG_FILE")"

    HOST_TYPE_VALUE="$HOST_TYPE" \
    LINUX_USER_VALUE="$LINUX_USER" \
    WINDOWS_USER_VALUE="$WINDOWS_USER" \
    LINUX_SSH_PORT_VALUE="$LINUX_SSH_PORT" \
    WINDOWS_SSH_PORT_VALUE="$WINDOWS_SSH_PORT" \
    CF_DOMAIN_VALUE="$CF_DOMAIN" \
    CF_TUNNEL_VALUE="$CF_TUNNEL" \
    CF_HOSTNAME_LINUX_VALUE="$CF_HOSTNAME_LINUX" \
    CF_HOSTNAME_WIN_VALUE="$CF_HOSTNAME_WIN" \
    DEFAULT_ROOT_DIR_VALUE="$DEFAULT_ROOT_DIR" \
    VENV_PATH_VALUE="$VENV_PATH" \
    python3 - "$HOST_CONFIG_FILE" <<'PY'
import json, os, pathlib, sys

path = pathlib.Path(sys.argv[1]).expanduser()
data = {
    "host_type": os.environ["HOST_TYPE_VALUE"],
    "linux_user": os.environ["LINUX_USER_VALUE"],
    "windows_user": os.environ["WINDOWS_USER_VALUE"],
    "linux_ssh_port": int(os.environ["LINUX_SSH_PORT_VALUE"]),
    "windows_ssh_port": int(os.environ["WINDOWS_SSH_PORT_VALUE"]),
    "cf_domain": os.environ["CF_DOMAIN_VALUE"],
    "cf_tunnel": os.environ["CF_TUNNEL_VALUE"],
    "cf_hostname_linux": os.environ["CF_HOSTNAME_LINUX_VALUE"],
    "cf_hostname_win": os.environ["CF_HOSTNAME_WIN_VALUE"],
    "default_root_dir": os.environ["DEFAULT_ROOT_DIR_VALUE"],
    "venv_path": os.environ["VENV_PATH_VALUE"],
}
path.write_text(json.dumps(data, indent=2), encoding="utf-8")
PY

    chmod 700 "$(dirname "$HOST_CONFIG_FILE")"
    chmod 600 "$HOST_CONFIG_FILE"
}

ensure_clients_config() {
    local clients_file="${HOME}/.config/gpuws/clients.json"
    mkdir -p "$(dirname "$clients_file")"
    if [ ! -f "$clients_file" ]; then
        printf '{\n  "clients": []\n}\n' > "$clients_file"
    fi
    chmod 600 "$clients_file"
}

cloudflared_authenticated() {
    cloudflared tunnel list >/dev/null 2>&1
}

load_windows_bootstrap_if_needed() {
    [ -f "$BOOTSTRAP_CONFIG_FILE" ] && return 0
    [ "$HOST_TYPE" = "windows-wsl" ] || return 0

    local candidate
    for candidate in $WINDOWS_BOOTSTRAP_GLOB; do
        [ -f "$candidate" ] || continue
        mkdir -p "$(dirname "$BOOTSTRAP_CONFIG_FILE")"
        cp "$candidate" "$BOOTSTRAP_CONFIG_FILE"
        chmod 600 "$BOOTSTRAP_CONFIG_FILE"
        log "Imported bootstrap config from $candidate"
        return 0
    done
}

load_config_values() {
    HOST_TYPE="${HOST_TYPE:-}"
    WINDOWS_USER="${WINDOWS_USER:-}"
    LINUX_SSH_PORT="${LINUX_SSH_PORT:-}"
    WINDOWS_SSH_PORT="${WINDOWS_SSH_PORT:-}"
    SSH_PUBLIC_KEY="${SSH_PUBLIC_KEY:-}"
    CF_DOMAIN="${CF_DOMAIN:-}"
    CF_TUNNEL="${CF_TUNNEL:-}"

    if [ -f "$HOST_CONFIG_FILE" ]; then
        HOST_TYPE="${HOST_TYPE:-$(json_get "$HOST_CONFIG_FILE" host_type)}"
        LINUX_USER="${LINUX_USER:-$(json_get "$HOST_CONFIG_FILE" linux_user)}"
        WINDOWS_USER="${WINDOWS_USER:-$(json_get "$HOST_CONFIG_FILE" windows_user)}"
        LINUX_SSH_PORT="${LINUX_SSH_PORT:-$(json_get "$HOST_CONFIG_FILE" linux_ssh_port)}"
        WINDOWS_SSH_PORT="${WINDOWS_SSH_PORT:-$(json_get "$HOST_CONFIG_FILE" windows_ssh_port)}"
        CF_DOMAIN="${CF_DOMAIN:-$(json_get "$HOST_CONFIG_FILE" cf_domain)}"
        CF_TUNNEL="${CF_TUNNEL:-$(json_get "$HOST_CONFIG_FILE" cf_tunnel)}"
        DEFAULT_ROOT_DIR="${DEFAULT_ROOT_DIR:-$(json_get "$HOST_CONFIG_FILE" default_root_dir)}"
        VENV_PATH="${VENV_PATH:-$(json_get "$HOST_CONFIG_FILE" venv_path)}"
    fi

    if [ -f "$BOOTSTRAP_CONFIG_FILE" ]; then
        HOST_TYPE="${HOST_TYPE:-$(json_get "$BOOTSTRAP_CONFIG_FILE" host_type)}"
        WINDOWS_USER="${WINDOWS_USER:-$(json_get "$BOOTSTRAP_CONFIG_FILE" windows_user)}"
        LINUX_SSH_PORT="${LINUX_SSH_PORT:-$(json_get "$BOOTSTRAP_CONFIG_FILE" linux_ssh_port)}"
        WINDOWS_SSH_PORT="${WINDOWS_SSH_PORT:-$(json_get "$BOOTSTRAP_CONFIG_FILE" windows_ssh_port)}"
        SSH_PUBLIC_KEY="${SSH_PUBLIC_KEY:-$(json_get "$BOOTSTRAP_CONFIG_FILE" ssh_public_key)}"
        CF_DOMAIN="${CF_DOMAIN:-$(json_get "$BOOTSTRAP_CONFIG_FILE" cf_domain)}"
        CF_TUNNEL="${CF_TUNNEL:-$(json_get "$BOOTSTRAP_CONFIG_FILE" cf_tunnel)}"
    fi

    HOST_TYPE="${HOST_TYPE:-$DETECTED_HOST_TYPE}"
    LINUX_USER="${LINUX_USER:-$(whoami)}"
    LINUX_SSH_PORT="${LINUX_SSH_PORT:-2222}"
    WINDOWS_SSH_PORT="${WINDOWS_SSH_PORT:-22}"
    DEFAULT_ROOT_DIR="${DEFAULT_ROOT_DIR:-/home/$LINUX_USER/gpws}"
    VENV_PATH="${VENV_PATH:-$DEFAULT_ROOT_DIR/.venv}"
}

prompt_for_missing_values() {
    [ "${NON_INTERACTIVE:-}" = "true" ] && return 0

    echo ""
    echo "Press Enter to accept defaults or enter different values."

    if [ -z "${SSH_PUBLIC_KEY:-}" ]; then
        echo ""
        echo "Paste your SSH public key:"
        read -r -p "SSH public key: " SSH_PUBLIC_KEY
    fi

    read -r -p "Linux SSH port [$LINUX_SSH_PORT]: " _LSP
    LINUX_SSH_PORT="${_LSP:-$LINUX_SSH_PORT}"

    if [ "$HOST_TYPE" = "windows-wsl" ]; then
        read -r -p "Windows SSH port [$WINDOWS_SSH_PORT]: " _WSP
        WINDOWS_SSH_PORT="${_WSP:-$WINDOWS_SSH_PORT}"
    fi

    if [ -z "${CF_DOMAIN:-}" ]; then
        read -r -p "Cloudflare domain: " CF_DOMAIN
    fi

    read -r -p "Tunnel name [$CF_TUNNEL]: " _TUN
    CF_TUNNEL="${_TUN:-$CF_TUNNEL}"
}

validate_required_values() {
    [ -n "${SSH_PUBLIC_KEY:-}" ] || fail "SSH_PUBLIC_KEY is required"
    [ -n "${CF_DOMAIN:-}" ] || fail "CF_DOMAIN is required"
    [ -n "${CF_TUNNEL:-}" ] || fail "CF_TUNNEL is required"

    if [ "$HOST_TYPE" = "windows-wsl" ]; then
        [ -n "${WINDOWS_USER:-}" ] || fail "WINDOWS_USER is required for windows-wsl setup"
    fi
}

derive_values() {
    local short_host
    short_host="$(hostname | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9._-]+/-/g; s/^-+//; s/-+$//')"

    CF_HOSTNAME_LINUX="${LINUX_USER}.${CF_DOMAIN}"
    if [ "$HOST_TYPE" = "windows-wsl" ]; then
        CF_HOSTNAME_WIN="${short_host}.${CF_DOMAIN}"
    else
        CF_HOSTNAME_WIN=""
        WINDOWS_USER=""
    fi
}

install_cloudflared() {
    if command_exists cloudflared; then
        log "cloudflared already installed"
        return 0
    fi

    local os
    os="$(uname -s)"

    case "$os" in
        Linux)
            local tmp_deb
            tmp_deb="$(mktemp /tmp/cloudflared.XXXXXX.deb)"
            curl -fsSL \
              "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb" \
              -o "$tmp_deb"
            sudo dpkg -i "$tmp_deb" || sudo apt-get install -f -y
            rm -f "$tmp_deb"
            ;;
        *)
            fail "Unsupported OS for automatic cloudflared install: $os"
            ;;
    esac

    command_exists cloudflared || fail "cloudflared install failed"
}

write_cloudflared_config() {
    local config_yml="$HOME/.cloudflared/config.yml"
    local tunnel_id="$1"
    local extra_ingress=""

    mkdir -p "$HOME/.cloudflared"

    if [ "$HOST_TYPE" = "windows-wsl" ]; then
        local win_ip
        win_ip="$(ip route | awk '/default/ {print $3; exit}')"
        extra_ingress="  - hostname: $CF_HOSTNAME_WIN
    service: tcp://${win_ip}:${WINDOWS_SSH_PORT}"
    fi

    cat > "$config_yml" <<EOF
tunnel: $tunnel_id
credentials-file: $HOME/.cloudflared/${tunnel_id}.json

ingress:
  - hostname: $CF_HOSTNAME_LINUX
    service: tcp://localhost:${LINUX_SSH_PORT}
$extra_ingress
  - service: http_status:404
EOF
}

run_health_check() {
    step "Step 10: Health check"

    sshd -t >/dev/null 2>&1 || fail "sshd configuration test failed"
    [ -x "$VENV_PATH/bin/python" ] || fail "Shared venv python missing at $VENV_PATH/bin/python"
    [ -x "$HOME/bin/kernel-manager.sh" ] || fail "kernel-manager.sh missing"
    [ -f "$HOST_CONFIG_FILE" ] || fail "host.json missing"

    log "Host type: $HOST_TYPE"
    log "Linux SSH: $CF_HOSTNAME_LINUX:$LINUX_SSH_PORT"
    if [ "$HOST_TYPE" = "windows-wsl" ]; then
        log "Windows SSH: $CF_HOSTNAME_WIN:$WINDOWS_SSH_PORT"
    fi
    log "Shared root: $DEFAULT_ROOT_DIR"
    log "Shared venv: $VENV_PATH"
    log "Host setup complete."
    log "Next step: add a client."
}

# Step 1: Detect and load
if grep -qi microsoft /proc/version 2>/dev/null; then
    DETECTED_HOST_TYPE="windows-wsl"
    log "Running in WSL mode"
else
    DETECTED_HOST_TYPE="linux"
    log "Running in standalone Linux mode"
fi

load_windows_bootstrap_if_needed
load_config_values
prompt_for_missing_values
validate_required_values
derive_values

if [ "${NON_INTERACTIVE:-}" != "true" ]; then
    echo ""
    echo "Host type: $HOST_TYPE"
    echo "Linux user: $LINUX_USER"
    echo "Linux SSH port: $LINUX_SSH_PORT"
    if [ "$HOST_TYPE" = "windows-wsl" ]; then
        echo "Windows SSH port: $WINDOWS_SSH_PORT"
    fi
    echo "Cloudflare domain: $CF_DOMAIN"
    echo "Tunnel name: $CF_TUNNEL"
    echo "Shared root dir: $DEFAULT_ROOT_DIR"
    echo "Shared venv: $VENV_PATH"
    echo ""
    read -r -p "Press Enter when ready..."
fi

step "Step 2: Install dependencies"
if ! command_exists sshd || ! command_exists curl || ! dpkg -l | grep -q "^ii  python3-venv"; then
    sudo apt-get update -q
    sudo apt-get install -qy openssh-server curl wget python3 python3-venv
    if [ "$HOST_TYPE" = "linux" ]; then
        sudo apt-get install -qy ufw
    fi
else
    log "Dependencies already installed, skipping."
fi

step "Step 3: Configure SSH on port $LINUX_SSH_PORT"
sudo sed -i -E "s/^#?Port [0-9]+/Port $LINUX_SSH_PORT/" /etc/ssh/sshd_config
sudo sed -i -E "s/#?(PubkeyAuthentication).*/\1 yes/" /etc/ssh/sshd_config
sudo sed -i -E "s/#?(PasswordAuthentication).*/\1 no/" /etc/ssh/sshd_config
sudo mkdir -p /run/sshd

if systemd_usable; then
    sudo systemctl enable ssh
    sudo systemctl restart ssh
else
    warn "systemd is not available; skipping ssh service enable/restart"
fi

step "Step 4: Add SSH key"
mkdir -p "$HOME/.ssh"
touch "$HOME/.ssh/authorized_keys"
grep -qxF "$SSH_PUBLIC_KEY" "$HOME/.ssh/authorized_keys" || echo "$SSH_PUBLIC_KEY" >> "$HOME/.ssh/authorized_keys"
chmod 700 "$HOME/.ssh"
chmod 600 "$HOME/.ssh/authorized_keys"

step "Step 5: Configure machine behavior"
if [ "$HOST_TYPE" = "windows-wsl" ]; then
    log "WSL detected, skipping Linux firewall and sleep configuration."
else
    sudo ufw allow "$LINUX_SSH_PORT/tcp" comment "GPUWS Linux SSH" || true
    sudo ufw --force enable
    sudo systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target
    log "Firewall configured and sleep/suspend disabled"
fi

step "Step 6: Prepare GPUWS directories"
mkdir -p "$DEFAULT_ROOT_DIR" "$HOME/bin" "$HOME/.config/gpuws"
append_line_once 'export PATH="$HOME/.local/bin:$HOME/.cargo/bin:$HOME/bin:$PATH"' "$HOME/.bashrc"
export PATH="$HOME/.local/bin:$HOME/.cargo/bin:$HOME/bin:$PATH"

step "Step 7: Install uv and create shared venv"
if ! command_exists uv; then
    curl -LsSf https://astral.sh/uv/install.sh | sh
    [ -f "$HOME/.local/bin/env" ] && . "$HOME/.local/bin/env" || true
    [ -f "$HOME/.cargo/env" ] && . "$HOME/.cargo/env" || true
    export PATH="$HOME/.local/bin:$HOME/.cargo/bin:$HOME/bin:$PATH"
fi

mkdir -p "$DEFAULT_ROOT_DIR"
if [ ! -f "$DEFAULT_ROOT_DIR/pyproject.toml" ]; then
    (cd "$DEFAULT_ROOT_DIR" && uv init --name "gpuws")
fi
(cd "$DEFAULT_ROOT_DIR" && uv python pin 3.12)

if [ ! -d "$VENV_PATH" ]; then
    uv venv "$VENV_PATH" --project "$DEFAULT_ROOT_DIR"
    log "Shared venv created at $VENV_PATH"
else
    log "Shared venv exists at $VENV_PATH"
fi

(
    cd "$DEFAULT_ROOT_DIR" && \
    uv add --python "$VENV_PATH/bin/python" \
      ipykernel jupyter_client torch torchvision torchaudio \
      numpy numba pandas scipy scikit-learn matplotlib plotly pillow tqdm httpx requests
)

step "Step 8: Install host management tools"
curl -fsSL "$KERNEL_MANAGER_URL" -o "$HOME/bin/kernel-manager.sh"
chmod +x "$HOME/bin/kernel-manager.sh"
ensure_clients_config

if systemd_usable; then
    sudo tee /etc/systemd/system/kernel-cleanup.service > /dev/null <<EOF
[Unit]
Description=Cleanup inactive GPUWS kernels

[Service]
Type=oneshot
User=${LINUX_USER}
ExecStart=${HOME}/bin/kernel-manager.sh cleanup
EOF

    sudo tee /etc/systemd/system/kernel-cleanup.timer > /dev/null <<EOF
[Unit]
Description=Run GPUWS kernel cleanup daily

[Timer]
OnCalendar=*-*-* 22:00:00
Persistent=true

[Install]
WantedBy=timers.target
EOF

    sudo systemctl daemon-reload
    sudo systemctl enable kernel-cleanup.timer
    sudo systemctl restart kernel-cleanup.timer
fi

step "Step 9: Configure Cloudflare"
install_cloudflared

mkdir -p "$HOME/.local/bin"
CF_ACTUAL_PATH="$(command -v cloudflared 2>/dev/null || true)"
if [ -n "$CF_ACTUAL_PATH" ] && [ "$CF_ACTUAL_PATH" != "$HOME/.local/bin/cloudflared" ]; then
    ln -sf "$CF_ACTUAL_PATH" "$HOME/.local/bin/cloudflared"
fi

if ! cloudflared_authenticated; then
    if [ "${NON_INTERACTIVE:-}" = "true" ]; then
        warn "cloudflared is not authenticated. Run 'cloudflared tunnel login' and rerun setup."
    else
        fail "cloudflared is not authenticated. Run 'cloudflared tunnel login' and rerun this script."
    fi
else
    if ! cloudflared tunnel list 2>/dev/null | awk '{print $2}' | grep -qx "$CF_TUNNEL"; then
        cloudflared tunnel create "$CF_TUNNEL"
    fi

    TUNNEL_ID="$(cloudflared tunnel list | awk -v tunnel="$CF_TUNNEL" '$2 == tunnel {print $1; exit}')"
    [ -n "$TUNNEL_ID" ] || fail "Failed to determine tunnel id for $CF_TUNNEL"

    cloudflared tunnel route dns "$CF_TUNNEL" "$CF_HOSTNAME_LINUX" 2>/dev/null || true
    if [ "$HOST_TYPE" = "windows-wsl" ]; then
        cloudflared tunnel route dns "$CF_TUNNEL" "$CF_HOSTNAME_WIN" 2>/dev/null || true
    fi

    write_cloudflared_config "$TUNNEL_ID"

    if systemd_usable; then
        sudo tee /etc/systemd/system/cloudflared-tunnel.service > /dev/null <<EOF
[Unit]
Description=GPUWS Cloudflare Tunnel
After=network.target

[Service]
User=${LINUX_USER}
ExecStart=/usr/bin/cloudflared tunnel run ${CF_TUNNEL}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

        sudo systemctl daemon-reload
        sudo systemctl enable cloudflared-tunnel
        sudo systemctl restart cloudflared-tunnel
    fi
fi

write_host_config
run_health_check
