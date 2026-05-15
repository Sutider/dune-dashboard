# Dune Awakening Dashboard - Unified Launcher
# This script handles both setup and starting the dashboard.
# Run this script and choose what you want to do.

$ErrorActionPreference = "Continue"

$ProjectRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location -LiteralPath $ProjectRoot

# ── Helper Functions ──────────────────────────────────────────────────

function Show-Banner {
    Write-Host ""
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host "  Dune Awakening Dashboard" -ForegroundColor Cyan
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host ""
}

function Show-Menu {
    Write-Host "  What would you like to do?" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  [1] Start Dashboard" -ForegroundColor White
    Write-Host "      Launch the dashboard web interface." -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  [2] Run Setup" -ForegroundColor White
    Write-Host "      Configure the dashboard for the first time, or reconfigure." -ForegroundColor DarkGray
    Write-Host "      WARNING: Re-running setup will wipe your current settings." -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  [3] Run Diagnostics" -ForegroundColor White
    Write-Host "      Check your system for common issues that could block the dashboard." -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  [Q] Quit" -ForegroundColor White
    Write-Host ""
}

function Test-Python {
    try {
        $pythonVersion = python --version 2>&1
        Write-Host "  Python: $pythonVersion" -ForegroundColor Green
        return $true
    } catch {
        Write-Host "  Python: NOT FOUND" -ForegroundColor Red
        Write-Host ""
        Write-Host "  Python is required but not found on your system." -ForegroundColor Red
        Write-Host "  Please install Python 3.8 or later from https://www.python.org/downloads/" -ForegroundColor Yellow
        Write-Host ""
        Write-Host "  During installation, make sure to check:" -ForegroundColor Yellow
        Write-Host "    [x] Add Python to PATH" -ForegroundColor Yellow
        Write-Host ""
        return $false
    }
}

function Test-Dependencies {
    Write-Host "  Checking Python dependencies..." -ForegroundColor Yellow
    $missing = @()
    $required = @('flask', 'flask_socketio', 'yaml', 'flask_login', 'flask_wtf', 'flask_limiter', 'paramiko', 'argon2', 'cryptography')
    foreach ($mod in $required) {
        $result = python -c "import $mod" 2>$null
        if ($LASTEXITCODE -ne 0) {
            $missing += $mod
        }
    }
    if ($missing.Count -gt 0) {
        Write-Host "  Missing packages: $($missing -join ', ')" -ForegroundColor Yellow
        Write-Host "  Installing dependencies..." -ForegroundColor Yellow
        pip install -r (Join-Path $ProjectRoot "requirements.txt") --quiet
        if ($LASTEXITCODE -eq 0) {
            Write-Host "  Dependencies installed successfully." -ForegroundColor Green
            return $true
        } else {
            Write-Host "  [WARN] Some packages may have failed to install." -ForegroundColor Yellow
            return $false
        }
    } else {
        Write-Host "  All dependencies installed." -ForegroundColor Green
        return $true
    }
}

function Test-SshKey {
    $settingsFile = Join-Path $ProjectRoot "settings.yaml"
    $sshKeySrc = $null

    # Try to read SSH key from settings
    if (Test-Path $settingsFile) {
        $readSettingsScript = @"
import yaml, json, sys, os
path = sys.argv[1]
if not os.path.exists(path):
    print(json.dumps({}))
    sys.exit(0)
with open(path, 'r', encoding='utf-8-sig') as f:
    s = yaml.safe_load(f) or {}
print(json.dumps(s))
"@
        $readSettingsScript | Out-File -FilePath "$env:TEMP\read_settings_diag.py" -Encoding utf8 -Force
        $settingsJson = python "$env:TEMP\read_settings_diag.py" $settingsFile 2>$null
        if ($settingsJson) {
            $settings = $settingsJson | ConvertFrom-Json
            if ($settings.server -and $settings.server.ssh_key -and $settings.server.ssh_key -ne 'null') {
                $sshKeySrc = $settings.server.ssh_key
            }
        }
    }

    # Search for SSH key
    $keyPaths = @(
        $sshKeySrc,
        "$env:LOCALAPPDATA\DuneAwakeningServer\sshKey",
        (Join-Path $ProjectRoot "internal-scripts\ssh\sshKey"),
        "$env:TEMP\dune-tunnel-key",
        "$env:USERPROFILE\.ssh\id_ed25519",
        "$env:USERPROFILE\.ssh\id_rsa"
    ) | Where-Object { $_ -and $_ -ne 'null' }

    foreach ($kp in $keyPaths) {
        if (Test-Path $kp) {
            Write-Host "  SSH Key: Found at $kp" -ForegroundColor Green
            return $kp
        }
    }

    Write-Host "  SSH Key: NOT FOUND" -ForegroundColor Red
    Write-Host ""
    Write-Host "  No SSH key was found. The dashboard needs an SSH key to connect to your game server." -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  Where to find your SSH key:" -ForegroundColor Cyan
    Write-Host "    - If you used the Dune Awakening server setup, it's at:" -ForegroundColor White
    Write-Host "      %LOCALAPPDATA%\DuneAwakeningServer\sshKey" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "    - If you generated your own key, it's wherever you saved it." -ForegroundColor White
    Write-Host ""
    Write-Host "  To fix this:" -ForegroundColor Cyan
    Write-Host "    1. Locate your SSH private key file" -ForegroundColor White
    Write-Host "    2. Copy it to: $ProjectRoot\internal-scripts\ssh\sshKey" -ForegroundColor White
    Write-Host "    3. Or run setup again and provide the path when prompted" -ForegroundColor White
    Write-Host ""
    return $null
}

function Test-SshConnection {
    param($sshKey, $serverHost, $serverUser)

    if (-not $sshKey -or -not $serverHost -or $serverHost -eq 'YOUR_SERVER_IP') {
        Write-Host "  SSH Connection: SKIPPED (server not configured)" -ForegroundColor Yellow
        return $false
    }

    Write-Host "  Testing SSH connection to $serverUser@$serverHost..." -ForegroundColor Yellow
    $testOut = ssh -i $sshKey -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -o BatchMode=yes "${serverUser}@${serverHost}" "echo ok" 2>$null
    if ($testOut -eq "ok") {
        Write-Host "  SSH Connection: OK" -ForegroundColor Green
        return $true
    } else {
        Write-Host "  SSH Connection: FAILED" -ForegroundColor Red
        Write-Host ""
        Write-Host "  Could not connect to the game server via SSH." -ForegroundColor Yellow
        Write-Host ""
        Write-Host "  Common causes:" -ForegroundColor Cyan
        Write-Host "    1. The game server VM is not running" -ForegroundColor White
        Write-Host "       Fix: Start your Hyper-V VM or ensure the remote server is online." -ForegroundColor DarkGray
        Write-Host ""
        Write-Host "    2. The SSH key is incorrect or doesn't match the server" -ForegroundColor White
        Write-Host "       Fix: Verify the key in settings.yaml matches the key authorized on the VM." -ForegroundColor DarkGray
        Write-Host ""
        Write-Host "    3. The server IP in settings.yaml is wrong" -ForegroundColor White
        Write-Host "       Fix: Edit settings.yaml and update server.host to the correct IP." -ForegroundColor DarkGray
        Write-Host ""
        Write-Host "    4. A firewall is blocking SSH (port 22)" -ForegroundColor White
        Write-Host "       Fix: Check your network/firewall settings." -ForegroundColor DarkGray
        Write-Host ""
        return $false
    }
}

function Test-PortAvailability {
    param($port, $name)

    $inUse = Get-NetTCPConnection -LocalPort $port -ErrorAction SilentlyContinue | Where-Object { $_.State -eq 'Listen' }
    if ($inUse) {
        $proc = Get-Process -Id $inUse.OwningProcess -ErrorAction SilentlyContinue
        $procName = if ($proc) { $proc.ProcessName } else { "unknown" }
        Write-Host "  Port $port ($name): IN USE by $procName (PID: $($inUse.OwningProcess))" -ForegroundColor Red
        return $false
    } else {
        Write-Host "  Port $port ($name): Available" -ForegroundColor Green
        return $true
    }
}

function Test-FirewallRule {
    $fwRuleName = "DuneDashboard"
    try {
        $fwExists = Get-NetFirewallRule -DisplayName $fwRuleName -ErrorAction SilentlyContinue
        if ($fwExists) {
            Write-Host "  Firewall Rule '$fwRuleName': EXISTS" -ForegroundColor Green
            return $true
        }
    } catch {}

    Write-Host "  Firewall Rule '$fwRuleName': NOT FOUND" -ForegroundColor Yellow
    return $false
}

function Show-PortForwardGuide {
    Write-Host ""
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host "  Port Forwarding & Firewall Guide" -ForegroundColor Cyan
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  If you want to access the dashboard from another device on your network" -ForegroundColor White
    Write-Host "  or from the internet, you need to open/forward the dashboard port." -ForegroundColor White
    Write-Host ""
    Write-Host "  -- Home Network (Router Port Forwarding) ------------------" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  1. Find this computer's local IP address:" -ForegroundColor White
    Write-Host "     Run this command: ipconfig" -ForegroundColor DarkGray
    Write-Host "     Look for 'IPv4 Address' under your active network adapter." -ForegroundColor DarkGray
    Write-Host "     It will look like: 192.168.1.XXX or 10.0.0.XXX" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  2. Log into your router's admin page:" -ForegroundColor White
    Write-Host "     Open a browser and go to your router's IP (usually 192.168.1.1 or 192.168.0.1)" -ForegroundColor DarkGray
    Write-Host "     Look for 'Port Forwarding', 'Virtual Server', or 'NAT' settings." -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  3. Create a port forwarding rule:" -ForegroundColor White
    Write-Host "     - External Port: 5050 (or your dashboard port)" -ForegroundColor DarkGray
    Write-Host "     - Internal Port: 5050 (or your dashboard port)" -ForegroundColor DarkGray
    Write-Host "     - Protocol: TCP" -ForegroundColor DarkGray
    Write-Host "     - Internal IP: The local IP from step 1" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  4. Find your public IP address:" -ForegroundColor White
    Write-Host "     Visit https://api.ipify.org in your browser" -ForegroundColor DarkGray
    Write-Host "     Your public IP is what others use to connect: https://YOUR_PUBLIC_IP:5050" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  -- Windows Firewall ---------------------------------------" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  If Windows Firewall is blocking incoming connections:" -ForegroundColor White
    Write-Host ""
    Write-Host "  Quick fix (run as Administrator):" -ForegroundColor White
    Write-Host "    New-NetFirewallRule -DisplayName 'DuneDashboard' -Direction Inbound -Action Allow -Protocol TCP -LocalPort 5050" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  Or via the GUI:" -ForegroundColor White
    Write-Host "    1. Open 'Windows Defender Firewall with Advanced Security'" -ForegroundColor DarkGray
    Write-Host "    2. Click 'Inbound Rules' -> 'New Rule...'" -ForegroundColor DarkGray
    Write-Host "    3. Select 'Port' -> TCP -> Specific local ports: 5050" -ForegroundColor DarkGray
    Write-Host "    4. Select 'Allow the connection' -> Apply to all profiles -> Name it 'DuneDashboard'" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  -- Cloud Server (AWS, Azure, Hetzner, etc.) -------------" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  If your dashboard is on a cloud server, you need to open the port" -ForegroundColor White
    Write-Host "  in the cloud provider's firewall/security group:" -ForegroundColor White
    Write-Host ""
    Write-Host "    - AWS: Edit the Security Group -> Add Inbound Rule -> TCP 5050" -ForegroundColor DarkGray
    Write-Host "    - Azure: Edit Network Security Group -> Add Inbound Rule -> TCP 5050" -ForegroundColor DarkGray
    Write-Host "    - Hetzner: Edit Firewall -> Add Rule -> TCP 5050" -ForegroundColor DarkGray
    Write-Host "    - DigitalOcean: Edit Firewall -> Add Inbound Rule -> TCP 5050" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  -- Common Ports Used by the Dashboard -------------------" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "    Port 5050  - Dashboard web interface (main port)" -ForegroundColor White
    Write-Host "    Port 80    - HTTP to HTTPS redirect (optional)" -ForegroundColor White
    Write-Host "    Port 443   - HTTPS (if you change the dashboard port to 443)" -ForegroundColor White
    Write-Host ""
    Write-Host "  -- Testing Your Connection -------------------------------" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  From another device on the same network:" -ForegroundColor White
    Write-Host "    Open browser -> https://THIS_COMPUTER_IP:5050" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  From the internet:" -ForegroundColor White
    Write-Host "    Open browser -> https://YOUR_PUBLIC_IP:5050" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  If it doesn't work:" -ForegroundColor White
    Write-Host "    1. Check Windows Firewall (see above)" -ForegroundColor DarkGray
    Write-Host "    2. Check router port forwarding (see above)" -ForegroundColor DarkGray
    Write-Host "    3. Check cloud provider firewall (see above)" -ForegroundColor DarkGray
    Write-Host "    4. Make sure the dashboard is bound to 0.0.0.0 (not 127.0.0.1)" -ForegroundColor DarkGray
    Write-Host "       Check settings.yaml -> dashboard.host should be 0.0.0.0 for remote access" -ForegroundColor DarkGray
    Write-Host ""
}

function Run-Diagnostics {
    Show-Banner
    Write-Host "  Running Diagnostics..." -ForegroundColor Cyan
    Write-Host ""

    $issues = 0

    # Python
    Write-Host "[1/7] Checking Python..." -ForegroundColor Yellow
    if (-not (Test-Python)) { $issues++ }
    Write-Host ""

    # Dependencies
    Write-Host "[2/7] Checking Dependencies..." -ForegroundColor Yellow
    if (-not (Test-Dependencies)) { $issues++ }
    Write-Host ""

    # Settings
    $settingsFile = Join-Path $ProjectRoot "settings.yaml"
    Write-Host "[3/7] Checking Settings..." -ForegroundColor Yellow
    if (Test-Path $settingsFile) {
        Write-Host "  settings.yaml: FOUND" -ForegroundColor Green
        $readSettingsScript = @"
import yaml, json, sys, os
path = sys.argv[1]
if not os.path.exists(path):
    print(json.dumps({}))
    sys.exit(0)
with open(path, 'r', encoding='utf-8-sig') as f:
    s = yaml.safe_load(f) or {}
print(json.dumps(s))
"@
        $readSettingsScript | Out-File -FilePath "$env:TEMP\read_settings_diag.py" -Encoding utf8 -Force
        $settingsJson = python "$env:TEMP\read_settings_diag.py" $settingsFile 2>$null
        if ($settingsJson) {
            $settings = $settingsJson | ConvertFrom-Json
            if ($settings.server -and $settings.server.host -and $settings.server.host -ne 'YOUR_SERVER_IP') {
                Write-Host "  Server Host: $($settings.server.host)" -ForegroundColor Green
            } else {
                Write-Host "  Server Host: NOT CONFIGURED (edit settings.yaml)" -ForegroundColor Red
                $issues++
            }
            if ($settings.dashboard) {
                $dashHost = $settings.dashboard.host
                $dashPort = $settings.dashboard.port
                Write-Host "  Dashboard: ${dashHost}:${dashPort}" -ForegroundColor Green
                if ($dashHost -eq '0.0.0.0') {
                    Write-Host "    (Accessible from localhost, LAN, and internet)" -ForegroundColor DarkGray
                } else {
                    Write-Host "    (Only accessible from this computer)" -ForegroundColor DarkGray
                }
            }
        } else {
            Write-Host "  settings.yaml: COULD NOT READ" -ForegroundColor Red
            $issues++
        }
    } else {
        Write-Host "  settings.yaml: NOT FOUND - Run setup first" -ForegroundColor Red
        $issues++
    }
    Write-Host ""

    # SSH Key
    Write-Host "[4/7] Checking SSH Key..." -ForegroundColor Yellow
    $sshKey = Test-SshKey
    if (-not $sshKey) { $issues++ }
    Write-Host ""

    # SSH Connection
    Write-Host "[5/7] Checking SSH Connection..." -ForegroundColor Yellow
    if ($settingsJson) {
        $settings = $settingsJson | ConvertFrom-Json
        $serverHost = $settings.server.host
        $serverUser = $settings.server.user
        if (-not (Test-SshConnection -sshKey $sshKey -serverHost $serverHost -serverUser $serverUser)) { $issues++ }
    } else {
        Write-Host "  SSH Connection: SKIPPED (settings not available)" -ForegroundColor Yellow
    }
    Write-Host ""

    # Port Availability
    Write-Host "[6/7] Checking Port Availability..." -ForegroundColor Yellow
    $dashboardPort = 5050
    if ($settingsJson) {
        $settings = $settingsJson | ConvertFrom-Json
        if ($settings.dashboard -and $settings.dashboard.port) {
            $dashboardPort = [int]$settings.dashboard.port
        }
    }
    if (-not (Test-PortAvailability -port $dashboardPort -name "Dashboard")) { $issues++ }
    Write-Host ""

    # Firewall
    Write-Host "[7/7] Checking Firewall..." -ForegroundColor Yellow
    Test-FirewallRule | Out-Null
    Write-Host ""

    # Summary
    Write-Host "============================================================" -ForegroundColor Cyan
    if ($issues -eq 0) {
        Write-Host "  All local checks passed!" -ForegroundColor Green
    } else {
        Write-Host "  Found $issues local issue(s) that may prevent the dashboard from working." -ForegroundColor Yellow
        Write-Host "  Review the messages above for details on how to fix each issue." -ForegroundColor Yellow
    }
    Write-Host ""

    # Server-side diagnostics
    if ($settingsJson) {
        $settings = $settingsJson | ConvertFrom-Json
        if ($settings.server -and $settings.server.host -and $settings.server.host -ne 'YOUR_SERVER_IP') {
            Write-Host "  Running server-side diagnostics..." -ForegroundColor Yellow
            Write-Host ""
            python (Join-Path $ProjectRoot "scripts\diagnostic.py") (Join-Path $ProjectRoot "settings.yaml")
            Write-Host ""
        }
    }

    # Offer port forward guide
    Write-Host "  Would you like to see the Port Forwarding & Firewall guide? (y/N)" -ForegroundColor Cyan
    $showGuide = Read-Host "  "
    if ($showGuide -eq 'y' -or $showGuide -eq 'Y') {
        Show-PortForwardGuide
    }

    Write-Host "  Press Enter to return to the main menu..." -ForegroundColor Cyan
    Read-Host "  "
}

function Run-Setup {
    Write-Host ""
    Write-Host "  Starting setup..." -ForegroundColor Yellow
    Write-Host ""

    # Check if this is a re-run
    $IsReRun = (Test-Path (Join-Path $ProjectRoot "settings.yaml")) -or (Test-Path (Join-Path $ProjectRoot "logs")) -or (Test-Path (Join-Path $ProjectRoot "instance")) -or (Test-Path (Join-Path $ProjectRoot "ssl"))

    if ($IsReRun) {
        Write-Host "  [WARNING] Existing dashboard data detected!" -ForegroundColor Red
        Write-Host ""
        Write-Host "  This will WIPE the following and start fresh:" -ForegroundColor Yellow
        Write-Host "    - settings.yaml (configuration)" -ForegroundColor Yellow
        Write-Host "    - logs/ (all log files)" -ForegroundColor Yellow
        Write-Host "    - instance/ (SQLite database)" -ForegroundColor Yellow
        Write-Host "    - ssl/ (SSL certificates and CA)" -ForegroundColor Yellow
        Write-Host "    - __pycache__/ (Python cache)" -ForegroundColor Yellow
        Write-Host ""
        Write-Host "  Are you sure you want to continue? (Y/N)" -ForegroundColor Red

        $confirmation = Read-Host "  Type Y to confirm"
        if ($confirmation -ne "Y" -and $confirmation -ne "y") {
            Write-Host ""
            Write-Host "  Setup cancelled. No changes made." -ForegroundColor Yellow
            return
        }

        Write-Host ""
        Write-Host "  Cleaning existing data..." -ForegroundColor Yellow

        if (Test-Path (Join-Path $ProjectRoot "settings.yaml")) { Remove-Item (Join-Path $ProjectRoot "settings.yaml") -Force; Write-Host "    Removed settings.yaml" -ForegroundColor Green }
        if (Test-Path (Join-Path $ProjectRoot "logs")) { Remove-Item (Join-Path $ProjectRoot "logs") -Recurse -Force; Write-Host "    Removed logs/" -ForegroundColor Green }
        if (Test-Path (Join-Path $ProjectRoot "instance")) { Remove-Item (Join-Path $ProjectRoot "instance") -Recurse -Force; Write-Host "    Removed instance/" -ForegroundColor Green }
        if (Test-Path (Join-Path $ProjectRoot "ssl")) { Remove-Item (Join-Path $ProjectRoot "ssl") -Recurse -Force; Write-Host "    Removed ssl/" -ForegroundColor Green }
        if (Test-Path (Join-Path $ProjectRoot "__pycache__")) { Remove-Item (Join-Path $ProjectRoot "__pycache__") -Recurse -Force; Write-Host "    Removed __pycache__/" -ForegroundColor Green }

        $cacheDirs = Get-ChildItem -Path (Join-Path $ProjectRoot "app") -Recurse -Directory -Filter "__pycache__" -ErrorAction SilentlyContinue
        foreach ($dir in $cacheDirs) { Remove-Item $dir.FullName -Recurse -Force }
        if ($cacheDirs.Count -gt 0) { Write-Host "    Removed $($cacheDirs.Count) Python cache folders" -ForegroundColor Green }

        Write-Host "  Clean complete!" -ForegroundColor Green
        Write-Host ""
    }

    # Run the actual setup script
    & (Join-Path $ProjectRoot "setup.ps1")
}

function Start-Dashboard {
    Write-Host ""
    Write-Host "  Starting dashboard..." -ForegroundColor Yellow
    Write-Host ""

    # Check Python
    if (-not (Test-Python)) {
        Write-Host "  Cannot start without Python. Please install Python 3.8+ first." -ForegroundColor Red
        return
    }

    # Check dependencies
    Test-Dependencies | Out-Null

    # Check settings
    $settingsFile = Join-Path $ProjectRoot "settings.yaml"
    if (-not (Test-Path $settingsFile)) {
        Write-Host ""
        Write-Host "  [ERROR] settings.yaml not found. You need to run setup first." -ForegroundColor Red
        Write-Host ""
        Write-Host "  Run setup to configure the dashboard before starting it." -ForegroundColor Yellow
        return
    }

    # Read settings
    $readSettingsScript = @"
import yaml, json, sys, os
path = sys.argv[1]
if not os.path.exists(path):
    print(json.dumps({}))
    sys.exit(0)
with open(path, 'r', encoding='utf-8-sig') as f:
    s = yaml.safe_load(f) or {}
print(json.dumps(s))
"@
    $readSettingsScript | Out-File -FilePath "$env:TEMP\read_settings_start.py" -Encoding utf8 -Force
    $settingsJson = python "$env:TEMP\read_settings_start.py" $settingsFile 2>$null
    if (-not $settingsJson) {
        Write-Host "  [ERROR] Failed to read settings.yaml" -ForegroundColor Red
        return
    }
    $settings = $settingsJson | ConvertFrom-Json

    $ServerHost = $settings.server.host
    $SSHUser = $settings.server.user
    $LocalPort = [int]$settings.database.port
    $Namespace = $settings.kubernetes.namespace
    $DashboardPort = [int]$settings.dashboard.port
    $DirectorPort = [int]$settings.director.port

    # Find SSH key
    function Test-SshKeyForStart($keyPath, $targetServer) {
        if (-not (Test-Path $keyPath)) { return $false }
        try {
            $out = ssh -i $keyPath -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 -o BatchMode=yes $targetServer "echo ok" 2>$null
            return $out -eq "ok"
        } catch { return $false }
    }

    $SSHKeySrc = $settings.server.ssh_key
    $LocalKey = Join-Path $ProjectRoot "internal-scripts\ssh\sshKey"
    $ParentKey = Join-Path (Split-Path $ProjectRoot) "internal-scripts\ssh\sshKey"

    if ($SSHKeySrc -and $SSHKeySrc -ne 'null' -and -not [string]::IsNullOrEmpty($SSHKeySrc)) {
        if (Test-SshKeyForStart $SSHKeySrc ($SSHUser + '@' + $ServerHost)) {
            Write-Host "  SSH Key: Using key from settings.yaml" -ForegroundColor Green
        } else {
            Write-Host "  SSH Key: Key in settings.yaml failed, searching..." -ForegroundColor Yellow
            $SSHKeySrc = $null
        }
    }

    if (-not $SSHKeySrc -or -not (Test-Path $SSHKeySrc) -or -not (Test-SshKeyForStart $SSHKeySrc ($SSHUser + '@' + $ServerHost))) {
        $keyPaths = @(
            $LocalKey,
            $ParentKey,
            "$env:LOCALAPPDATA\DuneAwakeningServer\sshKey",
            "$env:USERPROFILE\.ssh\id_ed25519",
            "$env:USERPROFILE\.ssh\id_rsa",
            "$env:USERPROFILE\.ssh\id_ecdsa",
            "$env:TEMP\dune-tunnel-key",
            "$env:TEMP\dune-awakening-server-sshKey"
        )
        foreach ($kp in $keyPaths) {
            if ($kp -ne $SSHKeySrc -and (Test-Path $kp)) {
                if (Test-SshKeyForStart $kp ($SSHUser + '@' + $ServerHost)) {
                    $SSHKeySrc = $kp
                    Write-Host "  SSH Key: Found working key at $kp" -ForegroundColor Green
                    break
                }
            }
        }
    }

    if (-not $SSHKeySrc -or -not (Test-Path $SSHKeySrc)) {
        Write-Host ""
        Write-Host "  [ERROR] No working SSH key found." -ForegroundColor Red
        Write-Host ""
        Write-Host "  The dashboard needs an SSH key to connect to your game server." -ForegroundColor Yellow
        Write-Host "  Place a valid key in one of these locations:" -ForegroundColor Yellow
        Write-Host "    - $ProjectRoot\internal-scripts\ssh\sshKey" -ForegroundColor DarkGray
        Write-Host "    - %LOCALAPPDATA%\DuneAwakeningServer\sshKey" -ForegroundColor DarkGray
        Write-Host "    - %USERPROFILE%\.ssh\id_ed25519" -ForegroundColor DarkGray
        Write-Host ""
        Write-Host "  Or update the ssh_key path in settings.yaml." -ForegroundColor Yellow
        return
    }

    # Copy SSH key to temp with restricted permissions
    if ($SSHKeySrc -ne $LocalKey -and (Test-Path $LocalKey) -and (Get-Item $LocalKey).Length -eq 0) {
        Copy-Item $SSHKeySrc $LocalKey -Force
        Write-Host "  Updated internal key file" -ForegroundColor Green
    }

    $SSHKey = "$env:TEMP\dune-tunnel-key"
    $ResolvedSrc = [System.IO.Path]::GetFullPath($SSHKeySrc)
    $ResolvedDest = [System.IO.Path]::GetFullPath($SSHKey)
    if ($ResolvedSrc -ne $ResolvedDest) {
        Copy-Item $SSHKeySrc $SSHKey -Force
    }
    try {
        $acl = Get-Acl $SSHKey -ErrorAction SilentlyContinue
        if ($acl) {
            $acl.SetAccessRuleProtection($true, $false)
            $rule = New-Object System.Security.AccessControl.FileSystemAccessRule("$env:USERNAME", "FullControl", "Allow")
            $acl.SetAccessRule($rule)
            Set-Acl -Path $SSHKey -AclObject $acl -ErrorAction SilentlyContinue
        }
    } catch {}

    Write-Host ""
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host "  Dune Awakening Dashboard" -ForegroundColor Cyan
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host ""

    # Kill existing SSH tunnels on the DB/Director ports
    Get-NetTCPConnection -LocalPort $LocalPort -ErrorAction SilentlyContinue | ForEach-Object {
        Get-Process -Id $_.OwningProcess -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -eq 'ssh' } | Stop-Process -Force -ErrorAction SilentlyContinue
    }
    Get-NetTCPConnection -LocalPort $DirectorPort -ErrorAction SilentlyContinue | ForEach-Object {
        Get-Process -Id $_.OwningProcess -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -eq 'ssh' } | Stop-Process -Force -ErrorAction SilentlyContinue
    }
    Start-Sleep 1

    # [1/4] SSH Tunnel
    Write-Host "[1/4] Starting SSH tunnel (localhost:$LocalPort -> VM)..." -ForegroundColor Yellow
    $sshArgs = @(
        "-i", $SSHKey,
        "-o", "StrictHostKeyChecking=accept-new",
        "-o", "ServerAliveInterval=30",
        "-o", "ServerAliveCountMax=3",
        "-L", "${LocalPort}:localhost:${LocalPort}",
        "-L", "${DirectorPort}:localhost:${DirectorPort}",
        "-N", "${SSHUser}@${ServerHost}"
    )
    $sshTunnel = Start-Process ssh -ArgumentList $sshArgs -PassThru -WindowStyle Hidden

    $connected = $false
    for ($i = 0; $i -lt 30; $i++) {
        Start-Sleep -Seconds 1
        if ($sshTunnel.HasExited) {
            Write-Host "[ERROR] SSH tunnel exited (code: $($sshTunnel.ExitCode))" -ForegroundColor Red
            Write-Host ""
            Write-Host "  The SSH tunnel could not connect to your game server." -ForegroundColor Yellow
            Write-Host ""
            Write-Host "  Troubleshooting:" -ForegroundColor Cyan
            Write-Host "    1. Make sure the game server VM is running" -ForegroundColor White
            Write-Host "    2. Check that the server IP in settings.yaml is correct: $ServerHost" -ForegroundColor White
            Write-Host "    3. Verify your SSH key is authorized on the VM" -ForegroundColor White
            Write-Host "    4. Try connecting manually: ssh -i $SSHKey ${SSHUser}@${ServerHost}" -ForegroundColor White
            Write-Host ""
            return
        }
        try {
            $tcp = New-Object System.Net.Sockets.TcpClient
            $tcp.Connect("127.0.0.1", $LocalPort)
            $tcp.Close()
            $connected = $true
            break
        } catch {}
    }
    if (-not $connected) {
        Write-Host "[ERROR] SSH tunnel did not connect within 30 seconds" -ForegroundColor Red
        Write-Host ""
        Write-Host "  The SSH tunnel could not establish a connection." -ForegroundColor Yellow
        Write-Host ""
        Write-Host "  Troubleshooting:" -ForegroundColor Cyan
        Write-Host "    1. Check that your game server VM is running" -ForegroundColor White
        Write-Host "    2. Verify network connectivity: ping $ServerHost" -ForegroundColor White
        Write-Host "    3. Check if port $LocalPort is blocked by a firewall" -ForegroundColor White
        Write-Host "    4. Try connecting manually: ssh -i $SSHKey ${SSHUser}@${ServerHost}" -ForegroundColor White
        Write-Host ""
        Stop-Process -Id $sshTunnel.Id -Force -ErrorAction SilentlyContinue
        return
    }
    Write-Host "[OK]   SSH tunnel up on localhost:$LocalPort (DB) and localhost:$DirectorPort (Director)" -ForegroundColor Green

    # [2/4] DB Port-Forward
    Write-Host "[2/4] Starting DB port-forward on VM..." -ForegroundColor Yellow

    if (-not $Namespace -or $Namespace -eq '') {
        Write-Host "[ERROR] Kubernetes namespace is empty." -ForegroundColor Red
        Write-Host ""
        Write-Host "  The dashboard needs to know your Kubernetes namespace to connect to the database." -ForegroundColor Yellow
        Write-Host ""
        Write-Host "  To find your namespace:" -ForegroundColor Cyan
        Write-Host "    1. SSH into your game server: ssh -i $SSHKey ${SSHUser}@${ServerHost}" -ForegroundColor White
        Write-Host "    2. Run: sudo kubectl get namespaces" -ForegroundColor White
        Write-Host "    3. Look for a namespace starting with 'funcom-seabass-'" -ForegroundColor White
        Write-Host "    4. Edit settings.yaml and set kubernetes.namespace to that value" -ForegroundColor White
        Write-Host ""
        Stop-Process -Id $sshTunnel.Id -Force -ErrorAction SilentlyContinue
        return
    }

    $DBService = "${Namespace}-db-dbdepl-svc"

    $pfCheck = ssh -i $SSHKey -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 ${SSHUser}@${ServerHost} "sudo kubectl get svc -n ${Namespace} -o name" 2>$null
    if ($pfCheck) {
        $dbSvc = ($pfCheck -split "`n") | Where-Object { $_ -match 'db.*svc' -or $_ -match 'postgres' -or $_ -match 'pg' } | Select-Object -First 1
        if ($dbSvc) {
            $DBService = $dbSvc -replace 'service/', ''
            Write-Host "  Found DB service: $DBService" -ForegroundColor Green
        }
    }

    $RemotePort = 15432
    $pfCmd = "nohup sudo kubectl port-forward -n $Namespace svc/$DBService $LocalPort`:$RemotePort > /tmp/pf.log 2>`&1 `"&`""
    ssh -i $SSHKey -o StrictHostKeyChecking=accept-new -o ServerAliveInterval=30 "${SSHUser}@${ServerHost}" $pfCmd 2>$null
    Start-Sleep -Seconds 2

    $bgdSvc = "${Namespace}-bgd-svc"
    $pfCheckBgd = ssh -i $SSHKey -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 ${SSHUser}@${ServerHost} "sudo kubectl get svc -n ${Namespace} -o name" 2>$null
    if ($pfCheckBgd) {
        $bgdMatch = ($pfCheckBgd -split "`n") | Where-Object { $_ -match 'bgd.*svc' } | Select-Object -First 1
        if ($bgdMatch) { $bgdSvc = $bgdMatch -replace 'service/', '' }
    }

    # Check if BGD deployment is running, scale up if needed
    $bgdDeploy = "${Namespace}-bgd-deploy"
    $bgdReady = ssh -i $SSHKey -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 ${SSHUser}@${ServerHost} "sudo kubectl get deployment $bgdDeploy -n $Namespace -o jsonpath='{.status.readyReplicas}'" 2>$null
    if (-not $bgdReady -or $bgdReady -eq '0' -or $bgdReady -eq '') {
        Write-Host "  BGD deployment is scaled down, starting..." -ForegroundColor Yellow
        $scaleOut = ssh -i $SSHKey -o StrictHostKeyChecking=accept-new -o ConnectTimeout=30 ${SSHUser}@${ServerHost} "sudo kubectl scale deployment $bgdDeploy -n $Namespace --replicas=1" 2>$null
        Write-Host "  Waiting for BGD pod to be ready..." -ForegroundColor Yellow
        Start-Sleep -Seconds 15
    }

    $directorRemotePort = 11717
    $directorCmd = "nohup sudo kubectl port-forward -n $Namespace svc/$bgdSvc $DirectorPort`:$directorRemotePort > /tmp/director_pf.log 2>`&1 `"&`""
    ssh -i $SSHKey -o StrictHostKeyChecking=accept-new -o ServerAliveInterval=30 "${SSHUser}@${ServerHost}" $directorCmd 2>$null

    Start-Sleep -Seconds 3

    # [3/4] Database Check
    Write-Host "[3/4] Checking database..." -ForegroundColor Yellow
    $dbTest = $false
    $dbScript = Join-Path $ProjectRoot "scripts\db_check.py"
    for ($i = 0; $i -lt 15; $i++) {
        try {
            $result = python $dbScript $LocalPort 2>$null
            if ($result -match 'ok') { $dbTest = $true; break }
        } catch {}
        Start-Sleep -Seconds 1
    }
    if (-not $dbTest) {
        Write-Host "[ERROR] Database connection failed." -ForegroundColor Red
        Write-Host ""
        Write-Host "  The dashboard could not connect to the game server's database." -ForegroundColor Yellow
        Write-Host ""
        Write-Host "  Troubleshooting:" -ForegroundColor Cyan
        Write-Host "    1. Check the port-forward log on the VM:" -ForegroundColor White
        $pfLog = ssh -i $SSHKey -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 ${SSHUser}@${ServerHost} "cat /tmp/pf.log" 2>$null
        if ($pfLog) { Write-Host "       $pfLog" -ForegroundColor Red }
        else { Write-Host "       Log empty or unreadable." -ForegroundColor Yellow }
        Write-Host ""
        Write-Host "    2. Verify the DB service exists on the VM:" -ForegroundColor White
        Write-Host "       ssh -i $SSHKey ${SSHUser}@${ServerHost} 'sudo kubectl get svc -n $Namespace'" -ForegroundColor DarkGray
        Write-Host ""
        Write-Host "    3. Check that the database port in settings.yaml is correct: $LocalPort" -ForegroundColor White
        Write-Host ""
        Write-Host "    4. The database service name should be: $DBService" -ForegroundColor White
        Write-Host "       If it's different, the port-forward may be targeting the wrong service." -ForegroundColor White
        Write-Host ""
        Stop-Process -Id $sshTunnel.Id -Force -ErrorAction SilentlyContinue
        return
    }
    Write-Host "[OK]   Database connected" -ForegroundColor Green

    # [3/4] Director Check
    Write-Host "[3/4] Checking director connection..." -ForegroundColor Yellow
    $directorTest = $false
    for ($i = 0; $i -lt 15; $i++) {
        try {
            $tcp = New-Object System.Net.Sockets.TcpClient
            $tcp.Connect("127.0.0.1", $DirectorPort)
            $tcp.Close()
            $directorTest = $true
            break
        } catch {}
        Start-Sleep -Seconds 1
    }
    if (-not $directorTest) {
        Write-Host "[WARN] Director port-forward not responding on localhost:$DirectorPort" -ForegroundColor Yellow
        Write-Host "       The Director tab may not work until the port-forward is active." -ForegroundColor Yellow
        Write-Host ""
        Write-Host "  Troubleshooting:" -ForegroundColor Cyan
        Write-Host "    1. Check the port-forward log on the VM:" -ForegroundColor White
        $directorPfLog = ssh -i $SSHKey -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 ${SSHUser}@${ServerHost} "cat /tmp/director_pf.log" 2>$null
        if ($directorPfLog) { Write-Host "       $directorPfLog" -ForegroundColor Red }
        else { Write-Host "       Log empty or unreadable." -ForegroundColor Yellow }
        Write-Host ""
        Write-Host "    2. Verify the BGD service exists on the VM:" -ForegroundColor White
        Write-Host "       ssh -i $SSHKey ${SSHUser}@${ServerHost} 'sudo kubectl get svc -n $Namespace'" -ForegroundColor DarkGray
        Write-Host ""
    } else {
        Write-Host "[OK]   Director port-forward connected" -ForegroundColor Green
    }

    # [4/4] Firewall check for remote access
    $fwRuleName = "DuneDashboard"
    $fwExists = $null
    try { $fwExists = Get-NetFirewallRule -DisplayName $fwRuleName -ErrorAction SilentlyContinue } catch {}
    $remoteDashboard = "$($settings.dashboard.host)" -eq "0.0.0.0"
    if ($remoteDashboard -and -not $fwExists) {
        Write-Host "[WARN] No Windows Firewall rule found for remote access." -ForegroundColor Yellow
        Write-Host "       Other devices on your network may not be able to reach the dashboard." -ForegroundColor Yellow
        Write-Host ""
        Write-Host "  To allow remote access, you need to:" -ForegroundColor Cyan
        Write-Host "    1. Open Windows Firewall for port $DashboardPort (TCP)" -ForegroundColor White
        Write-Host "    2. If behind a router, set up port forwarding for port $DashboardPort" -ForegroundColor White
        Write-Host ""
        Write-Host "  Quick firewall fix (run as Administrator):" -ForegroundColor White
        Write-Host "    New-NetFirewallRule -DisplayName DuneDashboard -Direction Inbound -Action Allow -Protocol TCP -LocalPort $DashboardPort" -ForegroundColor DarkGray
        Write-Host ""
        $redirectEnabled = $settings.dashboard.http_redirect -eq $true
        if ($redirectEnabled) {
            $redirectPort = if ($settings.dashboard.http_redirect_port) { $settings.dashboard.http_redirect_port } else { 80 }
            Write-Host "  Ports needed: $redirectPort (optional HTTP redirect), $DashboardPort (dashboard)" -ForegroundColor Yellow
        } else {
            Write-Host "  Port needed: $DashboardPort (dashboard)" -ForegroundColor Yellow
        }
        Write-Host ""
        $SetupFirewall = Read-Host "  Create firewall rules now? Requires Administrator (Y/n)"
        if ($SetupFirewall -ne 'n' -and $SetupFirewall -ne 'N') {
            $firewallPorts = @($DashboardPort)
            if ($redirectEnabled) { $firewallPorts = @($redirectPort) + $firewallPorts }
            $firewallPortList = ($firewallPorts -join ',')
            $isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
            if (-not $isAdmin) {
                Write-Host "  Starting elevated PowerShell to add firewall rules..." -ForegroundColor Yellow
                $fwScript = "New-NetFirewallRule -DisplayName DuneDashboard -Direction Inbound -Action Allow -Protocol TCP -LocalPort $firewallPortList; Write-Host ''; Read-Host 'Press Enter to close'"
                Start-Process powershell -ArgumentList "-NoProfile", "-Command", $fwScript -Verb RunAs -Wait
                Write-Host "[OK]   Firewall rules added." -ForegroundColor Green
            } else {
                New-NetFirewallRule -DisplayName DuneDashboard -Direction Inbound -Action Allow -Protocol TCP -LocalPort $firewallPorts
                Write-Host "[OK]   Firewall rules added for port(s): $firewallPortList." -ForegroundColor Green
            }
        } else {
            Write-Host "  Skipped. External access may be blocked by Windows Firewall." -ForegroundColor Yellow
        }
        Write-Host ""
    }

    # [4/4] Start Dashboard
    Write-Host "[4/4] Starting dashboard..." -ForegroundColor Yellow
    Write-Host ""

    # Determine access URLs
    $protocol = "http"
    $sslCert = $settings.dashboard.ssl_cert
    $sslKey = $settings.dashboard.ssl_key
    if ($sslCert -and $sslKey -and $sslCert -ne 'null' -and $sslKey -ne 'null') {
        if ((Test-Path $sslCert) -and (Test-Path $sslKey)) {
            $protocol = "https"
        }
    }

    $dashHost = $settings.dashboard.host
    if ($dashHost -eq '0.0.0.0') {
        Write-Host "  Dashboard is accessible at:" -ForegroundColor Green
        Write-Host "    Local:    ${protocol}://localhost:$DashboardPort" -ForegroundColor Cyan
        Write-Host "    Local:    ${protocol}://127.0.0.1:$DashboardPort" -ForegroundColor Cyan
        Write-Host "    Network:  ${protocol}://<this-computer-ip>:$DashboardPort" -ForegroundColor Cyan
        Write-Host "    Internet: ${protocol}://<your-public-ip>:$DashboardPort" -ForegroundColor Cyan
    } else {
        Write-Host "    ${protocol}://$dashHost`:$DashboardPort" -ForegroundColor Cyan
    }
    Write-Host ""
    Write-Host "  Press Ctrl+C to stop the dashboard." -ForegroundColor DarkGray
    Write-Host ""

    Set-Location -LiteralPath $ProjectRoot
    python run.py

    Write-Host ""
    Write-Host "Stopping tunnels..." -ForegroundColor Cyan
    Stop-Process -Id $sshTunnel.Id -Force -ErrorAction SilentlyContinue
    $pkillCmd = 'ssh -i "' + $SSHKey + '" -o StrictHostKeyChecking=accept-new ' + $SSHUser + '@' + $ServerHost + ' "pkill -f kubectl-port-forward"'
    cmd /c $pkillCmd 2>$null
}

# ── Main Loop ───────────────────────────────────────────────────────────

Show-Banner

while ($true) {
    Show-Menu
    $choice = Read-Host "  Enter your choice"

    switch ($choice) {
        "1" { Start-Dashboard; break }
        "2" { Run-Setup; break }
        "3" { Run-Diagnostics; break }
        "Q" { Write-Host ""; Write-Host "  Goodbye!"; Write-Host ""; exit 0 }
        "q" { Write-Host ""; Write-Host "  Goodbye!"; Write-Host ""; exit 0 }
        default { Write-Host ""; Write-Host "  Invalid choice. Please enter 1, 2, 3, or Q." -ForegroundColor Yellow; Write-Host "" }
    }

    Write-Host ""
}
