#!/usr/bin/env bash
set -euo pipefail

# GPUWS Linux host setup
# Target: Ubuntu/Debian-based systems and WSL Ubuntu-style environments.

HOST_CONFIG_FILE="${HOME}/.config/gpuws/host.json"
BOOTSTRAP_CONFIG_FILE="${HOME}/.config/gpuws/bootstrap.json"
WINDOWS_BOOTSTRAP_GLOB="/mnt/c/Users/*/.config/gpuws/bootstrap.json"

KERNEL_MANAGER_URL="https://raw.githubusercontent.com/rleyvasal/gpuws/main/kernel-manager.sh"
GPUWS_HOST_SCRIPT_URL="https://raw.githubusercontent.com/rleyvasal/gpuws/main/gpuws"
CLIENT_SETUP_TEMPLATE_URL="https://raw.githubusercontent.com/rleyvasal/gpuws/main/client-setup.sh"

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

require_debian_family() {
    [ -f /etc/debian_version ] || fail "GPUWS linux-setup.sh currently supports Ubuntu/Debian-based systems only."
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

sanitize_host_label() {
    printf '%s' "$1" \
      | tr '[:upper:]' '[:lower:]' \
      | sed -E 's/[^a-z0-9-]+/-/g; s/-+/-/g; s/^-+//; s/-+$//'
}

write_host_config() {
    mkdir -p "$(dirname "$HOST_CONFIG_FILE")"

    HOST_TYPE_VALUE="$HOST_TYPE" \
    HOST_LABEL_VALUE="$HOST_LABEL" \
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
    "host_label": os.environ["HOST_LABEL_VALUE"],
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

discover_windows_bootstrap() {
    [ "$DETECTED_HOST_TYPE" = "windows-wsl" ] || return 0
    [ -f "$BOOTSTRAP_CONFIG_FILE" ] && return 0

    local candidate
    for candidate in $WINDOWS_BOOTSTRAP_GLOB; do
        [ -f "$candidate" ] || continue
        mkdir -p "$(dirname "$BOOTSTRAP_CONFIG_FILE")"
        cp "$candidate" "$BOOTSTRAP_CONFIG_FILE"
        chmod 600 "$BOOTSTRAP_CONFIG_FILE"
        log "Imported GPUWS bootstrap config from $candidate"
        return 0
    done
}

load_host_json_values() {
    [ -f "$HOST_CONFIG_FILE" ] || return 0

    HOST_TYPE="$(json_get "$HOST_CONFIG_FILE" host_type)"
    HOST_LABEL="$(json_get "$HOST_CONFIG_FILE" host_label)"
    LINUX_USER="$(json_get "$HOST_CONFIG_FILE" linux_user)"
    WINDOWS_USER="$(json_get "$HOST_CONFIG_FILE" windows_user)"
    LINUX_SSH_PORT="$(json_get "$HOST_CONFIG_FILE" linux_ssh_port)"
    WINDOWS_SSH_PORT="$(json_get "$HOST_CONFIG_FILE" windows_ssh_port)"
    CF_DOMAIN="$(json_get "$HOST_CONFIG_FILE" cf_domain)"
    CF_TUNNEL="$(json_get "$HOST_CONFIG_FILE" cf_tunnel)"
    DEFAULT_ROOT_DIR="$(json_get "$HOST_CONFIG_FILE" default_root_dir)"
    VENV_PATH="$(json_get "$HOST_CONFIG_FILE" venv_path)"
}

load_bootstrap_values() {
    [ -f "$BOOTSTRAP_CONFIG_FILE" ] || return 0

    HOST_TYPE="${HOST_TYPE:-$(json_get "$BOOTSTRAP_CONFIG_FILE" host_type)}"
    HOST_LABEL="${HOST_LABEL:-$(json_get "$BOOTSTRAP_CONFIG_FILE" host_label)}"
    WINDOWS_USER="${WINDOWS_USER:-$(json_get "$BOOTSTRAP_CONFIG_FILE" windows_user)}"
    LINUX_SSH_PORT="${LINUX_SSH_PORT:-$(json_get "$BOOTSTRAP_CONFIG_FILE" linux_ssh_port)}"
    WINDOWS_SSH_PORT="${WINDOWS_SSH_PORT:-$(json_get "$BOOTSTRAP_CONFIG_FILE" windows_ssh_port)}"
    SSH_PUBLIC_KEY="${SSH_PUBLIC_KEY:-$(json_get "$BOOTSTRAP_CONFIG_FILE" ssh_public_key)}"
    CF_DOMAIN="${CF_DOMAIN:-$(json_get "$BOOTSTRAP_CONFIG_FILE" cf_domain)}"
    CF_TUNNEL="${CF_TUNNEL:-$(json_get "$BOOTSTRAP_CONFIG_FILE" cf_tunnel)}"
}

apply_env_overrides() {
    HOST_TYPE="${GPUWS_HOST_TYPE:-${HOST_TYPE:-}}"
    HOST_LABEL="${GPUWS_HOST_LABEL:-${HOST_LABEL:-}}"
    WINDOWS_USER="${GPUWS_WINDOWS_USER:-${WINDOWS_USER:-}}"
    LINUX_SSH_PORT="${GPUWS_LINUX_SSH_PORT:-${LINUX_SSH_PORT:-}}"
    WINDOWS_SSH_PORT="${GPUWS_WINDOWS_SSH_PORT:-${WINDOWS_SSH_PORT:-}}"
    SSH_PUBLIC_KEY="${GPUWS_SSH_PUBLIC_KEY:-${SSH_PUBLIC_KEY:-}}"
    CF_DOMAIN="${GPUWS_CF_DOMAIN:-${CF_DOMAIN:-}}"
    CF_TUNNEL="${GPUWS_CF_TUNNEL:-${CF_TUNNEL:-}}"
}

apply_defaults() {
    HOST_TYPE="${HOST_TYPE:-$DETECTED_HOST_TYPE}"
    LINUX_USER="${LINUX_USER:-$(whoami)}"
    LINUX_SSH_PORT="${LINUX_SSH_PORT:-2222}"
    WINDOWS_SSH_PORT="${WINDOWS_SSH_PORT:-22}"
    CF_TUNNEL="${CF_TUNNEL:-gpuws}"
    DEFAULT_ROOT_DIR="${DEFAULT_ROOT_DIR:-/home/$LINUX_USER/gpws}"
    VENV_PATH="${VENV_PATH:-$DEFAULT_ROOT_DIR/.venv}"

    if [ -z "${HOST_LABEL:-}" ]; then
        HOST_LABEL="$(sanitize_host_label "$(hostname)")"
    fi
}

validate_ssh_public_key() {
    local key="$1"
    local tmp_key

    [ -n "${key:-}" ] || return 1

    tmp_key="$(mktemp)"
    printf '%s\n' "$key" > "$tmp_key"

    if ssh-keygen -l -f "$tmp_key" >/dev/null 2>&1; then
        rm -f "$tmp_key"
        return 0
    fi

    rm -f "$tmp_key"
    return 1
}

validate_required_values() {
    [ -n "${SSH_PUBLIC_KEY:-}" ] || fail "GPUWS requires an admin SSH public key"
    validate_ssh_public_key "$SSH_PUBLIC_KEY" || fail "Invalid admin SSH public key"
    [ -n "${HOST_LABEL:-}" ] || fail "GPUWS requires a host label"
    [ -n "${CF_DOMAIN:-}" ] || fail "GPUWS requires a Cloudflare domain"
    [ -n "${CF_TUNNEL:-}" ] || fail "GPUWS requires a Cloudflare tunnel name"
}

check_or_fail() {
    local description="$1"
    shift

    local output=""
    if ! output="$("$@" 2>&1)"; then
        if [ -n "$output" ]; then
            fail "$description: $output"
        else
            fail "$description"
        fi
    fi
}

set_sshd_option() {
    local key="$1"
    local value="$2"
    local config_file="/etc/ssh/sshd_config"

    if sudo grep -Eq "^[#[:space:]]*${key}[[:space:]]+" "$config_file"; then
        sudo sed -i -E "s|^[#[:space:]]*${key}[[:space:]]+.*|${key} ${value}|" "$config_file"
    else
        echo "${key} ${value}" | sudo tee -a "$config_file" >/dev/null
    fi
}

port_in_use() {
    local port="$1"
    ss -ltn | awk '{print $4}' | grep -Eq "(^|:)$port$"
}

choose_free_linux_ssh_port() {
    if [ "${NON_INTERACTIVE:-}" = "true" ]; then
        if port_in_use "$LINUX_SSH_PORT"; then
            fail "Port $LINUX_SSH_PORT is already in use. Choose a different Linux SSH port and rerun setup."
        fi
        return 0
    fi

    while port_in_use "$LINUX_SSH_PORT"; do
        echo "Port $LINUX_SSH_PORT is already in use."
        read -r -p "Choose a different Linux SSH port: " _NEW_LINUX_SSH_PORT
        [ -n "$_NEW_LINUX_SSH_PORT" ] || continue
        LINUX_SSH_PORT="$_NEW_LINUX_SSH_PORT"
    done
}

cloudflared_authenticated() {
    cloudflared tunnel list >/dev/null 2>&1
}

install_cloudflared() {
    if command_exists cloudflared; then
        log "cloudflared already installed"
        return 0
    fi

    local tmp_deb
    tmp_deb="$(mktemp /tmp/cloudflared.XXXXXX.deb)"
    curl -fsSL \
      "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb" \
      -o "$tmp_deb"
    sudo dpkg -i "$tmp_deb" || sudo apt-get install -f -y
    rm -f "$tmp_deb"

    command_exists cloudflared || fail "cloudflared install failed"
}

ensure_cloudflared_symlink() {
    local stable_dir="$HOME/.local/bin"
    local stable_path="$stable_dir/cloudflared"
    local actual_path

    mkdir -p "$stable_dir"

    if [ -L "$stable_path" ] && ! readlink "$stable_path" >/dev/null 2>&1; then
        rm -f "$stable_path"
    fi

    actual_path="$(command -v cloudflared 2>/dev/null || true)"
    [ -n "$actual_path" ] || fail "cloudflared is not installed or not on PATH"

    if [ "$actual_path" = "$stable_path" ]; then
        if [ -x "$stable_path" ]; then
            log "cloudflared already available at $stable_path"
            return 0
        fi
        fail "cloudflared at $stable_path is not executable"
    fi

    [ -x "$actual_path" ] || fail "cloudflared binary is not executable: $actual_path"

    if [ -e "$stable_path" ] && [ ! -L "$stable_path" ]; then
        warn "$stable_path already exists and is not a symlink; leaving it unchanged"
        return 0
    fi

    ln -sfn "$actual_path" "$stable_path"

    if [ -L "$stable_path" ] || [ -x "$stable_path" ]; then
        log "cloudflared available at $stable_path"
        return 0
    fi

    fail "Failed to create working cloudflared symlink at $stable_path"
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

install_cloudflared_service() {
    local cloudflared_path
    cloudflared_path="$(command -v cloudflared)"
    [ -n "$cloudflared_path" ] || fail "cloudflared binary not found for systemd service"

    sudo tee /etc/systemd/system/gpuws-cloudflared.service >/dev/null <<EOF
[Unit]
Description=GPUWS Cloudflare Tunnel
After=network.target

[Service]
User=${LINUX_USER}
ExecStart=${cloudflared_path} tunnel run ${CF_TUNNEL}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

    sudo systemctl daemon-reload
    sudo systemctl enable gpuws-cloudflared
    sudo systemctl restart gpuws-cloudflared
}

install_kernel_cleanup_timer() {
    sudo tee /etc/systemd/system/gpuws-kernel-cleanup.service >/dev/null <<EOF
[Unit]
Description=Cleanup inactive GPUWS kernels

[Service]
Type=oneshot
User=${LINUX_USER}
ExecStart=${HOME}/bin/kernel-manager.sh cleanup
EOF

    sudo tee /etc/systemd/system/gpuws-kernel-cleanup.timer >/dev/null <<EOF
[Unit]
Description=Run GPUWS kernel cleanup daily

[Timer]
OnCalendar=*-*-* 22:00:00
Persistent=true

[Install]
WantedBy=timers.target
EOF

    sudo systemctl daemon-reload
    sudo systemctl enable gpuws-kernel-cleanup.timer
    sudo systemctl restart gpuws-kernel-cleanup.timer
}

derive_values() {
    CF_HOSTNAME_LINUX="${HOST_LABEL}.${CF_DOMAIN}"

    if [ "$HOST_TYPE" = "windows-wsl" ]; then
        CF_HOSTNAME_WIN="${HOST_LABEL}-win.${CF_DOMAIN}"
    else
        CF_HOSTNAME_WIN=""
        WINDOWS_USER=""
    fi
}

prompt_for_missing_values() {
    [ "${NON_INTERACTIVE:-}" = "true" ] && return 0

    echo ""
    echo "Press Enter to accept defaults or enter different values."

    if [ -z "${SSH_PUBLIC_KEY:-}" ]; then
        while true; do
            echo ""
            echo "Paste the admin SSH public key from the machine you will use to access this GPU host."
            echo "This grants initial SSH access to the host."
            echo "Example source: ~/.ssh/id_ed25519.pub on your laptop or client machine."
            read -r -p "Admin SSH public key: " SSH_PUBLIC_KEY

            if validate_ssh_public_key "$SSH_PUBLIC_KEY"; then
                break
            fi

            echo "Invalid admin SSH public key. Please paste a valid public key from the client machine you will use to access this host."
            SSH_PUBLIC_KEY=""
        done
    fi

    read -r -p "Host label [$HOST_LABEL]: " _HL
    HOST_LABEL="$(sanitize_host_label "${_HL:-$HOST_LABEL}")"
    [ -n "$HOST_LABEL" ] || fail "Host label is required"

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

windows_bootstrap_status() {
    local candidate
    for candidate in $WINDOWS_BOOTSTRAP_GLOB; do
        [ -f "$candidate" ] || continue

        local win_user=""
        local win_port=""
        win_user="$(json_get "$candidate" windows_user)"
        win_port="$(json_get "$candidate" windows_ssh_port)"

        if [ -n "$win_user" ] || [ -n "$win_port" ]; then
            printf '%s|%s|%s\n' "$candidate" "$win_user" "$win_port"
            return 0
        fi
    done

    return 1
}

run_health_check() {
    step "GPUWS Step 10: Health check"

    check_or_fail "sshd configuration test failed" sudo sshd -t
    [ -x "$VENV_PATH/bin/python" ] || fail "Shared venv python missing at $VENV_PATH/bin/python"
    [ -x "$HOME/bin/kernel-manager.sh" ] || fail "kernel-manager.sh missing at $HOME/bin/kernel-manager.sh"
    [ -x "$HOME/bin/gpuws" ] || fail "gpuws host command missing at $HOME/bin/gpuws"
    [ -f "$HOME/.config/gpuws/templates/client-setup.sh" ] || fail "client-setup.sh template missing at $HOME/.config/gpuws/templates/client-setup.sh"
    [ -f "$HOST_CONFIG_FILE" ] || fail "host.json missing at $HOST_CONFIG_FILE"

    log "Host type: $HOST_TYPE"
    log "Host label: $HOST_LABEL"
    log "Tunnel name: $CF_TUNNEL"
    log "Linux SSH: $CF_HOSTNAME_LINUX:$LINUX_SSH_PORT"

    if [ "$HOST_TYPE" = "windows-wsl" ]; then
        if [ -n "${CF_HOSTNAME_WIN:-}" ] && [ -n "${WINDOWS_USER:-}" ]; then
            log "Windows SSH: $CF_HOSTNAME_WIN:$WINDOWS_SSH_PORT"
        else
            local win_bootstrap_info=""
            if win_bootstrap_info="$(windows_bootstrap_status)"; then
                local win_bootstrap_path=""
                local win_bootstrap_user=""
                local win_bootstrap_port=""
                IFS='|' read -r win_bootstrap_path win_bootstrap_user win_bootstrap_port <<< "$win_bootstrap_info"
                log "Windows SSH port: ${win_bootstrap_port:-22} (from Windows bootstrap: $win_bootstrap_path)"
            else
                log "Windows SSH port: 22 (Windows bootstrap not found)"
            fi
        fi
    fi

    log "Shared root: $DEFAULT_ROOT_DIR"
    log "Shared venv: $VENV_PATH"
    log "Host command: $HOME/bin/gpuws"
    log "Client template: $HOME/.config/gpuws/templates/client-setup.sh"
    log "GPUWS host setup complete."
    log "Next step: run 'gpuws client add'"
}

DETECTED_HOST_TYPE="linux"
if grep -qi microsoft /proc/version 2>/dev/null; then
    DETECTED_HOST_TYPE="windows-wsl"
    log "Running in GPUWS WSL mode"
else
    log "Running in GPUWS standalone Linux mode"
fi

require_debian_family
discover_windows_bootstrap

HOST_TYPE=""
HOST_LABEL=""
LINUX_USER=""
WINDOWS_USER=""
LINUX_SSH_PORT=""
WINDOWS_SSH_PORT=""
SSH_PUBLIC_KEY="${SSH_PUBLIC_KEY:-}"
CF_DOMAIN="${CF_DOMAIN:-}"
CF_TUNNEL="${CF_TUNNEL:-}"
DEFAULT_ROOT_DIR=""
VENV_PATH=""

load_host_json_values
load_bootstrap_values
apply_env_overrides
apply_defaults
prompt_for_missing_values
validate_required_values
derive_values

if [ "${NON_INTERACTIVE:-}" != "true" ]; then
    echo ""
    echo "Host type: $HOST_TYPE"
    echo "Host label: $HOST_LABEL"
    echo "Linux user: $LINUX_USER"
    echo "Linux SSH port: $LINUX_SSH_PORT"
    if [ "$HOST_TYPE" = "windows-wsl" ]; then
        echo "Windows SSH port: $WINDOWS_SSH_PORT"
    fi
    echo "Cloudflare domain: $CF_DOMAIN"
    echo "Tunnel name: $CF_TUNNEL"
    echo "Linux hostname: ${CF_HOSTNAME_LINUX}"
    if [ "$HOST_TYPE" = "windows-wsl" ]; then
        echo "Windows hostname: ${CF_HOSTNAME_WIN}"
    fi
    echo "Shared root dir: $DEFAULT_ROOT_DIR"
    echo "Shared venv: $VENV_PATH"
    echo "Admin SSH key: will be added for initial host access"
    echo ""
    read -r -p "Press Enter when ready..."
fi

step "GPUWS Step 2: Install dependencies"
if ! command_exists sshd || ! command_exists curl || ! command_exists jq || ! dpkg -l | grep -q "^ii  python3-venv"; then
    sudo apt-get update -q
    sudo apt-get install -qy openssh-server curl wget python3 python3-venv jq
    if [ "$HOST_TYPE" = "linux" ]; then
        sudo apt-get install -qy ufw
    fi
else
    log "Dependencies already installed, skipping."
fi

step "GPUWS Step 3: Configure SSH on port $LINUX_SSH_PORT"

choose_free_linux_ssh_port

SSHD_CONFIG_BACKUP="$(mktemp)"
sudo cp /etc/ssh/sshd_config "$SSHD_CONFIG_BACKUP"

restore_sshd_config() {
    sudo cp "$SSHD_CONFIG_BACKUP" /etc/ssh/sshd_config
    rm -f "$SSHD_CONFIG_BACKUP"
}

set_sshd_option "Port" "$LINUX_SSH_PORT"
set_sshd_option "PubkeyAuthentication" "yes"
set_sshd_option "PasswordAuthentication" "no"
sudo mkdir -p /run/sshd

if ! sudo sshd -t >/dev/null 2>&1; then
    restore_sshd_config
    fail "Invalid sshd_config after GPUWS SSH changes"
fi

if systemd_usable; then
    if ! sudo systemctl enable ssh >/dev/null 2>&1; then
        restore_sshd_config
        fail "Failed to enable ssh service"
    fi

    if ! restart_error="$(sudo systemctl restart ssh 2>&1)"; then
        restore_sshd_config
        fail "Failed to restart ssh service: $restart_error"
    fi
else
    warn "systemd is not available; skipping ssh service enable/restart"
fi

rm -f "$SSHD_CONFIG_BACKUP"

step "GPUWS Step 4: Authorize admin SSH key"
validate_ssh_public_key "$SSH_PUBLIC_KEY" || fail "Invalid admin SSH public key"

mkdir -p "$HOME/.ssh"
touch "$HOME/.ssh/authorized_keys"
grep -qxF "$SSH_PUBLIC_KEY" "$HOME/.ssh/authorized_keys" || echo "$SSH_PUBLIC_KEY" >> "$HOME/.ssh/authorized_keys"
chmod 700 "$HOME/.ssh"
chmod 600 "$HOME/.ssh/authorized_keys"

step "GPUWS Step 5: Configure machine behavior"
if [ "$HOST_TYPE" = "windows-wsl" ]; then
    log "WSL detected, skipping Linux firewall and sleep configuration."
else
    sudo ufw allow "$LINUX_SSH_PORT/tcp" comment "GPUWS Linux SSH" || true
    sudo ufw --force enable
    sudo systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target
    log "Firewall configured and sleep/suspend disabled"
fi

step "GPUWS Step 6: Prepare GPUWS directories"
mkdir -p "$DEFAULT_ROOT_DIR" "$HOME/bin" "$HOME/.config/gpuws"
append_line_once 'export PATH="$HOME/.local/bin:$HOME/.cargo/bin:$HOME/bin:$PATH"' "$HOME/.bashrc"
export PATH="$HOME/.local/bin:$HOME/.cargo/bin:$HOME/bin:$PATH"

step "GPUWS Step 7: Install uv and create shared venv"
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
    (
        cd "$DEFAULT_ROOT_DIR" && \
        uv add --python "$VENV_PATH/bin/python" \
          ipykernel jupyter_client torch torchvision torchaudio \
          numpy numba pandas scipy scikit-learn matplotlib plotly pillow tqdm httpx requests
    )
    log "Shared GPUWS venv created at $VENV_PATH"
else
    log "Shared GPUWS venv exists at $VENV_PATH, skipping package install"
fi

step "GPUWS Step 8: Install host management tools"
curl -fsSL "$KERNEL_MANAGER_URL" -o "$HOME/bin/kernel-manager.sh"
chmod +x "$HOME/bin/kernel-manager.sh"

curl -fsSL "$GPUWS_HOST_SCRIPT_URL" -o "$HOME/bin/gpuws"
chmod +x "$HOME/bin/gpuws"

mkdir -p "$HOME/.config/gpuws/templates"
curl -fsSL "$CLIENT_SETUP_TEMPLATE_URL" -o "$HOME/.config/gpuws/templates/client-setup.sh"
chmod 600 "$HOME/.config/gpuws/templates/client-setup.sh"

ensure_clients_config

if systemd_usable; then
    install_kernel_cleanup_timer
fi

step "GPUWS Step 9: Configure Cloudflare"
install_cloudflared
ensure_cloudflared_symlink

if ! cloudflared_authenticated; then
    if [ "${NON_INTERACTIVE:-}" = "true" ]; then
        fail "cloudflared is not authenticated. Run 'cloudflared tunnel login' and rerun this script."
    fi

    echo ""
    echo "Cloudflare authentication is required."
    echo "A login URL will be shown next."
    echo "Before using that URL, make sure you are signed in to the correct Cloudflare account in your browser."
    echo "If you are running inside WSL, the browser may open on Windows."
    echo "If the first redirect only signs you in, open the displayed URL again after login."
    echo ""

    cloudflared tunnel login

    if ! cloudflared_authenticated; then
        fail "cloudflared authentication did not complete successfully."
    fi
fi

if ! cloudflared tunnel list 2>/dev/null | awk '{print $2}' | grep -qx "$CF_TUNNEL"; then
    cloudflared tunnel create "$CF_TUNNEL"
fi

TUNNEL_ID="$(cloudflared tunnel list | awk -v tunnel="$CF_TUNNEL" '$2 == tunnel {print $1; exit}')"
[ -n "$TUNNEL_ID" ] || fail "Failed to determine tunnel id for $CF_TUNNEL"

check_or_fail "Failed to create DNS route for $CF_HOSTNAME_LINUX" \
    cloudflared tunnel route dns "$CF_TUNNEL" "$CF_HOSTNAME_LINUX"

if [ "$HOST_TYPE" = "windows-wsl" ]; then
    check_or_fail "Failed to create DNS route for $CF_HOSTNAME_WIN" \
        cloudflared tunnel route dns "$CF_TUNNEL" "$CF_HOSTNAME_WIN"
fi

write_cloudflared_config "$TUNNEL_ID"

if systemd_usable; then
    install_cloudflared_service
fi

write_host_config
run_health_check
