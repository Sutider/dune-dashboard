# Dune Awakening Dashboard - Setup
# Run this ONCE per server. After that, use start.ps1

$ErrorActionPreference = "Stop"

$ProjectRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location -LiteralPath $ProjectRoot

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  Dune Awakening Dashboard - Setup" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""

# Check if this is a re-run (existing settings or logs)
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
        exit 0
    }
    
    Write-Host ""
    Write-Host "  Cleaning existing data..." -ForegroundColor Yellow
    
    if (Test-Path (Join-Path $ProjectRoot "settings.yaml")) {
        Remove-Item (Join-Path $ProjectRoot "settings.yaml") -Force
        Write-Host "    Removed settings.yaml" -ForegroundColor Green
    }
    if (Test-Path (Join-Path $ProjectRoot "logs")) {
        Remove-Item (Join-Path $ProjectRoot "logs") -Recurse -Force
        Write-Host "    Removed logs/" -ForegroundColor Green
    }
    if (Test-Path (Join-Path $ProjectRoot "instance")) {
        Remove-Item (Join-Path $ProjectRoot "instance") -Recurse -Force
        Write-Host "    Removed instance/" -ForegroundColor Green
    }
    if (Test-Path (Join-Path $ProjectRoot "ssl")) {
        Remove-Item (Join-Path $ProjectRoot "ssl") -Recurse -Force
        Write-Host "    Removed ssl/" -ForegroundColor Green
    }
    if (Test-Path (Join-Path $ProjectRoot "__pycache__")) {
        Remove-Item (Join-Path $ProjectRoot "__pycache__") -Recurse -Force
        Write-Host "    Removed __pycache__/" -ForegroundColor Green
    }
    
    # Clean app/__pycache__ and routes/__pycache__ etc.
    $cacheDirs = Get-ChildItem -Path (Join-Path $ProjectRoot "app") -Recurse -Directory -Filter "__pycache__" -ErrorAction SilentlyContinue
    foreach ($dir in $cacheDirs) {
        Remove-Item $dir.FullName -Recurse -Force
    }
    if ($cacheDirs.Count -gt 0) {
        Write-Host "    Removed $($cacheDirs.Count) Python cache folders" -ForegroundColor Green
    }
    
    Write-Host "  Clean complete!" -ForegroundColor Green
    Write-Host ""
}

# Check Python
Write-Host "[1/6] Checking Python..." -ForegroundColor Yellow
try {
    $pythonVersion = python --version 2>&1
    Write-Host "  Found: $pythonVersion" -ForegroundColor Green
} catch {
    Write-Host "  [ERROR] Python not found. Install Python 3.8+ first." -ForegroundColor Red
    exit 1
}

# Install dependencies
Write-Host ""
Write-Host "[2/6] Installing dependencies..." -ForegroundColor Yellow
pip install -r (Join-Path $ProjectRoot "requirements.txt") --quiet
if ($LASTEXITCODE -eq 0) {
    Write-Host "  Dependencies installed" -ForegroundColor Green
} else {
    Write-Host "  [WARN] Some packages may have failed. Continuing..." -ForegroundColor Yellow
}

# Configure SSH key
Write-Host ""
Write-Host "[3/6] Configuring SSH key..." -ForegroundColor Yellow
$TargetKey = Join-Path $ProjectRoot "internal-scripts\ssh\sshKey"
$SshKeyPaths = @(
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
    # If found in temp, copy to project for portability
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
$DirectorPort = "32479"
$FileBrowserPort = "18888"
$AuthUser = "admin"
$AuthPass = ""

# Try to detect VM IP - prioritize local Hyper-V, then local network IPs from known_hosts
function Test-IsLocalIP($ip) {
    if ($ip -match '^192\.168\.') { return $true }
    if ($ip -match '^10\.') { return $true }
    if ($ip -match '^172\.(1[6-9]|2[0-9]|3[0-1])\.') { return $true }
    return $false
}

# First: try direct Hyper-V detection
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
    # Fallback: scan known_hosts and prioritize local IPs
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

# Auto-detect external IP (try external service first, then local interfaces)
try {
    $HostIp = (Invoke-WebRequest -Uri "https://api.ipify.org" -UseBasicParsing -TimeoutSec 5).Content.Trim()
} catch {
    $localIps = Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.InterfaceAlias -notlike 'Loopback*' -and $_.PrefixOrigin -ne 'WellKnown' } | Select-Object -ExpandProperty IPAddress
    if ($localIps.Count -gt 0) { $HostIp = $localIps[0] }
}

# Ask for VM IP (SSH)
Write-Host ""
Write-Host "  VM External IP - used for SSH connection to your game server" -ForegroundColor Cyan
$val = Read-Host "  VM Host [$VmHost]"
if ($val) { $VmHost = $val }

# Ask for Host IP (cert SANs)
Write-Host ""
Write-Host "  This Machine's External IP - used for SSL certificate so remote access works" -ForegroundColor Cyan
if ($HostIp) { $hostIpHint = "$HostIp (auto-detected)" } else { $hostIpHint = "Your Windows machine's external IP" }
$val = Read-Host "  Host IP [$hostIpHint]"
if ($val) { $HostIp = $val }
elseif (-not $HostIp) { $HostIp = $null }

# Ask for domain name (Let's Encrypt)
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
    $testOut = cmd /c "ssh -i `"$FoundKey`" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 -o BatchMode=yes dune@$VmHost echo ok" 2>$null
    if ($testOut -match "ok") {
        Write-Host "  SSH connection OK" -ForegroundColor Green
        $nsOut = cmd /c "ssh -i `"$FoundKey`" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -o BatchMode=yes dune@$VmHost sudo kubectl get namespaces -o name" 2>$null
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
        Write-Host "  [WARN] SSH failed for $VmHost. You may need to enter the namespace manually." -ForegroundColor Yellow
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

$val = Read-Host "  Auth Password (required)"
if ($val) { $AuthPass = $val }
else {
    Write-Host "  [ERROR] Password is required. Setup cancelled." -ForegroundColor Red
    exit 1
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

    # Check for certbot
    $certbotCmd = Get-Command certbot -ErrorAction SilentlyContinue
    if (-not $certbotCmd) {
        Write-Host "  Installing certbot..." -ForegroundColor Yellow
        
        # Try winget first
        try {
            winget install --id Certbot.Certbot -e --accept-source-agreements --accept-package-agreements --silent 2>$null | Out-Null
            $certbotCmd = Get-Command certbot -ErrorAction SilentlyContinue
        } catch {}

        # Try pip as fallback
        if (-not $certbotCmd) {
            Write-Host "  winget failed, trying pip..." -ForegroundColor Yellow
            pip install certbot 2>$null | Out-Null
            $certbotCmd = Get-Command certbot -ErrorAction SilentlyContinue
        }

        # Try running via python -m certbot
        if (-not $certbotCmd) {
            $testCertbot = python -m certbot --version 2>$null
            if ($LASTEXITCODE -eq 0) {
                $certbotCmd = @{ Source = "python -m certbot" }
            }
        }
    }

    if ($certbotCmd) {
        # Stop anything on port 80 for the challenge
        $httpRedirect = Get-NetTCPConnection -LocalPort 80 -ErrorAction SilentlyContinue | Where-Object { $_.State -eq 'Listen' }
        if ($httpRedirect) {
            Write-Host "  Temporarily stopping services on port 80 for certificate validation..." -ForegroundColor Yellow
        }

        $certbotExe = if ($certbotCmd.Source -eq "python") { "python" } else { "certbot" }
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

            # Fallback path check
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
            Write-Host "  To retry, run setup.ps1 again after installing certbot: winget install Certbot.Certbot" -ForegroundColor Yellow
        }
    } else {
        Write-Host "  [WARN] certbot not available. Falling back to local CA certificate." -ForegroundColor Yellow
        Write-Host "  To install certbot later, run: winget install Certbot.Certbot" -ForegroundColor Yellow
        Write-Host "  Then re-run setup.ps1 to get a Let's Encrypt certificate." -ForegroundColor Yellow
    }
}

if (-not $UseLetsEncrypt) {
    # Use forward slashes for Python to avoid unicode escape issues
    $CaCertPathPy = $CaCertPath -replace '\\', '/'
    $CaKeyPathPy = $CaKeyPath -replace '\\', '/'
    $SslCertPathPy = $SslCertPath -replace '\\', '/'
    $SslKeyPathPy = $SslKeyPath -replace '\\', '/'

    # Auto-detect local Windows IP for cert SANs
    $SanIps = @('127.0.0.1')
    if ($VmHost -ne "YOUR_SERVER_IP") { $SanIps += $VmHost }
    if ($HostIp -and $HostIp -notin $SanIps) { $SanIps += $HostIp }

    # Generate CA if it doesn't exist
    if (-not (Test-Path $CaCertPath) -or -not (Test-Path $CaKeyPath)) {
        Write-Host "  Generating local CA..." -ForegroundColor Yellow
        python -c "from app.utils.ssl import generate_ca; generate_ca('$CaCertPathPy', '$CaKeyPathPy')"
    }

    # Generate server cert signed by CA
    $SanIpsArray = "['" + ($SanIps -join "', '") + "']"
    if ($VmHost -ne "YOUR_SERVER_IP") { $CommonName = $VmHost } else { $CommonName = "localhost" }
    python -c "from app.utils.ssl import generate_cert; generate_cert('$SslCertPathPy', '$SslKeyPathPy', ca_cert_path='$CaCertPathPy', ca_key_path='$CaKeyPathPy', common_name='$CommonName', san_ips=$SanIpsArray, san_dns=['localhost'])"
    $SslCert = "'$SslCertPath'"
    $SslKey = "'$SslKeyPath'"

    # Offer to install CA cert into Windows Trusted Root store
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
        Write-Host "  Skipped. You can install it later by running:" -ForegroundColor Yellow
        Write-Host "    .\install-ca-cert.bat" -ForegroundColor Cyan
    }
} else {
    $SslCert = "'$LeCertPath'"
    $SslKey = "'$LeKeyPath'"
}

# Firewall rules for HTTP redirect (port 80) and HTTPS dashboard
Write-Host ""
Write-Host "  Windows Firewall needs to allow incoming connections on ports 80 and $DashboardPort" -ForegroundColor Cyan
Write-Host "  for remote access to work. This requires Administrator privileges." -ForegroundColor Cyan
Write-Host ""
$SetupFirewall = Read-Host "  Create firewall rules? (Y/n)"
if ($SetupFirewall -eq 'n' -or $SetupFirewall -eq 'N') {
    Write-Host "  Skipped. Remote access may be blocked by firewall." -ForegroundColor Yellow
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
            $fwScript = "New-NetFirewallRule -DisplayName DuneDashboard -Direction Inbound -Action Allow -Protocol TCP -LocalPort 80,$DashboardPort; Write-Host ''; Read-Host 'Press Enter to close'"
            Start-Process powershell -ArgumentList "-NoProfile", "-Command", $fwScript -Verb RunAs -Wait
            Write-Host "  Firewall rules added." -ForegroundColor Green
        } else {
            New-NetFirewallRule -DisplayName DuneDashboard -Direction Inbound -Action Allow -Protocol TCP -LocalPort 80, $DashboardPort
            Write-Host "  Firewall rules added for ports 80 (HTTP redirect) and $DashboardPort (HTTPS)." -ForegroundColor Green
        }
    }
}

# Let's Encrypt auto-renewal scheduled task
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

# Remote access
Write-Host ""
$RemoteAccess = Read-Host "  Enable remote access? (y/N)"
$EnableRemote = ($RemoteAccess -eq 'y' -or $RemoteAccess -eq 'Y')

if ($EnableRemote) {
    $DashHost = "0.0.0.0"
    Write-Host "  Remote access enabled with HTTPS" -ForegroundColor Green
} else {
    $DashHost = "127.0.0.1"
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
Write-Host "  Block PostgreSQL (15432)? (Y/n)" -ForegroundColor Cyan
$val = Read-Host "  Block PostgreSQL (15432)? (Y/n)"
$BlockPostgres = -not ($val -eq 'n' -or $val -eq 'N')
if ($BlockPostgres) { Write-Host "  Will block port 15432 (PostgreSQL)" -ForegroundColor Green }
else { Write-Host "  Skipped - port 15432 will remain open to the internet" -ForegroundColor Red }

Write-Host ""
Write-Host "  Block File Browser (18888)? (Y/n)" -ForegroundColor Cyan
$val = Read-Host "  Block File Browser (18888)? (Y/n)"
$BlockFileBrowser = -not ($val -eq 'n' -or $val -eq 'N')
if ($BlockFileBrowser) { Write-Host "  Will block port 18888 (File Browser)" -ForegroundColor Green }
else { Write-Host "  Skipped - port 18888 will remain open to the internet" -ForegroundColor Yellow }

Write-Host ""
Write-Host "  Block Battlegroup Director (31820)? (Y/n)" -ForegroundColor Cyan
$val = Read-Host "  Block Battlegroup Director (31820)? (Y/n)"
$BlockDirector = -not ($val -eq 'n' -or $val -eq 'N')
if ($BlockDirector) { Write-Host "  Will block port 31820 (Director)" -ForegroundColor Green }
else { Write-Host "  Skipped - port 31820 will remain open to the internet" -ForegroundColor Yellow }

Write-Host ""
Write-Host "[5/6] Saving settings..." -ForegroundColor Yellow

# Generate secret key
$secret = -join ((65..90) + (97..122) + (48..57) | Get-Random -Count 32 | ForEach-Object {[char]$_})

# Hash the password using Argon2
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
    exit 1
}

# Write settings.yaml (UTF-8 without BOM)
$sshKeyPath = if ($FoundKey) { $FoundKey -replace '\\', '\\' } else { "null" }
$leDomain = if ($DomainName) { $DomainName } else { "null" }
$leEmail = if ($LeEmail) { $LeEmail } else { "null" }
$settingsContent = @"
server:
  host: '$VmHost'
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

database:
  host: 127.0.0.1
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

# Create logs directory
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
    Write-Host "    .\start.ps1" -ForegroundColor Cyan
} else {
    Write-Host "  SSH connection verified." -ForegroundColor Green

    # Apply firewall rules if requested
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
    Write-Host "    .\start.ps1" -ForegroundColor Cyan
}

Write-Host ""
