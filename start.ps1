# Dune Awakening Dashboard Launcher
# Starts SSH tunnel, DB port-forward, then runs the dashboard

$ErrorActionPreference = "Stop"

$ProjectRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$SettingsFile = Join-Path $ProjectRoot "settings.yaml"

# Check if settings exist
if (-not (Test-Path $SettingsFile)) {
    Write-Host "[WARN] settings.yaml not found. Running setup..." -ForegroundColor Yellow
    & (Join-Path $ProjectRoot "setup.ps1")
    if (-not (Test-Path $SettingsFile)) {
        Write-Host "[ERROR] Setup failed." -ForegroundColor Red
        exit 1
    }
}

# Read settings via Python script (avoids YAML parsing issues in PowerShell)
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
$readSettingsScript | Out-File -FilePath "$env:TEMP\read_settings.py" -Encoding utf8 -Force
$settingsJson = python "$env:TEMP\read_settings.py" $SettingsFile 2>$null
if (-not $settingsJson) {
    Write-Host "[ERROR] Failed to read settings.yaml" -ForegroundColor Red
    exit 1
}
$settings = $settingsJson | ConvertFrom-Json

$SSHHost = $settings.server.host
$SSHUser = $settings.server.user
$LocalPort = [int]$settings.database.port
$Namespace = $settings.kubernetes.namespace
$DashboardPort = [int]$settings.dashboard.port

# Find SSH key (prefer project-local for portability)
$SSHKeySrc = $settings.server.ssh_key
$LocalKey = Join-Path $ProjectRoot "internal-scripts\ssh\sshKey"
if (Test-Path $LocalKey) {
    $SSHKeySrc = $LocalKey
} elseif (-not $SSHKeySrc -or $SSHKeySrc -eq 'null' -or [string]::IsNullOrEmpty($SSHKeySrc)) {
    $keyPaths = @(
        $LocalKey,
        (Join-Path (Split-Path $ProjectRoot) "internal-scripts\ssh\sshKey"),
        "$env:TEMP\dune-tunnel-key",
        "$env:TEMP\dune-awakening-server-sshKey"
    )
    foreach ($kp in $keyPaths) {
        if (Test-Path $kp) {
            $SSHKeySrc = $kp
            break
        }
    }
}

if (-not $SSHKeySrc -or -not (Test-Path $SSHKeySrc)) {
    Write-Host "[ERROR] SSH key not found. Set ssh_key in settings.yaml or place key in:" -ForegroundColor Red
    Write-Host "  - $ProjectRoot\internal-scripts\ssh\sshKey" -ForegroundColor Yellow
    Write-Host "  - (parent)\internal-scripts\ssh\sshKey" -ForegroundColor Yellow
    Write-Host "  - %TEMP%\dune-tunnel-key" -ForegroundColor Yellow
    exit 1
}

# Copy key to temp with proper permissions
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

# Kill any existing SSH tunnels on the target port
Get-NetTCPConnection -LocalPort $LocalPort -ErrorAction SilentlyContinue | ForEach-Object {
    Get-Process -Id $_.OwningProcess -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -eq 'ssh' } | Stop-Process -Force -ErrorAction SilentlyContinue
}
Start-Sleep 1

Write-Host "[1/4] Starting SSH tunnel (localhost:$LocalPort -> VM)..." -ForegroundColor Yellow
$sshArgs = @(
    "-i", $SSHKey,
    "-o", "StrictHostKeyChecking=accept-new",
    "-o", "ServerAliveInterval=30",
    "-o", "ServerAliveCountMax=3",
    "-L", "${LocalPort}:localhost:${LocalPort}",
    "-N", "${SSHUser}@${SSHHost}"
)
$sshTunnel = Start-Process ssh -ArgumentList $sshArgs -PassThru -WindowStyle Hidden

$connected = $false
for ($i = 0; $i -lt 30; $i++) {
    Start-Sleep -Seconds 1
    if ($sshTunnel.HasExited) {
        Write-Host "[ERROR] SSH tunnel exited (code: $($sshTunnel.ExitCode))" -ForegroundColor Red
        exit 1
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
    Write-Host "[ERROR] SSH tunnel did not connect within 30s" -ForegroundColor Red
    Stop-Process -Id $sshTunnel.Id -Force -ErrorAction SilentlyContinue
    exit 1
}
Write-Host "[OK]   SSH tunnel up on localhost:$LocalPort" -ForegroundColor Green

# Start DB port-forward on VM
Write-Host "[2/4] Starting DB port-forward on VM..." -ForegroundColor Yellow

if (-not $Namespace -or $Namespace -eq '') {
    Write-Host "[ERROR] Kubernetes namespace is empty." -ForegroundColor Red
    Write-Host "  Edit settings.yaml and set kubernetes.namespace, or re-run setup.ps1 with SSH access." -ForegroundColor Yellow
    Stop-Process -Id $sshTunnel.Id -Force -ErrorAction SilentlyContinue
    exit 1
}

$DBService = "${Namespace}-db-dbdepl-svc"

# Try to find the actual DB service name
$pfCheck = ssh -i $SSHKey -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 ${SSHUser}@${SSHHost} "sudo kubectl get svc -n ${Namespace} -o name" 2>$null
if ($pfCheck) {
    $dbSvc = ($pfCheck -split "`n") | Where-Object { $_ -match 'db.*svc' -or $_ -match 'postgres' -or $_ -match 'pg' } | Select-Object -First 1
    if ($dbSvc) {
        $DBService = $dbSvc -replace 'service/', ''
        Write-Host "  Found DB service: $DBService" -ForegroundColor Green
    }
}

$RemotePort = 15432
$pfCmd = "ssh -i `"$SSHKey`" -o StrictHostKeyChecking=accept-new -o ServerAliveInterval=30 ${SSHUser}@${SSHHost} `"nohup sudo kubectl port-forward -n ${Namespace} svc/${DBService} ${LocalPort}:${RemotePort} > /tmp/pf.log 2>&1 &`""
cmd /c $pfCmd
Start-Sleep -Seconds 5

# Check DB
Write-Host "[3/4] Checking database..." -ForegroundColor Yellow
$dbTest = $false
for ($i = 0; $i -lt 15; $i++) {
    try {
        $result = python -W ignore -c "import psycopg2; c = psycopg2.connect(host='localhost', port=$LocalPort, user='postgres', password='postgres', dbname='dune', connect_timeout=3); c.close(); print('ok')" 2>$null
        if ($result -match 'ok') { $dbTest = $true; break }
    } catch {}
    Start-Sleep -Seconds 1
}
if (-not $dbTest) {
    Write-Host "[ERROR] Database connection failed." -ForegroundColor Red
    Write-Host "Checking port-forward log on VM..." -ForegroundColor Yellow
    $pfLog = ssh -i $SSHKey -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 ${SSHUser}@${SSHHost} "cat /tmp/pf.log" 2>$null
    if ($pfLog) { Write-Host $pfLog -ForegroundColor Red }
    else { Write-Host "Log empty or unreadable." -ForegroundColor Yellow }
    Write-Host ""
    Write-Host "Verify DB service exists:" -ForegroundColor Yellow
    Write-Host "  ssh -i $SSHKey ${SSHUser}@${SSHHost} 'sudo kubectl get svc -n $Namespace'" -ForegroundColor Cyan
    exit 1
}
Write-Host "[OK]   Database connected" -ForegroundColor Green

# Check firewall rules
$fwRuleName = "DuneDashboard"
$fwExists = $null
try { $fwExists = Get-NetFirewallRule -DisplayName $fwRuleName -ErrorAction SilentlyContinue } catch {}
if (-not $fwExists) {
    Write-Host "[WARN] No firewall rule found. Remote access to the dashboard will be blocked." -ForegroundColor Yellow
    Write-Host "  Ports needed: 80 (HTTP redirect), $DashboardPort (HTTPS)" -ForegroundColor Yellow
    Write-Host ""
    $SetupFirewall = Read-Host "  Create firewall rules now? Requires Administrator (Y/n)"
    if ($SetupFirewall -ne 'n' -and $SetupFirewall -ne 'N') {
        $isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        if (-not $isAdmin) {
            Write-Host "  Starting elevated PowerShell to add firewall rules..." -ForegroundColor Yellow
            $fwScript = "New-NetFirewallRule -DisplayName DuneDashboard -Direction Inbound -Action Allow -Protocol TCP -LocalPort 80,$DashboardPort; Write-Host ''; Read-Host 'Press Enter to close'"
            Start-Process powershell -ArgumentList "-NoProfile", "-Command", $fwScript -Verb RunAs -Wait
            Write-Host "[OK]   Firewall rules added." -ForegroundColor Green
        } else {
            New-NetFirewallRule -DisplayName DuneDashboard -Direction Inbound -Action Allow -Protocol TCP -LocalPort 80, $DashboardPort
            Write-Host "[OK]   Firewall rules added for ports 80, $DashboardPort." -ForegroundColor Green
        }
    } else {
        Write-Host "  Skipped. External access will be blocked." -ForegroundColor Yellow
    }
    Write-Host ""
}

# Check dependencies
Write-Host "[4/4] Starting dashboard..." -ForegroundColor Yellow
$pipCheck = python -c "import flask_socketio, yaml, flask_login" 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Host "  Installing dependencies..." -ForegroundColor Yellow
    pip install -r (Join-Path $ProjectRoot "requirements.txt") --quiet
}

Set-Location -LiteralPath $ProjectRoot
python run.py

# Cleanup
Write-Host "Stopping tunnels..." -ForegroundColor Cyan
Stop-Process -Id $sshTunnel.Id -Force -ErrorAction SilentlyContinue
$pkillCmd = "ssh -i `"$SSHKey`" -o StrictHostKeyChecking=accept-new ${SSHUser}@${SSHHost} `"pkill -f kubectl-port-forward`""
cmd /c $pkillCmd 2>$null
