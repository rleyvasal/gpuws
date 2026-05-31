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
    }
    catch {
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
    }
    catch {
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

function Test-SshPublicKeyFormat {
    param([string]$Key)

    if ([string]::IsNullOrWhiteSpace($Key)) { return $false }

    $parts = $Key.Trim() -split '\s+'
    if ($parts.Count -lt 2) { return $false }

    $allowed = @(
        'ssh-ed25519',
        'ssh-rsa',
        'ecdsa-sha2-nistp256',
        'ecdsa-sha2-nistp384',
        'ecdsa-sha2-nistp521'
    )

    if ($allowed -notcontains $parts[0]) { return $false }
    if ($parts[1] -notmatch '^[A-Za-z0-9+/=]+$') { return $false }

    return $true
}

function Test-PortInUseByOtherProcess {
    param([int]$Port)

    $listeners = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
    if (-not $listeners) { return $false }

    foreach ($listener in $listeners) {
        $proc = Get-Process -Id $listener.OwningProcess -ErrorAction SilentlyContinue
        if ($proc -and $proc.ProcessName -ne 'sshd') {
            return $true
        }
    }

    return $false
}

function Get-AvailableWindowsSshPort {
    param([int]$InitialPort)

    $port = $InitialPort

    while (Test-PortInUseByOtherProcess -Port $port) {
        Write-Host "Port $port is already in use by another process." -ForegroundColor Yellow
        $newPort = Read-Host "Choose a different Windows SSH port"
        if ([string]::IsNullOrWhiteSpace($newPort)) { continue }

        $parsed = 0
        if (-not [int]::TryParse($newPort, [ref]$parsed)) {
            Write-Host "Please enter a valid numeric port." -ForegroundColor Yellow
            continue
        }

        $port = $parsed
    }

    return $port
}

function Normalize-HostLabel {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) { return "" }

    $label = $Value.ToLower()
    $label = $label -replace '[^a-z0-9-]', '-'
    $label = $label -replace '-+', '-'
    $label = $label.Trim('-')
    return $label
}

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
        }
        else {
            $line
        }
    }

    if (-not $found) {
        $result += $Replacement
    }

    return ,$result
}

function Test-GpuwsWindowsHealth {
    param(
        [int]$WindowsSshPort,
        [string]$BootstrapFile,
        [string]$WindowsHostConfig,
        [string]$BootstrapInWslPath
    )

    $sshdService = Get-Service sshd -ErrorAction SilentlyContinue
    if (-not $sshdService -or $sshdService.Status -ne 'Running') {
        throw "Windows sshd service is not running"
    }

    $listener = Get-NetTCPConnection -LocalPort $WindowsSshPort -State Listen -ErrorAction SilentlyContinue
    if (-not $listener) {
        throw "Windows SSH port $WindowsSshPort is not listening"
    }

    $fwRule = Get-NetFirewallRule -DisplayName "GPUWS Windows SSH" -ErrorAction SilentlyContinue
    if (-not $fwRule) {
        throw "GPUWS Windows SSH firewall rule not found"
    }

    if (-not (Test-Path $BootstrapFile)) {
        throw "bootstrap.json not found at $BootstrapFile"
    }

    if (-not (Test-Path $WindowsHostConfig)) {
        throw "windows-host.json not found at $WindowsHostConfig"
    }

    if ($BootstrapInWslPath -and -not (Test-Path $BootstrapInWslPath)) {
        throw "bootstrap.json was not copied into WSL at $BootstrapInWslPath"
    }
}

$SETUP_LINUX_URL = "https://raw.githubusercontent.com/rleyvasal/gpuws/main/linux-setup.sh"

Write-Host ""
Write-Host "=== GPUWS PRE-FLIGHT CHECKLIST ===" -ForegroundColor Yellow
Write-Host "  1. This script prepares the Windows side for a GPUWS host using WSL." -ForegroundColor Yellow
Write-Host "  2. The admin SSH public key you provide is for initial host access." -ForegroundColor Yellow
Write-Host "  3. Managed GPUWS clients are added later from Linux using 'gpuws client add'." -ForegroundColor Yellow
Write-Host "  4. Linux setup inside WSL will handle the GPUWS runtime and Cloudflare tunnel." -ForegroundColor Yellow
Pause

$WINDOWS_USER = $env:USERNAME
$WINDOWS_HOME = $env:USERPROFILE

$GPUWS_DIR = Join-Path $WINDOWS_HOME ".config\gpuws"
$BOOTSTRAP_FILE = Join-Path $GPUWS_DIR "bootstrap.json"
$WINDOWS_HOST_CONFIG = Join-Path $GPUWS_DIR "windows-host.json"

$WSL_DISTRO = $null
$LINUX_USER = $null
$HOST_LABEL = $null
$LINUX_SSH_PORT = $null
$WINDOWS_SSH_PORT = $null
$SSH_PUBLIC_KEY = $null
$CF_DOMAIN = $null
$CF_TUNNEL = $null

if (Test-Path $BOOTSTRAP_FILE) {
    $saved = Get-Content $BOOTSTRAP_FILE -Raw | ConvertFrom-Json
    $WSL_DISTRO = $saved.wsl_distro
    $HOST_LABEL = $saved.host_label
    $LINUX_SSH_PORT = $saved.linux_ssh_port
    $WINDOWS_SSH_PORT = $saved.windows_ssh_port
    $SSH_PUBLIC_KEY = $saved.ssh_public_key
    $CF_DOMAIN = $saved.cf_domain
    $CF_TUNNEL = $saved.cf_tunnel
}

if (Test-Path $WINDOWS_HOST_CONFIG) {
    $savedHost = Get-Content $WINDOWS_HOST_CONFIG -Raw | ConvertFrom-Json
    if (-not $HOST_LABEL) { $HOST_LABEL = $savedHost.host_label }
    if (-not $WSL_DISTRO) { $WSL_DISTRO = $savedHost.wsl_distro }
    if (-not $LINUX_USER) { $LINUX_USER = $savedHost.linux_user }
}

if (-not $WSL_DISTRO) {
    $distros = Get-WSLDistros
    if ($distros.Count -eq 1) {
        $WSL_DISTRO = $distros[0]
        Write-Host "Detected WSL distro: $WSL_DISTRO" -ForegroundColor Green
    }
    elseif ($distros.Count -gt 1) {
        Write-Host "Detected WSL distros: $($distros -join ', ')" -ForegroundColor Yellow
        $WSL_DISTRO = Read-HostDefault "WSL distro" $distros[0]
    }
    else {
        $WSL_DISTRO = Read-HostDefault "WSL distro" "Ubuntu"
    }
}

if (-not $HOST_LABEL) {
    $defaultHostLabel = "gpuws-test"
    $HOST_LABEL = Normalize-HostLabel (Read-HostDefault "Host label" $defaultHostLabel)
    if ([string]::IsNullOrWhiteSpace($HOST_LABEL)) {
        throw "Host label is required"
    }
}

if (-not $LINUX_SSH_PORT) {
    $LINUX_SSH_PORT = Read-HostDefault "Linux SSH port" "2222"
}

if (-not $WINDOWS_SSH_PORT) {
    $WINDOWS_SSH_PORT = Read-HostDefault "Windows SSH port" "22"
}

$WINDOWS_SSH_PORT = Get-AvailableWindowsSshPort -InitialPort ([int]$WINDOWS_SSH_PORT)

if (-not $SSH_PUBLIC_KEY) {
    while ($true) {
        Write-Host ""
        Write-Host "Paste the admin SSH public key from the machine you will use to access this GPU host." -ForegroundColor Yellow
        Write-Host "This grants initial SSH access to the host." -ForegroundColor Yellow
        Write-Host "Example source: ~/.ssh/id_ed25519.pub on your laptop or client machine." -ForegroundColor Yellow
        $SSH_PUBLIC_KEY = Read-Host "Admin SSH public key"

        if (Test-SshPublicKeyFormat $SSH_PUBLIC_KEY) { break }

        Write-Host "Invalid admin SSH public key. Please paste a valid public key from the client machine you will use to access this host." -ForegroundColor Red
        $SSH_PUBLIC_KEY = $null
    }
}

if (-not $CF_DOMAIN) {
    $CF_DOMAIN = Read-Host "Cloudflare domain"
}

if (-not $CF_TUNNEL) {
    $CF_TUNNEL = Read-HostDefault "Tunnel name" "gpuws"
}

if (-not (Test-SshPublicKeyFormat $SSH_PUBLIC_KEY)) {
    throw "Invalid admin SSH public key"
}

if (-not (Test-Path $GPUWS_DIR)) {
    New-Item -ItemType Directory -Path $GPUWS_DIR -Force | Out-Null
}

$WSL_USER = Get-DetectedLinuxUser -Distro $WSL_DISTRO
if ($WSL_USER) {
    $LINUX_USER = $WSL_USER
}

$bootstrapObject = @{
    host_type        = "windows-wsl"
    host_label       = $HOST_LABEL
    windows_user     = $WINDOWS_USER
    wsl_distro       = $WSL_DISTRO
    linux_ssh_port   = [int]$LINUX_SSH_PORT
    windows_ssh_port = [int]$WINDOWS_SSH_PORT
    ssh_public_key   = $SSH_PUBLIC_KEY
    cf_domain        = $CF_DOMAIN
    cf_tunnel        = $CF_TUNNEL
}

$windowsHostObject = @{
    host_type        = "windows-wsl"
    host_label       = $HOST_LABEL
    windows_user     = $WINDOWS_USER
    wsl_distro       = $WSL_DISTRO
    linux_user       = $LINUX_USER
    linux_ssh_port   = [int]$LINUX_SSH_PORT
    windows_ssh_port = [int]$WINDOWS_SSH_PORT
    cf_domain        = $CF_DOMAIN
    cf_tunnel        = $CF_TUNNEL
    cf_hostname_linux = "$HOST_LABEL.$CF_DOMAIN"
    cf_hostname_win   = "$HOST_LABEL-win.$CF_DOMAIN"
}

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($BOOTSTRAP_FILE, ($bootstrapObject | ConvertTo-Json -Depth 4), $utf8NoBom)
[System.IO.File]::WriteAllText($WINDOWS_HOST_CONFIG, ($windowsHostObject | ConvertTo-Json -Depth 4), $utf8NoBom)

Write-Host ""
Write-Host "GPUWS bootstrap config saved to $BOOTSTRAP_FILE" -ForegroundColor Green
Write-Host "GPUWS Windows host config saved to $WINDOWS_HOST_CONFIG" -ForegroundColor Green

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
            }
            catch {
                Write-Host "Could not verify $feat; continuing." -ForegroundColor Yellow
            }
        }

        wsl --install -d $WSL_DISTRO
    }
    else {
        Write-Host "$WSL_DISTRO already installed, skipping." -ForegroundColor Green
    }
}

Run-Step "GPUWS Step 2: Install and configure OpenSSH" {
    $sshState = "Unknown"
    try {
        $sshState = Get-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0 | Select-Object -ExpandProperty State
    }
    catch {
        Write-Host "Could not check OpenSSH state, attempting install anyway..." -ForegroundColor Yellow
    }

    if ($sshState -ne 'Installed') {
        Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0
    }
    else {
        Write-Host "OpenSSH already installed, skipping." -ForegroundColor Green
    }

    ssh-keygen -A

    $sshdConfig = "C:\ProgramData\ssh\sshd_config"
    $backupConfig = "C:\ProgramData\ssh\sshd_config.gpuws.bak"

    if (-not (Test-Path $sshdConfig)) {
        New-Item -ItemType File -Path $sshdConfig -Force | Out-Null
    }

    Copy-Item $sshdConfig $backupConfig -Force
    Write-Host "Backed up sshd_config to $backupConfig" -ForegroundColor Yellow

    $lines = Get-Content $sshdConfig -ErrorAction SilentlyContinue
    if (-not $lines) { $lines = @() }

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

    try {
        & "$env:WINDIR\System32\OpenSSH\sshd.exe" -t
        if ($LASTEXITCODE -ne 0) {
            throw "sshd config validation failed"
        }

        Set-Service -Name sshd -StartupType Automatic
        if ((Get-Service sshd).Status -ne 'Running') {
            Start-Service sshd
        }
        Restart-Service sshd -ErrorAction Stop
    }
    catch {
        Copy-Item $backupConfig $sshdConfig -Force
        throw "Failed to validate or restart sshd. Restored previous sshd_config. $($_.Exception.Message)"
    }
}

Run-Step "GPUWS Step 3: Authorize admin SSH key" {
    if (-not (Test-SshPublicKeyFormat $SSH_PUBLIC_KEY)) {
        throw "Invalid admin SSH public key"
    }

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
        @{ Name = "GPUWS Windows SSH"; Port = $WINDOWS_SSH_PORT; Remote = "Any" },
        @{ Name = "GPUWS Linux SSH"; Port = $LINUX_SSH_PORT; Remote = "Any" }
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
if ($WSL_USER) {
    $LINUX_USER = $WSL_USER

    $windowsHostObject = @{
        host_type         = "windows-wsl"
        host_label        = $HOST_LABEL
        windows_user      = $WINDOWS_USER
        wsl_distro        = $WSL_DISTRO
        linux_user        = $LINUX_USER
        linux_ssh_port    = [int]$LINUX_SSH_PORT
        windows_ssh_port  = [int]$WINDOWS_SSH_PORT
        cf_domain         = $CF_DOMAIN
        cf_tunnel         = $CF_TUNNEL
        cf_hostname_linux = "$HOST_LABEL.$CF_DOMAIN"
        cf_hostname_win   = "$HOST_LABEL-win.$CF_DOMAIN"
    }
    [System.IO.File]::WriteAllText($WINDOWS_HOST_CONFIG, ($windowsHostObject | ConvertTo-Json -Depth 4), $utf8NoBom)
}

if ($needsReboot) {
    Write-Host ""
    Write-Host "GPUWS note: WSL setup appears to require a reboot before Linux handoff." -ForegroundColor Yellow
}

$bootstrapInWslPath = $null

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
    $bootstrapInWslPath = "\\wsl$\$WSL_DISTRO\home\$WSL_USER\.config\gpuws\bootstrap.json"
}

Run-Step "GPUWS Step 7: Health check" {
    Test-GpuwsWindowsHealth `
        -WindowsSshPort ([int]$WINDOWS_SSH_PORT) `
        -BootstrapFile $BOOTSTRAP_FILE `
        -WindowsHostConfig $WINDOWS_HOST_CONFIG `
        -BootstrapInWslPath $bootstrapInWslPath
}

Write-Host ""
Write-Host "GPUWS Windows side is ready." -ForegroundColor Green
Write-Host "Bootstrap copied into WSL." -ForegroundColor Green
Write-Host "Admin SSH key saved for initial host access." -ForegroundColor Green
Write-Host "Managed GPUWS clients are added later from Linux using 'gpuws client add'." -ForegroundColor Green
Write-Host ""
Write-Host "Host label: $HOST_LABEL" -ForegroundColor Cyan
Write-Host "Tunnel name: $CF_TUNNEL" -ForegroundColor Cyan
Write-Host "Linux hostname: $HOST_LABEL.$CF_DOMAIN" -ForegroundColor Cyan
Write-Host "Windows hostname: $HOST_LABEL-win.$CF_DOMAIN" -ForegroundColor Cyan
Write-Host ""
Write-Host "Next step inside WSL:" -ForegroundColor Cyan
Write-Host "  curl -fsSL '$SETUP_LINUX_URL' -o /tmp/linux-setup.sh && bash /tmp/linux-setup.sh" -ForegroundColor White
Write-Host ""
Write-Host "Bootstrap file:" -ForegroundColor Cyan
Write-Host "  $BOOTSTRAP_FILE" -ForegroundColor White
Write-Host "Windows host config:" -ForegroundColor Cyan
Write-Host "  $WINDOWS_HOST_CONFIG" -ForegroundColor White
