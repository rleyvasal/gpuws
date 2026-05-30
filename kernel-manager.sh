#!/usr/bin/env bash
set -euo pipefail

REGISTRY="${HOME}/.kernels/registry.json"
KERNELS_DIR="${HOME}/.kernels"
RUNTIME_DIR="${HOME}/.local/share/jupyter/runtime"
WORK_DIR_DEFAULT="${HOME}/gpu_dev_projects"
INACTIVITY_HOURS="${INACTIVITY_HOURS:-24}"

log() {
    echo "$*"
}

fail() {
    echo "Error: $*" >&2
    exit 1
}

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || fail "Missing required command: $1"
}

systemd_usable() {
    command -v systemctl >/dev/null 2>&1 || return 1
    [ -d /run/systemd/system ] || return 1
    systemctl list-units >/dev/null 2>&1 || return 1
}

require_systemd() {
    systemd_usable || fail "usable systemd is required for kernel management"
}

ensure_dirs() {
    mkdir -p "$KERNELS_DIR" "$RUNTIME_DIR" "$WORK_DIR_DEFAULT" "$HOME/bin"
    [ -f "$REGISTRY" ] || echo '{}' > "$REGISTRY"
}

sanitize_name() {
    local value="${1:-}"
    value="$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9._-]+/-/g; s/^-+//; s/-+$//')"
    printf '%s' "$value"
}

random_suffix() {
    if command -v openssl >/dev/null 2>&1; then
        openssl rand -hex 3
    else
        date +%s | tail -c 7
    fi
}

default_kernel_name() {
    local seed
    seed="${KERNEL_CLIENT_NAME:-${KERNEL_DEVICE_NAME:-$(hostname)}}"
    seed="$(sanitize_name "$seed")"
    [ -n "$seed" ] || seed="kernel"
    printf '%s-%s\n' "$seed" "$(random_suffix)"
}

service_name_for() {
    printf 'ipykernel-%s\n' "$1"
}

kernel_exists() {
    local name="$1"
    python3 - "$REGISTRY" "$name" <<'PY'
import json, sys
path, name = sys.argv[1], sys.argv[2]
with open(path, encoding="utf-8") as f:
    data = json.load(f)
sys.exit(0 if name in data else 1)
PY
}

next_port_base() {
    python3 - "$REGISTRY" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as f:
    data = json.load(f)
bases = [v.get("port_base", 56991) for v in data.values()]
print((max(bases) if bases else 56991) + 10)
PY
}

read_registry_field() {
    local name="$1"
    local field="$2"
    python3 - "$REGISTRY" "$name" "$field" <<'PY'
import json, sys
path, name, field = sys.argv[1:]
with open(path, encoding="utf-8") as f:
    data = json.load(f)
value = data.get(name, {}).get(field, "")
print(value if value is not None else "")
PY
}

write_registry_entry() {
    local name="$1"
    local port_base="$2"
    local conn_file="$3"
    local venv_python="$4"
    local work_dir="$5"
    local service_name="$6"

    python3 - "$REGISTRY" "$name" "$port_base" "$conn_file" "$venv_python" "$work_dir" "$service_name" <<'PY'
import json, sys, time
path, name, port_base, conn_file, venv_python, work_dir, service_name = sys.argv[1:]
with open(path, encoding="utf-8") as f:
    data = json.load(f)
now = time.time()
data[name] = {
    "port_base": int(port_base),
    "conn_file": conn_file,
    "venv_python": venv_python,
    "work_dir": work_dir,
    "service_name": service_name,
    "created": now,
    "last_seen": now
}
with open(path, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2)
PY
}

remove_registry_entry() {
    local name="$1"
    python3 - "$REGISTRY" "$name" <<'PY'
import json, sys
path, name = sys.argv[1], sys.argv[2]
with open(path, encoding="utf-8") as f:
    data = json.load(f)
data.pop(name, None)
with open(path, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2)
PY
}

create_connection_file() {
    local port_base="$1"
    local conn_file="$2"
    local key
    key="$(python3 -c 'import uuid; print(uuid.uuid4())')"

    cat > "$conn_file" <<EOF
{
  "shell_port": $((port_base)),
  "iopub_port": $((port_base + 1)),
  "stdin_port": $((port_base + 2)),
  "control_port": $((port_base + 3)),
  "hb_port": $((port_base + 4)),
  "ip": "127.0.0.1",
  "key": "$key",
  "transport": "tcp",
  "signature_scheme": "hmac-sha256",
  "kernel_name": "python3"
}
EOF

    chmod 600 "$conn_file"
}

create_service() {
    local service_name="$1"
    local linux_user="$2"
    local work_dir="$3"
    local venv_python="$4"
    local conn_file="$5"

    sudo tee "/etc/systemd/system/${service_name}.service" > /dev/null <<EOF
[Unit]
Description=Persistent IPython Kernel (${service_name})
After=network.target

[Service]
User=${linux_user}
WorkingDirectory=${work_dir}
ExecStart=${venv_python} -m ipykernel_launcher -f ${conn_file}
Restart=always
RestartSec=5
Environment=PATH=${HOME}/.local/bin:${HOME}/.cargo/bin:${HOME}/bin:/usr/local/bin:/usr/bin:/bin

[Install]
WantedBy=multi-user.target
EOF

    sudo systemctl daemon-reload
    sudo systemctl enable "$service_name"
    sudo systemctl restart "$service_name"
}

remove_service() {
    local service_name="$1"
    sudo systemctl stop "$service_name" 2>/dev/null || true
    sudo systemctl disable "$service_name" 2>/dev/null || true
    sudo rm -f "/etc/systemd/system/${service_name}.service"
    sudo systemctl daemon-reload
}

cmd_create() {
    local requested_name="${2:-}"
    local venv_python="${3:-/usr/bin/python3}"
    local work_dir="${4:-$WORK_DIR_DEFAULT}"
    local linux_user
    local name
    local port_base
    local conn_file
    local service_name

    linux_user="$(whoami)"
    mkdir -p "$work_dir"

    if [ -n "$requested_name" ]; then
        name="$(sanitize_name "$requested_name")"
    else
        name="$(default_kernel_name)"
    fi

    [ -n "$name" ] || fail "Could not determine kernel name"
    [ -x "$venv_python" ] || fail "Python executable not found: $venv_python"

    if kernel_exists "$name"; then
        log "Kernel '$name' already exists"
        exit 0
    fi

    port_base="$(next_port_base)"
    conn_file="${RUNTIME_DIR}/kernel-${name}.json"
    service_name="$(service_name_for "$name")"

    create_connection_file "$port_base" "$conn_file"
    create_service "$service_name" "$linux_user" "$work_dir" "$venv_python" "$conn_file"
    write_registry_entry "$name" "$port_base" "$conn_file" "$venv_python" "$work_dir" "$service_name"

    log "Kernel '$name' created"
    log "Connection file: $conn_file"
    log "Service: $service_name"
    log "Working directory: $work_dir"
    cat "$conn_file"
}

cmd_delete() {
    local name="${2:-}"
    local service_name
    local conn_file

    [ -n "$name" ] || fail "Usage: $0 delete <name>"
    kernel_exists "$name" || fail "Kernel '$name' not found"

    service_name="$(read_registry_field "$name" "service_name")"
    conn_file="$(read_registry_field "$name" "conn_file")"

    [ -n "$service_name" ] && remove_service "$service_name"
    [ -n "$conn_file" ] && rm -f "$conn_file"
    remove_registry_entry "$name"

    log "Kernel '$name' deleted"
}

cmd_list() {
    python3 - "$REGISTRY" <<'PY'
import json, sys, subprocess
with open(sys.argv[1], encoding="utf-8") as f:
    data = json.load(f)

if not data:
    print("No kernels registered")
    raise SystemExit(0)

print(f"{'NAME':24} {'STATUS':10} {'PORTS':15} {'WORK_DIR'}")
for name, info in sorted(data.items()):
    service = info.get("service_name", "")
    result = subprocess.run(["systemctl", "is-active", service], capture_output=True, text=True)
    status = result.stdout.strip() or "unknown"
    base = info.get("port_base", 0)
    ports = f"{base}-{base+4}"
    print(f"{name:24} {status:10} {ports:15} {info.get('work_dir','')}")
PY
}

cmd_touch() {
    local name="${2:-}"
    [ -n "$name" ] || fail "Usage: $0 touch <name>"

    python3 - "$REGISTRY" "$name" <<'PY'
import json, sys, time
path, name = sys.argv[1], sys.argv[2]
with open(path, encoding="utf-8") as f:
    data = json.load(f)
if name not in data:
    print(f"Kernel '{name}' not found", file=sys.stderr)
    raise SystemExit(1)
data[name]["last_seen"] = time.time()
with open(path, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2)
PY

    log "Kernel '$name' touched"
}

cmd_status() {
    local name="${2:-}"
    [ -n "$name" ] || fail "Usage: $0 status <name>"

    python3 - "$REGISTRY" "$name" <<'PY'
import json, sys, subprocess
path, name = sys.argv[1], sys.argv[2]
with open(path, encoding="utf-8") as f:
    data = json.load(f)
info = data.get(name)
if not info:
    print(f"Kernel '{name}' not found", file=sys.stderr)
    raise SystemExit(1)
service = info.get("service_name", "")
result = subprocess.run(["systemctl", "is-active", service], capture_output=True, text=True)
info["service_status"] = result.stdout.strip() or "unknown"
print(json.dumps(info, indent=2))
PY
}

cmd_cleanup() {
    python3 - "$REGISTRY" "$INACTIVITY_HOURS" <<'PY' | while read -r name; do
import json, sys, time
path, hours = sys.argv[1], int(sys.argv[2])
with open(path, encoding="utf-8") as f:
    data = json.load(f)
cutoff = time.time() - (hours * 3600)
for name, info in sorted(data.items()):
    if info.get("last_seen", 0) < cutoff:
        print(name)
PY
        [ -n "$name" ] || continue
        log "Removing inactive kernel: $name"
        cmd_delete cleanup "$name"
    done
}

usage() {
    cat <<EOF
Usage:
  $0 create [name] [python_path] [work_dir]
  $0 delete <name>
  $0 list
  $0 touch <name>
  $0 status <name>
  $0 cleanup
EOF
}

main() {
    require_cmd python3
    require_systemd
    ensure_dirs

    case "${1:-}" in
        create)  cmd_create "$@" ;;
        delete)  cmd_delete "$@" ;;
        list)    cmd_list ;;
        touch)   cmd_touch "$@" ;;
        status)  cmd_status "$@" ;;
        cleanup) cmd_cleanup ;;
        *)       usage; exit 1 ;;
    esac
}

main "$@"
