#!/bin/bash
# Dune Awakening Dashboard - Setup (Linux/macOS)
# Run this ONCE per server. After that, use start.sh

set -e

PROJECT_ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$PROJECT_ROOT"

echo ""
echo "============================================================"
echo "  Dune Awakening Dashboard - Setup"
echo "============================================================"
echo ""

# Check if this is a re-run
IS_RERUN=false
if [ -f "$PROJECT_ROOT/settings.yaml" ] || [ -d "$PROJECT_ROOT/logs" ] || [ -d "$PROJECT_ROOT/instance" ]; then
    IS_RERUN=true
fi

if [ "$IS_RERUN" = true ]; then
    echo "  [WARNING] Existing dashboard data detected!"
    echo ""
    echo "  This will WIPE the following and start fresh:"
    echo "    - settings.yaml (configuration)"
    echo "    - logs/ (all log files)"
    echo "    - instance/ (SQLite database)"
    echo ""
    echo "  Are you sure you want to continue? (y/N)"
    read -r CONFIRMATION
    if [ "$CONFIRMATION" != "y" ] && [ "$CONFIRMATION" != "Y" ]; then
        echo ""
        echo "  Setup cancelled. No changes made."
        exit 0
    fi

    echo ""
    echo "  Cleaning existing data..."
    [ -f "$PROJECT_ROOT/settings.yaml" ] && rm -f "$PROJECT_ROOT/settings.yaml" && echo "    Removed settings.yaml"
    [ -d "$PROJECT_ROOT/logs" ] && rm -rf "$PROJECT_ROOT/logs" && echo "    Removed logs/"
    [ -d "$PROJECT_ROOT/instance" ] && rm -rf "$PROJECT_ROOT/instance" && echo "    Removed instance/"
    find "$PROJECT_ROOT" -type d -name "__pycache__" -exec rm -rf {} + 2>/dev/null && echo "    Removed __pycache__/"
    echo "  Clean complete!"
    echo ""
fi

# Determine Python command
PYTHON=""
if command -v python3 &>/dev/null; then
    PYTHON="python3"
elif command -v python &>/dev/null; then
    PYTHON="python"
else
    echo "[ERROR] Python not found. Install Python 3.8+ first."
    exit 1
fi

echo "[1/6] Checking Python..."
echo "  Found: $($PYTHON --version)"

# Install dependencies
echo ""
echo "[2/6] Installing dependencies..."
$PYTHON -m pip install -r "$PROJECT_ROOT/requirements.txt" --quiet 2>/dev/null && echo "  Dependencies installed" || echo "  [WARN] Some packages may have failed. Continuing..."

# Configure SSH key
echo ""
echo "[3/6] Configuring SSH key..."
TARGET_KEY="$PROJECT_ROOT/internal-scripts/ssh/sshKey"
SSH_KEY_PATHS=(
    "/tmp/dune-tunnel-key"
    "/tmp/dune-awakening-server-sshKey"
    "$TARGET_KEY"
    "$(dirname "$PROJECT_ROOT")/internal-scripts/ssh/sshKey"
)
FOUND_KEY=""
for path in "${SSH_KEY_PATHS[@]}"; do
    if [ -f "$path" ]; then
        FOUND_KEY="$path"
        break
    fi
done

fix_ssh_perms() {
    if [ -f "$1" ]; then
        chmod 600 "$1"
        if command -v chown &>/dev/null; then
            chown "$(whoami)" "$1" 2>/dev/null || true
        fi
    fi
}

if [ -z "$FOUND_KEY" ]; then
    echo "  [INFO] No SSH key found in standard locations."
    read -rp "  Enter path to your SSH key file (or press Enter to skip): " USER_KEY
    if [ -n "$USER_KEY" ] && [ -f "$USER_KEY" ]; then
        mkdir -p "$(dirname "$TARGET_KEY")"
        cp "$USER_KEY" "$TARGET_KEY"
        fix_ssh_perms "$TARGET_KEY"
        FOUND_KEY="$TARGET_KEY"
        echo "  Key copied to internal-scripts/ssh/sshKey"
    else
        echo "  Skipping SSH key configuration."
    fi
else
    if [[ "$FOUND_KEY" != *internal-scripts* ]]; then
        mkdir -p "$(dirname "$TARGET_KEY")"
        cp "$FOUND_KEY" "$TARGET_KEY"
        fix_ssh_perms "$TARGET_KEY"
        FOUND_KEY="$TARGET_KEY"
        echo "  Key copied to internal-scripts/ssh/sshKey for portability"
    else
        fix_ssh_perms "$FOUND_KEY"
        echo "  Found: $FOUND_KEY"
    fi
fi

# Auto-detect server settings
echo ""
echo "[4/6] Detecting server settings..."

SERVER_HOST="YOUR_SERVER_IP"
SERVER_USER="dune"
K8S_NAMESPACE=""
DASHBOARD_PORT="5050"
DB_PORT="15433"
DIRECTOR_PORT="32479"
FILEBROWSER_PORT="18888"
AUTH_USER="admin"
AUTH_PASS="changeme"

if [ -n "$FOUND_KEY" ] && [ "$SERVER_HOST" != "YOUR_SERVER_IP" ]; then
    if ssh -i "$FOUND_KEY" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -o BatchMode=yes "dune@$SERVER_HOST" "echo ok" &>/dev/null; then
        echo "  SSH connection OK"
        NS=$(ssh -i "$FOUND_KEY" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -o BatchMode=yes "dune@$SERVER_HOST" "sudo kubectl get namespaces -o name" 2>/dev/null | grep 'funcom-seabass-' | head -1 | sed 's|namespace/||')
        if [ -n "$NS" ]; then
            K8S_NAMESPACE="$NS"
            echo "  Namespace: $K8S_NAMESPACE"
        fi
    else
        echo "  [WARN] SSH failed. Using defaults."
    fi
fi

# Interactive review/edit
echo ""
echo "  Review settings (press Enter to accept, or type new value):"
echo ""

read -rp "  Server Host [$SERVER_HOST]: " VAL; [ -n "$VAL" ] && SERVER_HOST="$VAL"
read -rp "  Server User [$SERVER_USER]: " VAL; [ -n "$VAL" ] && SERVER_USER="$VAL"
read -rp "  SSH Key Path [$FOUND_KEY]: " VAL; [ -n "$VAL" ] && FOUND_KEY="$VAL"
read -rp "  K8s Namespace [$K8S_NAMESPACE]: " VAL; [ -n "$VAL" ] && K8S_NAMESPACE="$VAL"
read -rp "  Dashboard Port [$DASHBOARD_PORT]: " VAL; [ -n "$VAL" ] && DASHBOARD_PORT="$VAL"
read -rp "  DB Local Port [$DB_PORT]: " VAL; [ -n "$VAL" ] && DB_PORT="$VAL"
read -rp "  Director Port [$DIRECTOR_PORT]: " VAL; [ -n "$VAL" ] && DIRECTOR_PORT="$VAL"
read -rp "  FileBrowser Port [$FILEBROWSER_PORT]: " VAL; [ -n "$VAL" ] && FILEBROWSER_PORT="$VAL"
read -rp "  Auth Username [$AUTH_USER]: " VAL; [ -n "$VAL" ] && AUTH_USER="$VAL"
read -rp "  Auth Password [$AUTH_PASS]: " VAL; [ -n "$VAL" ] && AUTH_PASS="$VAL"

echo ""
echo "[5/6] Saving settings..."

# Generate secret key
SECRET=$($PYTHON -c "import secrets; print(secrets.token_hex(32))")

# Escape SSH key path for YAML
SSH_KEY_YAML="null"
if [ -n "$FOUND_KEY" ]; then
    SSH_KEY_YAML="'$FOUND_KEY'"
fi

cat > "$PROJECT_ROOT/settings.yaml" << EOF
server:
  host: '$SERVER_HOST'
  user: $SERVER_USER
  ssh_key: $SSH_KEY_YAML

dashboard:
  host: 127.0.0.1
  port: $DASHBOARD_PORT
  debug: false
  secret_key: $SECRET

database:
  host: 127.0.0.1
  port: $DB_PORT
  user: postgres
  password: postgres
  name: dune
  schema: dune
  min_connections: 2
  max_connections: 10

kubernetes:
  namespace: '$K8S_NAMESPACE'
  battlegroup_script: /home/dune/.dune/bin/battlegroup

director:
  port: $DIRECTOR_PORT

filebrowser:
  port: $FILEBROWSER_PORT

cache:
  chat_pod_ttl: 60
  chat_messages_ttl: 10
  static_data_ttl: 300

auth:
  enabled: true
  username: $AUTH_USER
  password: $AUTH_PASS

logging:
  level: INFO
  file: logs/dashboard.log
  max_bytes: 10485760
  backup_count: 5
EOF

echo "  Settings saved to settings.yaml"

# Create logs directory
mkdir -p "$PROJECT_ROOT/logs"

echo ""
echo "[6/6] Verifying setup..."
VERIFY=$($PYTHON -W ignore -c "from app.factory import create_app; app, sio = create_app(); print('OK -', len(app.url_map._rules), 'routes')" 2>/dev/null)
if [[ "$VERIFY" == OK* ]]; then
    echo "  $VERIFY"
else
    echo "  [WARN] Verification failed: $VERIFY"
fi

echo ""
echo "============================================================"
echo "  Setup Complete!"
echo "============================================================"
echo ""

# Check SSH validity
SSH_VALID=false
if [ -n "$FOUND_KEY" ] && [ -f "$FOUND_KEY" ] && [ "$SERVER_HOST" != "YOUR_SERVER_IP" ]; then
    if ssh -i "$FOUND_KEY" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -o BatchMode=yes "${SERVER_USER}@${SERVER_HOST}" "echo ok" &>/dev/null; then
        SSH_VALID=true
    fi
fi

if [ "$SSH_VALID" = false ]; then
    if [ "$SERVER_HOST" = "YOUR_SERVER_IP" ]; then
        echo "  Remember to edit settings.yaml with your server IP before starting."
    else
        echo "  SSH key is not configured or failed to connect."
    fi
    echo "  Edit settings.yaml and set ssh_key to your key path."
    echo ""
    echo "  Then start the dashboard with:"
    echo ""
    echo "    ./start.sh"
else
    echo "  SSH connection verified."
    echo ""
    echo "  Start the dashboard with:"
    echo ""
    echo "    ./start.sh"
fi

echo ""
