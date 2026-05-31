# GPUWS

GPUWS sets up a private remote GPU workspace on either:

- Windows 11 + WSL
- Standalone Ubuntu/Debian Linux

It gives each client:

- a dedicated SSH identity on the host
- a dedicated work directory
- a dedicated Jupyter kernel

It uses:

- Cloudflare Tunnel for private connectivity
- a shared Python 3.12 `.venv` for ML packages
- `kernel-manager.sh` for per-client kernel lifecycle
- `gpuws` for host-side client management

## Repo Files

- `windows-setup.ps1`: bootstrap Windows + WSL host setup
- `linux-setup.sh`: configure the Linux host runtime
- `gpuws`: host-side client management command
- `client-setup.sh`: template used to generate client installer scripts
- `kernel-manager.sh`: internal per-client kernel manager

## Host Layout

GPUWS writes host state to:

### Linux / WSL host

- `~/.config/gpuws/host.json`
- `~/.config/gpuws/bootstrap.json`
- `~/.config/gpuws/clients.json`
- `~/.config/gpuws/templates/client-setup.sh`
- `~/.config/gpuws/generated/<client_name>-install.sh`

Host commands:

- `~/bin/gpuws`
- `~/bin/kernel-manager.sh`

Shared runtime:

- `/home/<linux_user>/gpws/`
- `/home/<linux_user>/gpws/.venv`
- `/home/<linux_user>/gpws/<client_name>/`

### Windows side

- `%USERPROFILE%\.config\gpuws\bootstrap.json`
- `%USERPROFILE%\.config\gpuws\windows-host.json`

## Requirements

Before starting, you should have:

- a Cloudflare account and domain
- permission to create or use Cloudflare tunnels for your domain
- an admin SSH public key from the machine you will use to access the host
- Ubuntu/Debian on Linux, or Windows 11 with WSL support

## Core Concepts

GPUWS now treats these as two separate pieces of Cloudflare identity:

- `host_label`
- `tunnel name`

They are not the same thing.

`host_label` controls the public hostname:

- Linux hostname: `<host_label>.<cf_domain>`
- Windows hostname in WSL mode: `<host_label>-win.<cf_domain>`

`tunnel name` controls the Cloudflare tunnel object:

- example: `gpuws`
- example: `gpuws-test`

This separation is important for side-by-side WSL setups. Multiple WSL environments should use different:

- `host_label`
- `tunnel name`

## Installation

### Option 1: Windows 11 + WSL

Run PowerShell as Administrator.

Run:

```powershell
irm https://raw.githubusercontent.com/rleyvasal/gpuws/main/windows-setup.ps1 | iex
```

The script will:

- install or detect WSL
- ask for your WSL distro
- ask for a `host_label`
- ask for Linux SSH port and Windows SSH port
- ask for your admin SSH public key
- ask for your Cloudflare domain and tunnel name
- configure Windows OpenSSH
- configure Windows firewall
- disable Windows sleep / WSL idle timeout
- validate `sshd_config` before restart, with rollback on failure
- save:
  - `%USERPROFILE%\.config\gpuws\bootstrap.json`
  - `%USERPROFILE%\.config\gpuws\windows-host.json`

If WSL user setup is not complete yet, the script will stop and print the exact commands to:

1. copy `bootstrap.json` into WSL
2. run `linux-setup.sh` inside WSL

If WSL is already ready, the script copies bootstrap config into WSL for you.

Then, inside WSL, run:

```bash
curl -fsSL https://raw.githubusercontent.com/rleyvasal/gpuws/main/linux-setup.sh -o /tmp/linux-setup.sh && bash /tmp/linux-setup.sh
```

### Option 2: Standalone Linux

On Ubuntu/Debian, run:

```bash
curl -fsSL https://raw.githubusercontent.com/rleyvasal/gpuws/main/linux-setup.sh -o /tmp/linux-setup.sh && bash /tmp/linux-setup.sh
```

The script will ask for:

- your admin SSH public key
- `host_label`
- Linux SSH port
- Cloudflare domain
- Cloudflare tunnel name

In WSL mode, it may also confirm:

- Windows SSH port

Defaults are shown where applicable. Press Enter to accept defaults or enter different values.

## What `linux-setup.sh` Does

`linux-setup.sh` is the real host setup for both:

- WSL Linux side
- standalone Linux

It will:

1. detect environment
2. load `host.json` or `bootstrap.json` if present
3. install dependencies
4. configure Linux SSH
5. add the admin SSH public key to `authorized_keys` for initial host access
6. prepare `/home/<linux_user>/gpws/`
7. install `uv`
8. create the shared Python 3.12 `.venv`
9. install ML packages into the shared `.venv`
10. install:
   - `~/bin/kernel-manager.sh`
   - `~/bin/gpuws`
   - `~/.config/gpuws/templates/client-setup.sh`
11. configure Cloudflare Tunnel
12. write `~/.config/gpuws/host.json`
13. initialize `~/.config/gpuws/clients.json`
14. run a host health check

Notes:

- The SSH public key requested during host setup is an admin SSH public key for initial host access.
- It does not automatically create a managed GPUWS client record.
- Managed clients are added later with `gpuws client add`.

Cloudflare authentication note:

- Before using the URL shown by `cloudflared tunnel login`, make sure you are already signed in to the correct Cloudflare account in your browser.
- If the first browser redirect only signs you in, open the displayed login URL again after login to complete tunnel authorization.
- Approve the selected domain when Cloudflare asks you to authorize it.

Cloudflare DNS note:

- GPUWS now fails loudly if the selected hostname already exists in Cloudflare DNS.
- If setup fails because a hostname already exists, either:
  - choose a different `host_label`
  - or remove/reassign the old DNS record if you intentionally want to reuse that hostname

After success, the next step is:

```bash
gpuws client add
```

## Verify Host Setup

Run:

```bash
gpuws host status
```

You should see:

- host type
- host label
- tunnel name
- Linux SSH endpoint
- Windows SSH endpoint if using WSL
- shared root dir
- shared venv path
- registered client count
- checks for:
  - `host.json`
  - `clients.json`
  - `kernel-manager.sh`
  - client template
  - shared venv
  - `cloudflared`
  - `sshd`
  - Cloudflare config

## Add a Client

On the host, run:

```bash
gpuws client add
```

You will be prompted for:

- client name
- client SSH public key

GPUWS will:

- normalize the client name
- add the public key to `~/.ssh/authorized_keys`
- create `/home/<linux_user>/gpws/<client_name>/`
- create a dedicated kernel for that client
- record the client in `~/.config/gpuws/clients.json`
- generate:
  - `~/.config/gpuws/generated/<client_name>-install.sh`

## List Clients

Run:

```bash
gpuws client list
```

This shows:

- client name
- work directory
- whether installer exists
- added timestamp

## Remove a Client

Run:

```bash
gpuws client remove <client_name>
```

Or skip confirmation:

```bash
gpuws client remove <client_name> --yes
```

This removes:

- the client record from `clients.json`
- the SSH key from `authorized_keys`
- the dedicated kernel
- the client work directory
- the generated installer

## Client Installation

The client only needs one file from the host:

- `~/.config/gpuws/generated/<client_name>-install.sh`

Share that installer script securely with the client.

### Moving the installer from WSL to Windows

If the host is running inside WSL, a simple way to make the installer easy to transfer is:

```bash
cp ~/.config/gpuws/generated/<client_name>-install.sh /mnt/c/Users/<windows_user>/Downloads/
```

From there, you can move it to the client machine using your preferred method, for example:

- AirDrop
- secure file share
- USB
- encrypted message or storage service

### Run on the client machine

On the client machine:

```bash
bash <client_name>-install.sh
```

The installer will:

1. install or verify `cloudflared`
2. create a stable symlink at `~/.local/bin/cloudflared`
3. ask for identity file path
4. write `~/.config/gpuws/client.json`
5. update `~/.ssh/config`
6. test `ssh gpuws-linux`
7. optionally test `ssh gpuws-windows`

Default identity file prompt:

```text
~/.ssh/id_ed25519
```

## Client Files

After client install, the client machine will have:

- `~/.config/gpuws/client.json`
- updated `~/.ssh/config`

The generated SSH config will include:

- `gpuws-linux`
- `gpuws-windows` when Windows access is configured

## End-to-End Test Order

Recommended order:

1. prepare a fresh WSL distro or clean Ubuntu environment
2. run Windows setup if using WSL
3. run Linux setup
4. run `gpuws host status`
5. run `gpuws client add`
6. inspect the generated installer
7. copy the installer from WSL to a Windows-visible path if needed
8. move the installer to the client machine
9. run the client installer
10. verify:
    - `ssh gpuws-linux`
    - optional `ssh gpuws-windows`

## Notes

- The shared ML environment is:
  - `/home/<linux_user>/gpws/.venv`
- Each client gets its own work directory:
  - `/home/<linux_user>/gpws/<client_name>/`
- Each client gets its own kernel name matching its normalized client name
- `kernel-manager.sh` remains an internal runtime tool
- `gpuws` is the user-facing host management command
- The admin SSH key used during host setup is separate from managed client records

## Troubleshooting

If Cloudflare setup fails:

```bash
cloudflared tunnel login
```

Then rerun:

```bash
bash linux-setup.sh
```

If Cloudflare DNS route creation fails because the hostname already exists:

- choose a different `host_label`
- or clean up the existing DNS record if you intend to reuse that hostname

If client SSH fails:

- confirm the private key path in `~/.config/gpuws/client.json`
- confirm the matching public key was added on the host
- confirm the host tunnel/service is running
- run:

```bash
ssh gpuws-linux
ssh -v gpuws-linux
```

If WSL handoff is incomplete:

- launch the distro once
- create the Linux user
- rerun `windows-setup.ps1`
- or use the printed copy-and-run commands
