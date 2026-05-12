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
$IsReRun = (Test-Path (Join-Path $ProjectRoot "settings.yaml")) -or (Test-Path (Join-Path $ProjectRoot "logs")) -or (Test-Path (Join-Path $ProjectRoot "instance"))

if ($IsReRun) {
    Write-Host "  [WARNING] Existing dashboard data detected!" -ForegroundColor Red
    Write-Host ""
    Write-Host "  This will WIPE the following and start fresh:" -ForegroundColor Yellow
    Write-Host "    - settings.yaml (configuration)" -ForegroundColor Yellow
    Write-Host "    - logs/ (all log files)" -ForegroundColor Yellow
    Write-Host "    - instance/ (SQLite database)" -ForegroundColor Yellow
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

$ServerHost = "YOUR_SERVER_IP"
$ServerUser = "dune"
$K8sNamespace = ""
$DashboardPort = "5050"
$DbPort = "15433"
$DirectorPort = "32479"
$FileBrowserPort = "18888"
$AuthUser = "admin"
$AuthPass = "changeme"

if ($FoundKey -and $ServerHost -ne "YOUR_SERVER_IP") {
    # Test SSH
    $testOut = ssh -i $FoundKey -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -o BatchMode=yes "dune@$ServerHost" "echo ok" 2>$null
    if ($testOut -eq "ok") {
        Write-Host "  SSH connection OK" -ForegroundColor Green

        # Auto-detect namespace
        $nsOut = ssh -i $FoundKey -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -o BatchMode=yes "dune@$ServerHost" "sudo kubectl get namespaces -o name" 2>$null
        if ($nsOut) {
            foreach ($line in $nsOut -split "`n") {
                $ns = $line -replace 'namespace/', ''
                if ($ns -match '^funcom-seabass-') {
                    $K8sNamespace = $ns
                    Write-Host "  Namespace: $K8sNamespace" -ForegroundColor Green
                    break
                }
            }
        }
    } else {
        Write-Host "  [WARN] SSH failed. Using defaults." -ForegroundColor Yellow
    }
}

# Interactive review/edit
Write-Host ""
Write-Host "  Review settings (press Enter to accept, or type new value):" -ForegroundColor Cyan
Write-Host ""

$val = Read-Host "  Server Host [$ServerHost]"
if ($val) { $ServerHost = $val }

$val = Read-Host "  Server User [$ServerUser]"
if ($val) { $ServerUser = $val }

$val = Read-Host "  SSH Key Path [$FoundKey]"
if ($val) { $FoundKey = $val }

$val = Read-Host "  K8s Namespace [$K8sNamespace]"
if ($val) { $K8sNamespace = $val }

$val = Read-Host "  Dashboard Port [$DashboardPort]"
if ($val) { $DashboardPort = $val }

$val = Read-Host "  DB Local Port [$DbPort]"
if ($val) { $DbPort = $val }

$val = Read-Host "  Director Port [$DirectorPort]"
if ($val) { $DirectorPort = $val }

$val = Read-Host "  FileBrowser Port [$FileBrowserPort]"
if ($val) { $FileBrowserPort = $val }

$val = Read-Host "  Auth Username [$AuthUser]"
if ($val) { $AuthUser = $val }

$val = Read-Host "  Auth Password [$AuthPass]"
if ($val) { $AuthPass = $val }

Write-Host ""
Write-Host "[5/6] Saving settings..." -ForegroundColor Yellow

# Generate secret key
$secret = -join ((65..90) + (97..122) + (48..57) | Get-Random -Count 32 | ForEach-Object {[char]$_})

# Write settings.yaml (UTF-8 without BOM)
$sshKeyPath = if ($FoundKey) { $FoundKey -replace '\\', '\\' } else { "null" }
$settingsContent = @"
server:
  host: '$ServerHost'
  user: $ServerUser
  ssh_key: '$sshKeyPath'

dashboard:
  host: 127.0.0.1
  port: $DashboardPort
  debug: false
  secret_key: $secret

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

cache:
  chat_pod_ttl: 60
  chat_messages_ttl: 10
  static_data_ttl: 300

auth:
  enabled: true
  username: $AuthUser
  password: $AuthPass

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
$verifyResult = python -W ignore -c "from app.factory import create_app; app, sio = create_app(); print('OK -', len(app.url_map._rules), 'routes')" 2>$null
if ($verifyResult -match "OK") {
    Write-Host "  $verifyResult" -ForegroundColor Green
} else {
    Write-Host "  [WARN] Verification failed: $verifyResult" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  Setup Complete!" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""

# Check if SSH key is valid for the server
$SshValid = $false
if ($FoundKey -and (Test-Path $FoundKey) -and $ServerHost -ne "YOUR_SERVER_IP") {
    $testOut = ssh -i $FoundKey -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -o BatchMode=yes "${ServerUser}@${ServerHost}" "echo ok" 2>$null
    $SshValid = ($testOut -eq "ok")
}

if (-not $SshValid) {
    if ($ServerHost -eq "YOUR_SERVER_IP") {
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
    Write-Host ""
    Write-Host "  Start the dashboard with:" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "    .\start.ps1" -ForegroundColor Cyan
}

Write-Host ""
