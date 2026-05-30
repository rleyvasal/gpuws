function Run-Step {
    param(
        [string]$Name,
        [scriptblock]$Action
    )

    Write-Host ""
    Write-Host "=== $Name ===" -ForegroundColor Cyan

    try {
        & $Action
        if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) {
            throw "Step failed with exit code $LASTEXITCODE"
        }
        Write-Host "$Name completed." -ForegroundColor Green
    } catch {
        Write-Host "$Name failed: $($_.Exception.Message)" -ForegroundColor Red
        Pause
        exit 1
    }
}

function Read-HostDefault {
    param(
        [string]$Prompt,
        [string]$Default
    )

    $value = Read-Host "$Prompt [$Default]"
    if ([string]::IsNullOrWhiteSpace($value)) { return $Default }
    return $value
}

function Get-WSLDistros {
    $output = wsl --list --quiet 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $output) { return @() }

    return $output |
        ForEach-Object { $_.Trim() } |
        ForEach-Object { $_.Trim([char]0) } |
        Where-Object { $_ -ne '' -and $_ -notmatch '^docker-desktop' }
}

function Get-DetectedLinuxUser {
    param([string]$Distro)

    try {
        $user = wsl -d $Distro -- bash -lc "whoami" 2>$null
        if (-not $user) { return $null }
        $user = $user.Trim()
        if ([string]::IsNullOrWhiteSpace($user) -or $user -eq "root") { return $null }
        return $user
    } catch {
        return $null
    }
}

function Test-RebootRequired {
    $paths = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending",
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired"
    )
    foreach ($path in $paths) {
        if (Test-Path $path) { return $true }
    }
    return $false
}

$SETUP_LINUX_URL = "https://raw.githubusercontent.com/rleyvasal/gpuws/main/linux-setup.sh"

Write-Host "=== GPUWS Windows Host Setup ===" -ForegroundColor Cyan
Write-Host "Press Enter to accept defaults or enter different values." -ForegroundColor Yellow

$WINDOWS_USER = $env:USERNAME
$WINDOWS_HOME = $env:USERPROFILE

$GPUWS_DIR = Join-Path $WINDOWS_HOME ".config\gpuws"
$BOOTSTRAP_FILE = Join-Path $GPUWS_DIR "bootstrap.json"

$WSL_DISTRO = $null
$LINUX_SSH_PORT = $null
$WINDOWS_SSH_PORT = $null
$SSH_PUBLIC_KEY = $null
$CF_DOMAIN = $null
$CF_TUNNEL = $null

if (Test-Path $BOOTSTRAP_FILE) {
    $saved = Get-Content $BOOTSTRAP_FILE -Raw | ConvertFrom-Json
    $WSL_DISTRO = $saved.wsl_distro
    $LINUX_SSH_PORT = $saved.linux_ssh_port
    $WINDOWS_SSH_PORT = $saved.windows_ssh_port
    $SSH_PUBLIC_KEY = $saved.ssh_public_key
    $CF_DOMAIN = $saved.cf_domain
    $CF_TUNNEL = $saved.cf_tunnel
}

if (-not $WSL_DISTRO) {
    $distros = Get-WSLDistros
    if ($distros.Count -eq 1) {
        $WSL_DISTRO = $distros[0]
        Write-Host "Detected WSL distro: $WSL_DISTRO" -ForegroundColor Green
    } elseif ($distros.Count -gt 1) {
        Write-Host "Detected WSL distros: $($distros -join ', ')" -ForegroundColor Yellow
        $WSL_DISTRO = Read-HostDefault "WSL distro" $distros[0]
    } else {
        $WSL_DISTRO = Read-HostDefault "WSL distro" "Ubuntu"
    }
}

if (-not $LINUX_SSH_PORT) {
    $LINUX_SSH_PORT = Read-HostDefault "Linux SSH port" "2222"
}
if (-not $WINDOWS_SSH_PORT) {
    $WINDOWS_SSH_PORT = Read-HostDefault "Windows SSH port" "22"
}
if (-not $SSH_PUBLIC_KEY) {
    Write-Host ""
    Write-Host "Paste your SSH public key:" -ForegroundColor Yellow
    $SSH_PUBLIC_KEY = Read-Host "SSH public key"
}
if (-not $CF_DOMAIN) {
    $CF_DOMAIN = Read-Host "Cloudflare domain"
}
if (-not $CF_TUNNEL) {
    $CF_TUNNEL = Read-HostDefault "Tunnel name" "gpuws"
}

if (-not (Test-Path $GPUWS_DIR)) {
    New-Item -ItemType Directory -Path $GPUWS_DIR -Force | Out-Null
}

$bootstrapObject = @{
    host_type        = "windows-wsl"
    windows_user     = $WINDOWS_USER
    wsl_distro       = $WSL_DISTRO
    linux_ssh_port   = [int]$LINUX_SSH_PORT
    windows_ssh_port = [int]$WINDOWS_SSH_PORT
    ssh_public_key   = $SSH_PUBLIC_KEY
    cf_domain        = $CF_DOMAIN
    cf_tunnel        = $CF_TUNNEL
}
$bootstrapJson = $bootstrapObject | ConvertTo-Json -Depth 3
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($BOOTSTRAP_FILE, $bootstrapJson, $utf8NoBom)

Write-Host ""
Write-Host "GPUWS bootstrap config saved to $BOOTSTRAP_FILE" -ForegroundColor Green

Run-Step "GPUWS Step 1: Install WSL and distro" {
    $distroInstalled = $false
    $output = wsl --list --quiet 2>$null
    if ($LASTEXITCODE -eq 0 -and $output) {
        $cleaned = $output | ForEach-Object { $_.Trim() } | ForEach-Object { $_.Trim([char]0) } | Where-Object { $_ -ne '' }
        $distroInstalled = $cleaned -contains $WSL_DISTRO
    }

    if (-not $distroInstalled) {
        $features = @("VirtualMachinePlatform", "Microsoft-Windows-Subsystem-Linux")
        foreach ($feat in $features) {
            try {
                $state = (Get-WindowsOptionalFeature -Online -FeatureName $feat).State
                if ($state -ne "Enabled") {
                    Write-Host "Enabling $feat..." -ForegroundColor Yellow
                    Enable-WindowsOptionalFeature -Online -FeatureName $feat -All -NoRestart | Out-Null
                }
            } catch {
                Write-Host "Could not verify $feat; continuing." -ForegroundColor Yellow
            }
        }

        wsl --install -d $WSL_DISTRO
    } else {
        Write-Host "$WSL_DISTRO already installed, skipping." -ForegroundColor Green
    }
}
Run-Step "GPUWS Step 2: Install and configure OpenSSH" {
    $sshState = "Unknown"
    try {
        $sshState = Get-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0 | Select-Object -ExpandProperty State
    } catch {
        Write-Host "Could not check OpenSSH state, attempting install anyway..." -ForegroundColor Yellow
    }

    if ($sshState -ne 'Installed') {
        Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0
    } else {
        Write-Host "OpenSSH already installed, skipping." -ForegroundColor Green
    }

    ssh-keygen -A

    $sshdConfig = "C:\ProgramData\ssh\sshd_config"
    $backupConfig = "C:\ProgramData\ssh\sshd_config.gpuws.bak"

    if (-not (Test-Path $sshdConfig)) {
        New-Item -ItemType File -Path $sshdConfig -Force | Out-Null
    }

    if (-not (Test-Path $backupConfig)) {
        Copy-Item $sshdConfig $backupConfig -Force
        Write-Host "Backed up sshd_config to $backupConfig" -ForegroundColor Yellow
    }

    $lines = Get-Content $sshdConfig -ErrorAction SilentlyContinue
    if (-not $lines) { $lines = @() }

    function Set-Or-AppendLine {
        param(
            [string[]]$InputLines,
            [string]$Pattern,
            [string]$Replacement
        )

        $found = $false
        $result = foreach ($line in $InputLines) {
            if ($line -match $Pattern) {
                $found = $true
                $Replacement
            } else {
                $line
            }
        }

        if (-not $found) {
            $result += $Replacement
        }

        return ,$result
    }

    $lines = Set-Or-AppendLine -InputLines $lines -Pattern '^\s*#?\s*Port\s+' -Replacement "Port $WINDOWS_SSH_PORT"
    $lines = Set-Or-AppendLine -InputLines $lines -Pattern '^\s*#?\s*PubkeyAuthentication\s+' -Replacement "PubkeyAuthentication yes"
    $lines = Set-Or-AppendLine -InputLines $lines -Pattern '^\s*#?\s*PasswordAuthentication\s+' -Replacement "PasswordAuthentication no"

    $content = ($lines -join "`n").TrimEnd()

    $content = [regex]::Replace(
        $content,
        '(?ms)^\s*Match Group administrators\s*\r?\n\s*AuthorizedKeysFile __PROGRAMDATA__/ssh/administrators_authorized_keys\s*',
        ''
    ).TrimEnd()

    $adminBlock = @"

Match Group administrators
       AuthorizedKeysFile __PROGRAMDATA__/ssh/administrators_authorized_keys
"@

    $content = ($content + $adminBlock).Trim() + "`r`n"
    Set-Content -Path $sshdConfig -Value $content

    Set-Service -Name sshd -StartupType Automatic
    Start-Service sshd
    Restart-Service sshd
}

Run-Step "GPUWS Step 3: Add SSH key" {
    $adminKeyFile = "C:\ProgramData\ssh\administrators_authorized_keys"
    if (-not (Test-Path "C:\ProgramData\ssh")) {
        New-Item -ItemType Directory -Path "C:\ProgramData\ssh" | Out-Null
    }

    $existingKeys = if (Test-Path $adminKeyFile) { Get-Content $adminKeyFile } else { @() }
    if ($existingKeys -notcontains $SSH_PUBLIC_KEY) {
        [System.IO.File]::AppendAllText($adminKeyFile, $SSH_PUBLIC_KEY + "`n")
    }

    icacls $adminKeyFile /inheritance:r /grant "SYSTEM:F" /grant "Administrators:F" | Out-Null
}

Run-Step "GPUWS Step 4: Configure firewall" {
    $rules = @(
        @{ Name="GPUWS OpenSSH Inbound"; Port=$WINDOWS_SSH_PORT; Remote="Any" },
        @{ Name="GPUWS Linux SSH Inbound"; Port=$LINUX_SSH_PORT; Remote="Any" }
    )

    foreach ($rule in $rules) {
        if (-not (Get-NetFirewallRule -DisplayName $rule.Name -ErrorAction SilentlyContinue)) {
            New-NetFirewallRule -DisplayName $rule.Name -Direction Inbound -Protocol TCP `
                -LocalPort $rule.Port -RemoteAddress $rule.Remote -Action Allow | Out-Null
        }
    }
}

Run-Step "GPUWS Step 5: Disable sleep and WSL idle timeout" {
    powercfg /change standby-timeout-ac 0
    powercfg /change standby-timeout-dc 0
    powercfg /change hibernate-timeout-ac 0
    powercfg /change hibernate-timeout-dc 0

    $wslConfig = Join-Path $WINDOWS_HOME ".wslconfig"
    $content = @"
[general]
instanceIdleTimeout=-1

[wsl2]
vmIdleTimeout=-1
"@
    Set-Content $wslConfig $content
}

$needsReboot = Test-RebootRequired
$WSL_USER = Get-DetectedLinuxUser -Distro $WSL_DISTRO

if ($needsReboot) {
    Write-Host ""
    Write-Host "GPUWS note: WSL setup appears to require a reboot before Linux handoff." -ForegroundColor Yellow
}

if (-not $WSL_USER) {
    Write-Host ""
    Write-Host "Could not detect a non-root Linux user in $WSL_DISTRO." -ForegroundColor Yellow
    Write-Host "Launch the distro once, create your Linux user, then continue with:" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "wsl -d $WSL_DISTRO -- bash -lc `"mkdir -p ~/.config/gpuws && cp /mnt/c/Users/$WINDOWS_USER/.config/gpuws/bootstrap.json ~/.config/gpuws/bootstrap.json && chmod 600 ~/.config/gpuws/bootstrap.json`"" -ForegroundColor Cyan
    Write-Host "wsl -d $WSL_DISTRO -- bash -lc `"curl -fsSL '$SETUP_LINUX_URL' -o /tmp/linux-setup.sh && bash /tmp/linux-setup.sh`"" -ForegroundColor Cyan
    Pause
    exit 0
}

Run-Step "GPUWS Step 6: Copy bootstrap config into WSL" {
    wsl -d $WSL_DISTRO -u $WSL_USER -- bash -lc "mkdir -p ~/.config/gpuws && cp /mnt/c/Users/$WINDOWS_USER/.config/gpuws/bootstrap.json ~/.config/gpuws/bootstrap.json && chmod 600 ~/.config/gpuws/bootstrap.json"
}

Write-Host ""
Write-Host "GPUWS Windows side is ready." -ForegroundColor Green
Write-Host "Bootstrap copied into WSL." -ForegroundColor Green
Write-Host ""
Write-Host "Next step inside WSL:" -ForegroundColor Cyan
Write-Host "  curl -fsSL '$SETUP_LINUX_URL' -o /tmp/linux-setup.sh && bash /tmp/linux-setup.sh" -ForegroundColor White
Write-Host ""
Write-Host "Bootstrap file:" -ForegroundColor Cyan
Write-Host "  $BOOTSTRAP_FILE" -ForegroundColor White
