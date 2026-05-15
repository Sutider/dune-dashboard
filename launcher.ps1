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
    Write-Host "      Sets up SSH, SSL, firewall rules, and saves settings.yaml." -ForegroundColor DarkGray
    Write-Host "      WARNING: Re-running setup will wipe your current settings." -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  [3] Run Diagnostics" -ForegroundColor White
    Write-Host "      Check your system for common issues that could block the dashboard." -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  [4] Install CA Certificate" -ForegroundColor White
    Write-Host "      Install the local CA certificate into Windows Trusted Root store." -ForegroundColor DarkGray
    Write-Host "      Removes browser SSL warnings on this machine only." -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  [5] Clean & Reinstall CA Certificate" -ForegroundColor White
    Write-Host "      Remove all old Dune Dashboard CA certificates and install a fresh one." -ForegroundColor DarkGray
    Write-Host "      Use this if you have duplicate or expired CA certificates." -ForegroundColor DarkGray
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
        Write-Host "  Python 3.8+ is required but not detected on your system." -ForegroundColor Yellow
        Write-Host ""
        $installPython = Read-Host "  Would you like to install Python automatically? (Y/n)"
        if ($installPython -ne 'n' -and $installPython -ne 'N') {
            Write-Host ""
            Write-Host "  Installing Python via winget..." -ForegroundColor Yellow
            try {
                winget install Python.Python.3.11 -e --accept-package-agreements --accept-source-agreements --silent 2>$null | Out-Null
                if ($LASTEXITCODE -eq 0) {
                    Write-Host "  Python installed successfully." -ForegroundColor Green
                    Write-Host "  Please restart your terminal and run the launcher again." -ForegroundColor Cyan
                    return $false
                }
            } catch {}

            Write-Host "  winget installation failed or unavailable." -ForegroundColor Yellow
            Write-Host ""
            Write-Host "  Please install Python 3.8+ manually:" -ForegroundColor Cyan
            Write-Host "    1. Download from https://www.python.org/downloads/" -ForegroundColor White
            Write-Host "    2. During installation, check: [x] Add Python to PATH" -ForegroundColor White
            Write-Host "    3. Restart your terminal and run the launcher again." -ForegroundColor White
            return $false
        } else {
            Write-Host ""
            Write-Host "  Please install Python 3.8+ manually:" -ForegroundColor Cyan
            Write-Host "    1. Download from https://www.python.org/downloads/" -ForegroundColor White
            Write-Host "    2. During installation, check: [x] Add Python to PATH" -ForegroundColor White
            Write-Host "    3. Restart your terminal and run the launcher again." -ForegroundColor White
            return $false
        }
    }
}

function Test-Dependencies {
    Write-Host "  Checking Python dependencies..." -ForegroundColor Yellow
    $installed = @()
    $missing = @()
    $required = @(
        @{ Name = 'flask'; Pkg = 'Flask' },
        @{ Name = 'flask_socketio'; Pkg = 'Flask-SocketIO' },
        @{ Name = 'socketio'; Pkg = 'python-socketio' },
        @{ Name = 'psycopg2'; Pkg = 'psycopg2-binary' },
        @{ Name = 'paramiko'; Pkg = 'paramiko' },
        @{ Name = 'yaml'; Pkg = 'PyYAML' },
        @{ Name = 'flask_login'; Pkg = 'Flask-Login' },
        @{ Name = 'flask_wtf'; Pkg = 'Flask-WTF' },
        @{ Name = 'flask_limiter'; Pkg = 'Flask-Limiter' },
        @{ Name = 'cryptography'; Pkg = 'cryptography' },
        @{ Name = 'argon2'; Pkg = 'argon2-cffi' }
    )
    foreach ($mod in $required) {
        $result = python -c "import $($mod.Name)" 2>$null
        if ($LASTEXITCODE -eq 0) {
            $installed += $mod.Pkg
        } else {
            $missing += $mod.Pkg
        }
    }

    if ($installed.Count -gt 0) {
        Write-Host "  Already installed ($($installed.Count)):" -ForegroundColor Green
        foreach ($pkg in $installed) { Write-Host "    - $pkg" -ForegroundColor DarkGray }
    }

    if ($missing.Count -gt 0) {
        Write-Host ""
        Write-Host "  Missing packages ($($missing.Count)):" -ForegroundColor Yellow
        foreach ($pkg in $missing) { Write-Host "    - $pkg" -ForegroundColor Yellow }
        Write-Host ""
        $installDeps = Read-Host "  Install missing dependencies? (Y/n)"
        if ($installDeps -eq 'n' -or $installDeps -eq 'N') {
            Write-Host ""
            Write-Host "  Installation cancelled. Cannot continue without required packages." -ForegroundColor Red
            return $false
        }
        Write-Host ""
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
        Write-Host "  All dependencies are installed." -ForegroundColor Green
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

function Install-CaCert {
    $CaCertPath = Join-Path $ProjectRoot "ssl\ca.pem"
    if (-not (Test-Path $CaCertPath)) {
        Write-Host ""
        Write-Host "  [ERROR] CA certificate not found at ssl\ca.pem" -ForegroundColor Red
        Write-Host ""
        Write-Host "  The CA certificate hasn't been generated yet." -ForegroundColor Yellow
        Write-Host "  Run Setup first to generate the local CA certificate." -ForegroundColor Yellow
        return
    }

    Write-Host ""
    Write-Host "  Installing Dune Dashboard CA certificate..." -ForegroundColor Yellow
    Write-Host ""

    $isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) {
        Write-Host "  [WARN] Not running as Administrator." -ForegroundColor Yellow
        Write-Host "  Starting a new elevated PowerShell window to install the CA cert..." -ForegroundColor Yellow
        Write-Host ""
        $elevatedScript = "certutil -addstore -f 'Root' '$CaCertPath'; Write-Host ''; Read-Host 'Press Enter to close'"
        Start-Process powershell -ArgumentList "-NoProfile", "-Command", $elevatedScript -Verb RunAs -Wait
        Write-Host "  CA certificate installation complete." -ForegroundColor Green
    } else {
        certutil -addstore -f "Root" $CaCertPath
        if ($LASTEXITCODE -eq 0) {
            Write-Host "  CA certificate installed to Trusted Root Certification Authorities." -ForegroundColor Green
        } else {
            Write-Host "  [WARN] certutil failed. Try running as Administrator." -ForegroundColor Yellow
        }
    }
    Write-Host ""
    Write-Host "  Restart your browser for the change to take effect." -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  Press Enter to return to the main menu..." -ForegroundColor Cyan
    Read-Host "  "
}

function Clean-CaCerts {
    $CaCertPath = Join-Path $ProjectRoot "ssl\ca.pem"
    if (-not (Test-Path $CaCertPath)) {
        Write-Host ""
        Write-Host "  [ERROR] CA certificate not found at ssl\ca.pem" -ForegroundColor Red
        Write-Host ""
        Write-Host "  The CA certificate hasn't been generated yet." -ForegroundColor Yellow
        Write-Host "  Run Setup first to generate the local CA certificate." -ForegroundColor Yellow
        return
    }

    Write-Host ""
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host "  Dune Dashboard - CA Certificate Cleanup" -ForegroundColor Cyan
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host ""

    Write-Host "  Removing all existing Dune Dashboard CA certificates..." -ForegroundColor Yellow
    Write-Host ""

    try {
        $store = New-Object System.Security.Cryptography.X509Certificates.X509Store('Root', 'CurrentUser')
        $store.Open('ReadWrite')
        $certs = $store.Certificates | Where-Object { $_.Subject -like '*Dune Dashboard*' }
        Write-Host "  Found $($certs.Count) in CurrentUser store" -ForegroundColor DarkGray
        foreach ($c in $certs) {
            $store.Remove($c)
            Write-Host "    Removed: $($c.Thumbprint)" -ForegroundColor DarkGray
        }
        $store.Close()
    } catch {
        Write-Host "  [WARN] Could not clean CurrentUser store: $_" -ForegroundColor Yellow
    }

    try {
        $store = New-Object System.Security.Cryptography.X509Certificates.X509Store('Root', 'LocalMachine')
        $store.Open('ReadWrite')
        $certs = $store.Certificates | Where-Object { $_.Subject -like '*Dune Dashboard*' }
        Write-Host "  Found $($certs.Count) in LocalMachine store" -ForegroundColor DarkGray
        foreach ($c in $certs) {
            $store.Remove($c)
            Write-Host "    Removed: $($c.Thumbprint)" -ForegroundColor DarkGray
        }
        $store.Close()
    } catch {
        Write-Host "  [WARN] Could not clean LocalMachine store (may require Administrator): $_" -ForegroundColor Yellow
    }

    Write-Host ""
    Write-Host "  Installing fresh CA certificate..." -ForegroundColor Yellow
    Write-Host ""

    $isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) {
        Write-Host "  [WARN] Not running as Administrator." -ForegroundColor Yellow
        Write-Host "  Starting a new elevated PowerShell window to install the CA cert..." -ForegroundColor Yellow
        Write-Host ""
        $elevatedScript = "certutil -addstore -f 'Root' '$CaCertPath'; Write-Host ''; Read-Host 'Press Enter to close'"
        Start-Process powershell -ArgumentList "-NoProfile", "-Command", $elevatedScript -Verb RunAs -Wait
    } else {
        certutil -addstore -f "Root" $CaCertPath
    }

    if ($LASTEXITCODE -eq 0) {
        Write-Host "  CA certificate cleaned and reinstalled successfully." -ForegroundColor Green
    } else {
        Write-Host "  [WARN] Could not install certificate. Try running as Administrator." -ForegroundColor Yellow
    }

    Write-Host ""
    Write-Host "  Restart your browser for the change to take effect." -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  Press Enter to return to the main menu..." -ForegroundColor Cyan
    Read-Host "  "
}

function Run-Setup {
    Write-Host ""
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host "  Dune Awakening Dashboard - Setup" -ForegroundColor Cyan
    Write-Host "============================================================" -ForegroundColor Cyan
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

    # Check Python
    Write-Host "[1/6] Checking Python..." -ForegroundColor Yellow
    try {
        $pythonVersion = python --version 2>&1
        Write-Host "  Found: $pythonVersion" -ForegroundColor Green
    } catch {
        Write-Host "  Python: NOT FOUND" -ForegroundColor Red
        Write-Host ""
        Write-Host "  Python 3.8+ is required but not detected on your system." -ForegroundColor Yellow
        Write-Host ""
        $installPython = Read-Host "  Would you like to install Python automatically? (Y/n)"
        if ($installPython -ne 'n' -and $installPython -ne 'N') {
            Write-Host ""
            Write-Host "  Installing Python via winget..." -ForegroundColor Yellow
            try {
                winget install Python.Python.3.11 -e --accept-package-agreements --accept-source-agreements --silent 2>$null | Out-Null
                if ($LASTEXITCODE -eq 0) {
                    Write-Host "  Python installed successfully." -ForegroundColor Green
                    Write-Host "  Please restart your terminal and run the launcher again." -ForegroundColor Cyan
                    return
                }
            } catch {}

            Write-Host "  winget installation failed or unavailable." -ForegroundColor Yellow
            Write-Host ""
            Write-Host "  Please install Python 3.8+ manually:" -ForegroundColor Cyan
            Write-Host "    1. Download from https://www.python.org/downloads/" -ForegroundColor White
            Write-Host "    2. During installation, check: [x] Add Python to PATH" -ForegroundColor White
            Write-Host "    3. Restart your terminal and run the launcher again." -ForegroundColor White
            return
        } else {
            Write-Host ""
            Write-Host "  Please install Python 3.8+ manually:" -ForegroundColor Cyan
            Write-Host "    1. Download from https://www.python.org/downloads/" -ForegroundColor White
            Write-Host "    2. During installation, check: [x] Add Python to PATH" -ForegroundColor White
            Write-Host "    3. Restart your terminal and run the launcher again." -ForegroundColor White
            return
        }
    }

    # Install dependencies
    Write-Host ""
    Write-Host "[2/6] Checking dependencies..." -ForegroundColor Yellow
    $depInstalled = @()
    $depMissing = @()
    $depRequired = @(
        @{ Name = 'flask'; Pkg = 'Flask' },
        @{ Name = 'flask_socketio'; Pkg = 'Flask-SocketIO' },
        @{ Name = 'socketio'; Pkg = 'python-socketio' },
        @{ Name = 'psycopg2'; Pkg = 'psycopg2-binary' },
        @{ Name = 'paramiko'; Pkg = 'paramiko' },
        @{ Name = 'yaml'; Pkg = 'PyYAML' },
        @{ Name = 'flask_login'; Pkg = 'Flask-Login' },
        @{ Name = 'flask_wtf'; Pkg = 'Flask-WTF' },
        @{ Name = 'flask_limiter'; Pkg = 'Flask-Limiter' },
        @{ Name = 'cryptography'; Pkg = 'cryptography' },
        @{ Name = 'argon2'; Pkg = 'argon2-cffi' }
    )
    foreach ($mod in $depRequired) {
        $result = python -c "import $($mod.Name)" 2>$null
        if ($LASTEXITCODE -eq 0) {
            $depInstalled += $mod.Pkg
        } else {
            $depMissing += $mod.Pkg
        }
    }

    if ($depInstalled.Count -gt 0) {
        Write-Host "  Already installed ($($depInstalled.Count)):" -ForegroundColor Green
        foreach ($pkg in $depInstalled) { Write-Host "    - $pkg" -ForegroundColor DarkGray }
    }

    if ($depMissing.Count -gt 0) {
        Write-Host ""
        Write-Host "  Missing packages ($($depMissing.Count)):" -ForegroundColor Yellow
        foreach ($pkg in $depMissing) { Write-Host "    - $pkg" -ForegroundColor Yellow }
        Write-Host ""
        $installDeps = Read-Host "  Install missing dependencies? (Y/n)"
        if ($installDeps -eq 'n' -or $installDeps -eq 'N') {
            Write-Host ""
            Write-Host "  Installation cancelled. Cannot continue without required packages." -ForegroundColor Red
            return
        }
        Write-Host ""
        Write-Host "  Installing dependencies..." -ForegroundColor Yellow
        pip install -r (Join-Path $ProjectRoot "requirements.txt") --quiet
        if ($LASTEXITCODE -eq 0) {
            Write-Host "  Dependencies installed successfully." -ForegroundColor Green
        } else {
            Write-Host "  [WARN] Some packages may have failed to install." -ForegroundColor Yellow
        }
    } else {
        Write-Host "  All dependencies are installed." -ForegroundColor Green
    }

    # Configure SSH key
    Write-Host ""
    Write-Host "[3/6] Configuring SSH key..." -ForegroundColor Yellow
    $TargetKey = Join-Path $ProjectRoot "internal-scripts\ssh\sshKey"
    $SshKeyPaths = @(
        "$env:LOCALAPPDATA\DuneAwakeningServer\sshKey",
        "$env:TEMP\dune-tunnel-key",
        "$env:TEMP\dune-awakening-server-sshKey",
        $TargetKey,
        (Join-Path (Split-Path $ProjectRoot) "internal-scripts\ssh\sshKey")
    )
    $FoundKey = $null
    foreach ($path in $SshKeyPaths) {
        if (Test-Path $path) {
            $FoundKey = $path
            break
        }
    }

    function Fix-SshKeyPermissions($keyPath) {
        if (-not (Test-Path $keyPath)) { return }
        $acl = Get-Acl $keyPath
        $acl.SetAccessRuleProtection($true, $false)
        $rule = New-Object System.Security.AccessControl.FileSystemAccessRule("$env:USERNAME", "FullControl", "Allow")
        $acl.SetAccessRule($rule)
        $adminRule = New-Object System.Security.AccessControl.FileSystemAccessRule("BUILTIN\Administrators", "FullControl", "Allow")
        $acl.SetAccessRule($adminRule)
        Set-Acl -Path $keyPath -AclObject $acl
    }

    if (-not $FoundKey) {
        Write-Host "  [INFO] No SSH key found in standard locations." -ForegroundColor Yellow
        $userKey = Read-Host "  Enter path to your SSH key file (or press Enter to skip)"
        if ($userKey -and (Test-Path $userKey)) {
            $targetDir = Join-Path $ProjectRoot "internal-scripts\ssh"
            if (-not (Test-Path $targetDir)) {
                New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
            }
            Copy-Item $userKey $TargetKey -Force
            Fix-SshKeyPermissions $TargetKey
            $FoundKey = $TargetKey
            Write-Host "  Key copied to internal-scripts\ssh\sshKey" -ForegroundColor Green
        } else {
            Write-Host "  Skipping SSH key configuration." -ForegroundColor Yellow
            $FoundKey = $null
        }
    } else {
        if ($FoundKey -notlike "*internal-scripts*") {
            $targetDir = Join-Path $ProjectRoot "internal-scripts\ssh"
            if (-not (Test-Path $targetDir)) {
                New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
            }
            Copy-Item $FoundKey $TargetKey -Force
            Fix-SshKeyPermissions $TargetKey
            $FoundKey = $TargetKey
            Write-Host "  Key copied to internal-scripts\ssh\sshKey for portability" -ForegroundColor Green
        } else {
            Write-Host "  Found: $FoundKey" -ForegroundColor Green
        }
    }

    # Auto-detect server settings
    Write-Host ""
    Write-Host "[4/6] Detecting server settings..." -ForegroundColor Yellow

    $VmHost = "YOUR_SERVER_IP"
    $HostIp = $null
    $ServerUser = "dune"
    $K8sNamespace = ""
    $DashboardPort = "5050"
    $DbPort = "15433"
    $DbHost = "127.0.0.1"
    $DirectorPort = "32479"
    $FileBrowserPort = "18888"
    $AuthUser = "admin"
    $AuthPass = ""

    function Test-IsLocalIP($ip) {
        if ($ip -match '^192\.168\.') { return $true }
        if ($ip -match '^10\.') { return $true }
        if ($ip -match '^172\.(1[6-9]|2[0-9]|3[0-1])\.') { return $true }
        return $false
    }

    $vmIp = $null
    try {
        $vmAdapter = Get-VMNetworkAdapter -VMName 'dune-awakening' -ErrorAction SilentlyContinue
        if ($vmAdapter -and $vmAdapter.IPAddresses) {
            $localIp = $vmAdapter.IPAddresses | Where-Object { Test-IsLocalIP $_ }
            if ($localIp) {
                $vmIp = $localIp[0]
                Write-Host "  Detected local Hyper-V VM IP: $vmIp" -ForegroundColor Green
            }
        }
    } catch { }

    if (-not $vmIp) {
        $KnownHosts = Join-Path $env:USERPROFILE ".ssh\known_hosts"
        if (Test-Path $KnownHosts) {
            $content = Get-Content $KnownHosts
            $localIps = @()
            $publicIps = @()
            foreach ($line in $content) {
                if ($line -match '\b(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})\b') {
                    $ip = $matches[1]
                    if (Test-IsLocalIP $ip) {
                        $localIps += $ip
                    } else {
                        $publicIps += $ip
                    }
                }
            }
            if ($localIps.Count -gt 0) {
                $vmIp = $localIps[-1]
                Write-Host "  Detected local IP from SSH history: $vmIp" -ForegroundColor Green
            } elseif ($publicIps.Count -gt 0) {
                $vmIp = $publicIps[-1]
                Write-Host "  Detected IP from SSH history: $vmIp (verify this is your local VM)" -ForegroundColor Yellow
            }
        }
    }

    if ($vmIp) { $VmHost = $vmIp }

    try {
        $HostIp = (Invoke-WebRequest -Uri "https://api.ipify.org" -UseBasicParsing -TimeoutSec 5).Content.Trim()
    } catch {
        $localIps = Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.InterfaceAlias -notlike 'Loopback*' -and $_.PrefixOrigin -ne 'WellKnown' } | Select-Object -ExpandProperty IPAddress
        if ($localIps.Count -gt 0) { $HostIp = $localIps[0] }
    }

    Write-Host ""
    Write-Host "  VM External IP - used for SSH connection to your game server" -ForegroundColor Cyan
    $val = Read-Host "  VM Host [$VmHost]"
    if ($val) { $VmHost = $val }

    Write-Host ""
    Write-Host "  This Machine's External IP - used for SSL certificate so remote access works" -ForegroundColor Cyan
    if ($HostIp) { $hostIpHint = "$HostIp (auto-detected)" } else { $hostIpHint = "Your Windows machine's external IP" }
    $val = Read-Host "  Host IP [$hostIpHint]"
    if ($val) { $HostIp = $val }
    elseif (-not $HostIp) { $HostIp = $null }

    Write-Host ""
    Write-Host "  Domain Name (optional) - for a publicly trusted SSL certificate via Let's Encrypt." -ForegroundColor Cyan
    Write-Host "  This removes browser warnings for ALL visitors. Requires:" -ForegroundColor Cyan
    Write-Host "    - A domain (or subdomain) pointing to this machine's external IP" -ForegroundColor Cyan
    Write-Host "    - Port 80 accessible from the internet" -ForegroundColor Cyan
    $val = Read-Host "  Domain (leave blank to use local CA instead)"
    $DomainName = $null
    if ($val -and $val -match '\S') { $DomainName = $val }

    $LeEmail = $null
    if ($DomainName) {
        Write-Host ""
        Write-Host "  Email address is required by Let's Encrypt for expiry notifications." -ForegroundColor Cyan
        $val = Read-Host "  Email Address"
        if ($val -and $val -match '\S') { $LeEmail = $val }
    }

    # Try SSH with the confirmed VM IP to auto-detect namespace
    if ($FoundKey -and $VmHost -ne "YOUR_SERVER_IP") {
        Write-Host "  Testing SSH connection..." -ForegroundColor Yellow
        Write-Host "  (Fresh VMs may need time to initialize SSH keys - will retry up to 60s)" -ForegroundColor DarkGray
        Write-Host ""

        $sshOk = $false
        for ($i = 0; $i -lt 12; $i++) {
            try {
                $testOut = ssh -i "$FoundKey" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 -o BatchMode=yes dune@$VmHost "echo ok" 2>$null
                $testExit = $LASTEXITCODE
                if ($testOut -match "ok" -and $testExit -eq 0) {
                    $sshOk = $true
                    break
                }
            } catch {}
            Write-Host "  Attempt $($i+1)/12 - SSH not ready yet, waiting 5s..." -ForegroundColor DarkGray
            Start-Sleep -Seconds 5
        }

        if ($sshOk) {
            Write-Host "  SSH connection OK" -ForegroundColor Green
            try {
                $nsOut = ssh -i "$FoundKey" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -o BatchMode=yes dune@$VmHost "sudo kubectl get namespaces -o name" 2>$null
            } catch { $nsOut = $null }
            if ($nsOut) {
                foreach ($line in $nsOut -split "`n") {
                    $ns = $line -replace 'namespace/', ''
                    if ($ns -match '^funcom-seabass-') {
                        $K8sNamespace = $ns
                        Write-Host "  Auto-detected namespace: $K8sNamespace" -ForegroundColor Green
                        break
                    }
                }
            }
        } else {
            Write-Host "  SSH connection failed after 60s of retries" -ForegroundColor Yellow
            Write-Host ""
            Write-Host "  This is normal on a fresh VM that hasn't finished initializing." -ForegroundColor Cyan
            Write-Host "  You can still continue setup - just enter the namespace manually below." -ForegroundColor Cyan
            Write-Host ""
            Write-Host "  Once the VM is ready, copy your public key to enable SSH:" -ForegroundColor Cyan
            Write-Host ""
            $pubKeyContent = $null
            try { $pubKeyContent = Get-Content "$FoundKey.pub" -ErrorAction SilentlyContinue } catch {}
            if ($pubKeyContent) {
                Write-Host "    ssh dune@$VmHost 'mkdir -p ~/.ssh && chmod 700 ~/.ssh && echo `"$pubKeyContent`" >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys'" -ForegroundColor DarkGray
            } else {
                Write-Host "    ssh dune@$VmHost 'mkdir -p ~/.ssh && chmod 700 ~/.ssh'" -ForegroundColor DarkGray
                Write-Host "    Then paste your public key into ~/.ssh/authorized_keys" -ForegroundColor DarkGray
            }
            Write-Host ""
        }
    }

    # Interactive review/edit
    Write-Host ""
    Write-Host "  Review settings (press Enter to accept, or type new value):" -ForegroundColor Cyan
    Write-Host ""

    Write-Host "  VM Host: $VmHost (IP of your game server VM, used for SSH)"
    if ($HostIp) { Write-Host "  Host IP: $HostIp (This machine's external IP, used for SSL cert)" }

    $val = Read-Host "  Server User [$ServerUser] (SSH username for the VM)"
    if ($val) { $ServerUser = $val }

    Write-Host "  SSH Key Path: $FoundKey (Path to your private SSH key)"

    if (-not $K8sNamespace) {
        Write-Host "  [INFO] To find your namespace, run: ssh dune@YOUR_IP 'sudo kubectl get namespaces'" -ForegroundColor Cyan
        $K8sHint = "funcom-seabass-<id> (Kubernetes cluster namespace)"
    } else {
        $K8sHint = "$K8sNamespace (Kubernetes cluster namespace)"
    }

    $val = Read-Host "  K8s Namespace [$K8sHint]"
    if ($val) { $K8sNamespace = $val }
    elseif (-not $K8sNamespace) { $K8sNamespace = "" }

    $val = Read-Host "  Dashboard Port [$DashboardPort] (Local web access port)"
    if ($val) { $DashboardPort = $val }

    $val = Read-Host "  DB Local Port [$DbPort] (Local database tunnel port)"
    if ($val) { $DbPort = $val }

    $val = Read-Host "  Director Port [$DirectorPort] (Director API port)"
    if ($val) { $DirectorPort = $val }

    $val = Read-Host "  FileBrowser Port [$FileBrowserPort] (File manager port)"
    if ($val) { $FileBrowserPort = $val }

    $val = Read-Host "  Auth Username [$AuthUser] (Dashboard login name)"
    if ($val) { $AuthUser = $val }

    $val = Read-Host "  Auth Password (required)" -AsSecureString
    $AuthPass = [System.Net.NetworkCredential]::new('', $val).Password
    if ($AuthPass) { }
    else {
        Write-Host "  [ERROR] Password is required. Setup cancelled." -ForegroundColor Red
        return
    }

    # SSL certificate (Let's Encrypt or local CA)
    Write-Host ""
    Write-Host "  Configuring SSL certificate..." -ForegroundColor Yellow
    $CertDir = Join-Path $ProjectRoot "ssl"
    if (-not (Test-Path $CertDir)) { New-Item -ItemType Directory -Path $CertDir -Force | Out-Null }
    $CaCertPath = Join-Path $CertDir "ca.pem"
    $CaKeyPath = Join-Path $CertDir "ca-key.pem"
    $SslCertPath = Join-Path $CertDir "cert.pem"
    $SslKeyPath = Join-Path $CertDir "key.pem"

    $UseLetsEncrypt = $false
    $LeCertPath = $null
    $LeKeyPath = $null

    if ($DomainName) {
        Write-Host "  Attempting Let's Encrypt certificate for $DomainName..." -ForegroundColor Yellow

        $certbotCmd = Get-Command certbot -ErrorAction SilentlyContinue
        if (-not $certbotCmd) {
            Write-Host "  Installing certbot..." -ForegroundColor Yellow

            try {
                winget install --id Certbot.Certbot -e --accept-source-agreements --accept-package-agreements --silent 2>$null | Out-Null
                $certbotCmd = Get-Command certbot -ErrorAction SilentlyContinue
            } catch {}

            if (-not $certbotCmd) {
                Write-Host "  winget failed, trying pip..." -ForegroundColor Yellow
                pip install certbot 2>$null | Out-Null
                $certbotCmd = Get-Command certbot -ErrorAction SilentlyContinue
            }

            if (-not $certbotCmd) {
                $testCertbot = python -m certbot --version 2>$null
                if ($LASTEXITCODE -eq 0) {
                    $certbotCmd = @{ Source = "python -m certbot" }
                }
            }
        }

        if ($certbotCmd) {
            $httpRedirect = Get-NetTCPConnection -LocalPort 80 -ErrorAction SilentlyContinue | Where-Object { $_.State -eq 'Listen' }
            if ($httpRedirect) {
                Write-Host "  Temporarily stopping services on port 80 for certificate validation..." -ForegroundColor Yellow
            }

            $certbotUseModule = ($certbotCmd.Source -eq "python")

            if ($certbotUseModule) {
                $certbotArgs = @("-m", "certbot", "certonly", "--standalone", "-d", $DomainName, "--non-interactive", "--agree-tos")
                if ($LeEmail) {
                    $certbotArgs += "--email"
                    $certbotArgs += $LeEmail
                } else {
                    $certbotArgs += "--register-unsafely-without-email"
                }
                $certbotResult = Start-Process python -ArgumentList $certbotArgs -Wait -NoNewWindow -PassThru -RedirectStandardOutput "$env:TEMP\certbot-out.txt"
            } else {
                $certbotArgs = @(
                    "certonly", "--standalone",
                    "-d", $DomainName,
                    "--non-interactive",
                    "--agree-tos"
                )
                if ($LeEmail) {
                    $certbotArgs += "--email"
                    $certbotArgs += $LeEmail
                } else {
                    $certbotArgs += "--register-unsafely-without-email"
                }
                $certbotResult = Start-Process certbot -ArgumentList $certbotArgs -Wait -NoNewWindow -PassThru -RedirectStandardOutput "$env:TEMP\certbot-out.txt"
            }
            $certbotOutput = Get-Content "$env:TEMP\certbot-out.txt" -ErrorAction SilentlyContinue

            if ($certbotResult.ExitCode -eq 0) {
                $UseLetsEncrypt = $true
                $LeCertPath = "C:\ProgramData\certbot\live\$DomainName\fullchain.pem"
                $LeKeyPath = "C:\ProgramData\certbot\live\$DomainName\privkey.pem"

                if (-not (Test-Path $LeCertPath)) {
                    $LeCertPath = "C:\Certbot\live\$DomainName\fullchain.pem"
                    $LeKeyPath = "C:\Certbot\live\$DomainName\privkey.pem"
                }

                if (Test-Path $LeCertPath) {
                    Write-Host "  Let's Encrypt certificate obtained successfully!" -ForegroundColor Green
                    Write-Host "  Certificate for $DomainName is publicly trusted." -ForegroundColor Green
                } else {
                    Write-Host "  [WARN] Let's Encrypt succeeded but cert files not found at expected path." -ForegroundColor Yellow
                    Write-Host "  Falling back to local CA." -ForegroundColor Yellow
                    $UseLetsEncrypt = $false
                }
            } else {
                Write-Host "  [WARN] Let's Encrypt certificate failed." -ForegroundColor Yellow
                if ($certbotOutput) { $certbotOutput | ForEach-Object { Write-Host "    $_" -ForegroundColor Yellow } }
                Write-Host "  Falling back to local CA certificate." -ForegroundColor Yellow
                Write-Host "  To retry, run setup again after installing certbot: winget install Certbot.Certbot" -ForegroundColor Yellow
            }
        } else {
            Write-Host "  [WARN] certbot not available. Falling back to local CA certificate." -ForegroundColor Yellow
            Write-Host "  To install certbot later, run: winget install Certbot.Certbot" -ForegroundColor Yellow
            Write-Host "  Then re-run setup to get a Let's Encrypt certificate." -ForegroundColor Yellow
        }
    }

    if (-not $UseLetsEncrypt) {
        $CaCertPathPy = $CaCertPath -replace '\\', '/'
        $CaKeyPathPy = $CaKeyPath -replace '\\', '/'
        $SslCertPathPy = $SslCertPath -replace '\\', '/'
        $SslKeyPathPy = $SslKeyPath -replace '\\', '/'

        $SanIps = @('127.0.0.1')
        if ($VmHost -ne "YOUR_SERVER_IP") { $SanIps += $VmHost }
        if ($HostIp -and $HostIp -notin $SanIps) { $SanIps += $HostIp }

        if (-not (Test-Path $CaCertPath) -or -not (Test-Path $CaKeyPath)) {
            Write-Host "  Generating local CA..." -ForegroundColor Yellow
            python -c "from app.utils.ssl import generate_ca; generate_ca('$CaCertPathPy', '$CaKeyPathPy')"
        }

        $SanIpsArray = "['" + ($SanIps -join "', '") + "']"
        if ($VmHost -ne "YOUR_SERVER_IP") { $CommonName = $VmHost } else { $CommonName = "localhost" }
        python -c "from app.utils.ssl import generate_cert; generate_cert('$SslCertPathPy', '$SslKeyPathPy', ca_cert_path='$CaCertPathPy', ca_key_path='$CaKeyPathPy', common_name='$CommonName', san_ips=$SanIpsArray, san_dns=['localhost'])"
        $SslCert = "'$SslCertPath'"
        $SslKey = "'$SslKeyPath'"

        Write-Host ""
        Write-Host "  A local CA certificate was generated (Let's Encrypt was not used)." -ForegroundColor Cyan
        Write-Host "  Installing it into the Trusted Root store will remove browser warnings on THIS machine only." -ForegroundColor Cyan
        Write-Host "  Visitors from other machines will still see a warning unless they also install the CA cert." -ForegroundColor Cyan
        Write-Host "  To get a publicly trusted certificate, re-run setup and provide a domain name." -ForegroundColor Cyan
        Write-Host ""
        $InstallCa = Read-Host "  Install CA certificate now? Requires Administrator (y/N)"
        if ($InstallCa -eq 'y' -or $InstallCa -eq 'Y') {
            $isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
            if (-not $isAdmin) {
                Write-Host ""
                Write-Host "  [WARN] Not running as Administrator." -ForegroundColor Yellow
                Write-Host "  Starting a new elevated PowerShell window to install the CA cert..." -ForegroundColor Yellow
                Write-Host ""
                $elevatedScript = "certutil -addstore -f 'Root' '$CaCertPath'; Write-Host ''; Read-Host 'Press Enter to close'"
                Start-Process powershell -ArgumentList "-NoProfile", "-Command", $elevatedScript -Verb RunAs -Wait
                Write-Host "  CA certificate installation complete." -ForegroundColor Green
            } else {
                certutil -addstore -f "Root" $CaCertPath
                if ($LASTEXITCODE -eq 0) {
                    Write-Host "  CA certificate installed to Trusted Root Certification Authorities." -ForegroundColor Green
                } else {
                    Write-Host "  [WARN] certutil failed. Try running setup as Administrator." -ForegroundColor Yellow
                }
            }
            Write-Host "  Restart your browser for the change to take effect." -ForegroundColor Cyan
        } else {
            Write-Host "  Skipped. You can install it later from the launcher menu (option 4)." -ForegroundColor Yellow
        }
    } else {
        $SslCert = "'$LeCertPath'"
        $SslKey = "'$LeKeyPath'"
    }

    # Remote access
    Write-Host ""
    $RemoteAccess = Read-Host "  Enable remote access? (y/N)"
    $EnableRemote = ($RemoteAccess -eq 'y' -or $RemoteAccess -eq 'Y')

    if ($EnableRemote) {
        $DashHost = "0.0.0.0"
        Write-Host "  Remote access enabled. The dashboard will bind to 0.0.0.0 so localhost, 127.0.0.1, LAN IP, and public IP can all work." -ForegroundColor Green
        Write-Host "  Dedicated server: allow TCP $DashboardPort in Windows Firewall/cloud firewall." -ForegroundColor Cyan
        Write-Host "  Home network: port-forward TCP $DashboardPort from your router to this machine's LAN IP." -ForegroundColor Cyan
    } else {
        $DashHost = "127.0.0.1"
        Write-Host "  Local-only access enabled. Use http(s)://localhost:$DashboardPort or http(s)://127.0.0.1:$DashboardPort." -ForegroundColor Green
    }

    $HttpRedirect = $false
    $HttpRedirectPort = 80
    if ($EnableRemote -and ($SslCert -ne "null") -and ($SslKey -ne "null")) {
        Write-Host ""
        Write-Host "  Optional HTTP to HTTPS redirect:" -ForegroundColor Cyan
        Write-Host "    - Not required if you visit https://HOST:$DashboardPort directly." -ForegroundColor Cyan
        Write-Host "    - Useful if you want http://HOST to redirect automatically." -ForegroundColor Cyan
        Write-Host "    - Requires TCP port 80 to be free and forwarded/open." -ForegroundColor Cyan
        $RedirectAnswer = Read-Host "  Enable HTTP redirect on port 80? (y/N)"
        $HttpRedirect = ($RedirectAnswer -eq 'y' -or $RedirectAnswer -eq 'Y')
    }

    # Firewall rules
    Write-Host ""
    if ($EnableRemote) {
        $FirewallPorts = @($DashboardPort)
        if ($HttpRedirect) { $FirewallPorts = @(80) + $FirewallPorts }
        $FirewallPortList = ($FirewallPorts -join ',')
        Write-Host "  Windows Firewall needs to allow incoming TCP port(s): $FirewallPortList" -ForegroundColor Cyan
        Write-Host "  This requires Administrator privileges." -ForegroundColor Cyan
        Write-Host ""
    } else {
        $FirewallPorts = @()
        $FirewallPortList = ""
        Write-Host "  Skipping Windows Firewall rules because remote access is disabled." -ForegroundColor Cyan
    }
    Write-Host ""
    if ($EnableRemote) {
        $SetupFirewall = Read-Host "  Create firewall rules? (Y/n)"
    } else {
        $SetupFirewall = "n"
    }
    if ($SetupFirewall -eq 'n' -or $SetupFirewall -eq 'N') {
        if ($EnableRemote) { Write-Host "  Skipped. Remote access may be blocked by firewall." -ForegroundColor Yellow }
    } else {
        $fwRuleName = "DuneDashboard"
        $fwExists = $null
        try { $fwExists = Get-NetFirewallRule -DisplayName $fwRuleName -ErrorAction SilentlyContinue } catch {}
        if ($fwExists) {
            Write-Host "  Firewall rule already exists." -ForegroundColor Green
        } else {
            $isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
            if (-not $isAdmin) {
                Write-Host "  Starting elevated PowerShell to add firewall rules..." -ForegroundColor Yellow
                $fwScript = "New-NetFirewallRule -DisplayName DuneDashboard -Direction Inbound -Action Allow -Protocol TCP -LocalPort $FirewallPortList; Write-Host ''; Read-Host 'Press Enter to close'"
                Start-Process powershell -ArgumentList "-NoProfile", "-Command", $fwScript -Verb RunAs -Wait
                Write-Host "  Firewall rules added." -ForegroundColor Green
            } else {
                New-NetFirewallRule -DisplayName DuneDashboard -Direction Inbound -Action Allow -Protocol TCP -LocalPort $FirewallPorts
                Write-Host "  Firewall rules added for TCP port(s): $FirewallPortList." -ForegroundColor Green
            }
        }
    }

    # Let's Encrypt auto-renewal
    if ($UseLetsEncrypt) {
        Write-Host ""
        Write-Host "  Setting up Let's Encrypt auto-renewal..." -ForegroundColor Yellow
        $taskName = "DuneDashboard-LeRenewal"
        $existingTask = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        if ($existingTask) {
            Write-Host "  Renewal task already exists." -ForegroundColor Green
        } else {
            $renewAction = New-ScheduledTaskAction -Execute "certbot" -Argument "renew --quiet" -RunLevel Highest
            $renewTrigger = New-ScheduledTaskTrigger -Daily -At 2am
            $renewSettings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
            Register-ScheduledTask -TaskName $taskName -Action $renewAction -Trigger $renewTrigger -Settings $renewSettings -Description "Auto-renew Let's Encrypt certificate for Dune Dashboard" -ErrorAction SilentlyContinue | Out-Null
            Write-Host "  Auto-renewal scheduled (daily at 2 AM). Certificates renew automatically." -ForegroundColor Green
        }
    }

    # Firewall security hardening
    Write-Host ""
    Write-Host "[SECURITY] Firewall Hardening" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  Your game server has services exposed to the internet without authentication." -ForegroundColor Yellow
    Write-Host "  This is a SECURITY RISK - these services are vulnerable to automated attacks." -ForegroundColor Yellow
    Write-Host "  PostgreSQL was ALREADY exploited by cryptocurrency mining malware." -ForegroundColor Red
    Write-Host ""
    Write-Host "  Recommended: Block these ports so only localhost/VPN can reach them:" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  [1] PostgreSQL (port 15432)   - VULNERABLE (ALREADY EXPLOITED - default postgres/postgres)" -ForegroundColor Red
    Write-Host "  [2] File Browser (port 18888) - VULNERABLE (no auth - exposes server files)" -ForegroundColor Yellow
    Write-Host "  [3] Battlegroup Director (port 31820) - VULNERABLE (no auth - exposes server API)" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  You can change these anytime from the Server page in the dashboard." -ForegroundColor Cyan
    Write-Host ""

    $val = Read-Host "  Block PostgreSQL (15432)? (Y/n)"
    $BlockPostgres = -not ($val -eq 'n' -or $val -eq 'N')
    if ($BlockPostgres) { Write-Host "  Will block port 15432 (PostgreSQL)" -ForegroundColor Green }
    else { Write-Host "  Skipped - port 15432 will remain open to the internet" -ForegroundColor Red }

    Write-Host ""
    $val = Read-Host "  Block File Browser (18888)? (Y/n)"
    $BlockFileBrowser = -not ($val -eq 'n' -or $val -eq 'N')
    if ($BlockFileBrowser) { Write-Host "  Will block port 18888 (File Browser)" -ForegroundColor Green }
    else { Write-Host "  Skipped - port 18888 will remain open to the internet" -ForegroundColor Yellow }

    Write-Host ""
    $val = Read-Host "  Block Battlegroup Director (31820)? (Y/n)"
    $BlockDirector = -not ($val -eq 'n' -or $val -eq 'N')
    if ($BlockDirector) { Write-Host "  Will block port 31820 (Director)" -ForegroundColor Green }
    else { Write-Host "  Skipped - port 31820 will remain open to the internet" -ForegroundColor Yellow }

    # Save settings
    Write-Host ""
    Write-Host "[5/6] Saving settings..." -ForegroundColor Yellow

    $secret = -join ((65..90) + (97..122) + (48..57) | Get-Random -Count 32 | ForEach-Object {[char]$_})

    Write-Host "  Hashing password with Argon2..." -ForegroundColor Yellow
    $pwScript = @"
import sys
from argon2 import PasswordHasher
ph = PasswordHasher()
print(ph.hash(sys.argv[1]))
"@
    $pwScript | Out-File -FilePath "$env:TEMP\hash_pw.py" -Encoding utf8 -Force
    $hashResult = python "$env:TEMP\hash_pw.py" $AuthPass 2>$null
    Remove-Item "$env:TEMP\hash_pw.py" -Force -ErrorAction SilentlyContinue
    if ($hashResult -and $hashResult -match '^\$argon2') {
        $AuthHash = $hashResult.Trim()
        Write-Host "  Password hashed successfully." -ForegroundColor Green
    } else {
        Write-Host "  [ERROR] Failed to hash password. Argon2 may not be installed." -ForegroundColor Red
        Write-Host "  Run: pip install argon2-cffi" -ForegroundColor Yellow
        return
    }

    $sshKeyPath = if ($FoundKey) { $FoundKey -replace '\\', '\\' } else { "null" }
    $leDomain = if ($DomainName) { $DomainName } else { "null" }
    $leEmail = if ($LeEmail) { $LeEmail } else { "null" }
    $vmLocalIp = if ($vmIp) { $vmIp } else { "null" }
    $settingsContent = @"
server:
  host: '$VmHost'
  local_ip: '$vmLocalIp'
  user: $ServerUser
  ssh_key: '$sshKeyPath'

dashboard:
  host: $DashHost
  port: $DashboardPort
  debug: false
  secret_key: $secret
  ssl_cert: $SslCert
  ssl_key: $SslKey
  ssl_domain: $leDomain
  ssl_email: $leEmail
  http_redirect: $HttpRedirect
  http_redirect_port: $HttpRedirectPort

database:
  host: $DbHost
  port: $DbPort
  user: postgres
  password: postgres
  name: dune
  schema: dune
  min_connections: 2
  max_connections: 10

kubernetes:
  namespace: '$K8sNamespace'
  battlegroup_script: /home/dune/.dune/bin/battlegroup

director:
  port: $DirectorPort

filebrowser:
  port: $FileBrowserPort

firewall:
  block_filebrowser: $BlockFileBrowser
  block_director: $BlockDirector
  block_postgres: $BlockPostgres

cache:
  chat_pod_ttl: 60
  chat_messages_ttl: 10
  static_data_ttl: 300

auth:
  enabled: true
  username: $AuthUser
  password_hash: '$AuthHash'

logging:
  level: INFO
  file: logs/dashboard.log
  max_bytes: 10485760
  backup_count: 5
"@

    [System.IO.File]::WriteAllText((Join-Path $ProjectRoot "settings.yaml"), $settingsContent, [System.Text.UTF8Encoding]::new($false))
    Write-Host "  Settings saved to settings.yaml" -ForegroundColor Green

    New-Item -ItemType Directory -Path (Join-Path $ProjectRoot "logs") -Force | Out-Null

    Write-Host ""
    Write-Host "[6/6] Verifying setup..." -ForegroundColor Yellow
    $verifyResult = python -W ignore -c "from app.config import load_settings; s = load_settings(); print('OK - settings loaded')" 2>$null
    if ($verifyResult -match "OK") {
        Write-Host "  $verifyResult" -ForegroundColor Green
    } else {
        Write-Host "  [WARN] Verification skipped." -ForegroundColor Yellow
    }

    Write-Host ""
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host "  Setup Complete!" -ForegroundColor Cyan
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host ""

    # Check if SSH key is valid for the server
    $SshValid = $false
    if ($FoundKey -and (Test-Path $FoundKey) -and $VmHost -ne "YOUR_SERVER_IP") {
        $testOut = ssh -i $FoundKey -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -o BatchMode=yes "${ServerUser}@${VmHost}" "echo ok" 2>$null
        $SshValid = ($testOut -eq "ok")
    }

    if (-not $SshValid) {
        if ($VmHost -eq "YOUR_SERVER_IP") {
            Write-Host "  Remember to edit settings.yaml with your server IP before starting." -ForegroundColor Yellow
        } else {
            Write-Host "  SSH key is not configured or failed to connect." -ForegroundColor Yellow
        }
        Write-Host ""
        Write-Host "  Then start the dashboard with:" -ForegroundColor Yellow
        Write-Host ""
        Write-Host "    .\launcher.ps1 (option 1)" -ForegroundColor Cyan
    } else {
        Write-Host "  SSH connection verified." -ForegroundColor Green

        $portsToBlock = @()
        if ($BlockFileBrowser) { $portsToBlock += 18888 }
        if ($BlockDirector) { $portsToBlock += 31820 }
        if ($BlockPostgres) { $portsToBlock += 15432 }

        if ($portsToBlock.Count -gt 0) {
            Write-Host ""
            Write-Host "  Applying firewall rules to block ports: $($portsToBlock -join ', ')..." -ForegroundColor Yellow

            $tmpFwScript = Join-Path $env:TEMP ([System.IO.Path]::GetRandomFileName() + ".sh")
            $fwContent = "for PORT in $($portsToBlock -join ' '); do`n"
            $fwContent += "  if iptables -t mangle -C PREROUTING -p tcp --dport `$PORT -s 127.0.0.1 -j ACCEPT 2>/dev/null; then`n"
            $fwContent += "    echo 'Port `$PORT already blocked'`n"
            $fwContent += "  else`n"
            $fwContent += "    iptables -I INPUT 1 -p tcp --dport `$PORT -s 127.0.0.1 -j ACCEPT`n"
            $fwContent += "    iptables -I INPUT 2 -p tcp --dport `$PORT -j DROP`n"
            $fwContent += "    iptables -I FORWARD 1 -p tcp --dport `$PORT -s 127.0.0.1 -j ACCEPT`n"
            $fwContent += "    iptables -I FORWARD 2 -p tcp --dport `$PORT -j DROP`n"
            $fwContent += "    iptables -t mangle -I PREROUTING 1 -p tcp --dport `$PORT -s 127.0.0.1 -j ACCEPT`n"
            $fwContent += "    iptables -t mangle -I PREROUTING 2 -p tcp --dport `$PORT -j DROP`n"
            $fwContent += "    echo 'Port `$PORT blocked'`n"
            $fwContent += "  fi`n"
            $fwContent += "done`n"
            $fwContent += "echo 'FIREWALL_DONE'`n"
            $fwContent | Out-File -FilePath $tmpFwScript -Encoding ascii -NoNewline -Force
            $bytes = [System.IO.File]::ReadAllBytes($tmpFwScript)
            Remove-Item $tmpFwScript -Force -ErrorAction SilentlyContinue
            $b64 = [Convert]::ToBase64String($bytes)
            $fwOut = ssh -i $FoundKey -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15 "${ServerUser}@${VmHost}" "echo '$b64' | base64 -d > /tmp/fw.sh && sudo bash /tmp/fw.sh && rm /tmp/fw.sh" 2>&1
            if ($fwOut -match "FIREWALL_DONE") {
                Write-Host "  Firewall rules applied successfully!" -ForegroundColor Green
            } else {
                Write-Host "  [WARN] Firewall rules may not have applied correctly." -ForegroundColor Yellow
                if ($fwOut.Length -gt 300) {
                    Write-Host "  Output: $($fwOut.Substring(0, 300))" -ForegroundColor Yellow
                } else {
                    Write-Host "  Output: $fwOut" -ForegroundColor Yellow
                }
            }
        }

        Write-Host ""
        Write-Host "  Start the dashboard with:" -ForegroundColor Yellow
        Write-Host ""
        Write-Host "    .\launcher.ps1 (option 1)" -ForegroundColor Cyan
    }

    Write-Host ""
    Write-Host "  Press Enter to return to the main menu..." -ForegroundColor Cyan
    Read-Host "  "
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
            "$env:LOCALAPPDATA\DuneAwakeningServer\sshKey",
            $LocalKey,
            $ParentKey,
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
        "4" { Install-CaCert; break }
        "5" { Clean-CaCerts; break }
        "Q" { Write-Host ""; Write-Host "  Goodbye!"; Write-Host ""; exit 0 }
        "q" { Write-Host ""; Write-Host "  Goodbye!"; Write-Host ""; exit 0 }
        default { Write-Host ""; Write-Host "  Invalid choice. Please enter 1, 2, 3, 4, 5, or Q." -ForegroundColor Yellow; Write-Host "" }
    }

    Write-Host ""
}
