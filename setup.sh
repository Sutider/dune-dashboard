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
if [ -f "$PROJECT_ROOT/settings.yaml" ] || [ -d "$PROJECT_ROOT/logs" ] || [ -d "$PROJECT_ROOT/instance" ] || [ -d "$PROJECT_ROOT/ssl" ]; then
    IS_RERUN=true
fi

if [ "$IS_RERUN" = true ]; then
    echo "  [WARNING] Existing dashboard data detected!"
    echo ""
    echo "  This will WIPE the following and start fresh:"
    echo "    - settings.yaml (configuration)"
    echo "    - logs/ (all log files)"
    echo "    - instance/ (SQLite database)"
    echo "    - ssl/ (SSL certificates and CA)"
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
    [ -d "$PROJECT_ROOT/ssl" ] && rm -rf "$PROJECT_ROOT/ssl" && echo "    Removed ssl/"
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

VM_HOST="YOUR_SERVER_IP"
HOST_IP=""
SERVER_USER="dune"
K8S_NAMESPACE=""
DASHBOARD_PORT="5050"
DB_PORT="15433"
DIRECTOR_PORT="32479"
FILEBROWSER_PORT="18888"
AUTH_USER="admin"
AUTH_PASS="changeme"

# Try to detect VM IP from known_hosts
KNOWN_HOSTS="$HOME/.ssh/known_hosts"
if [ -f "$KNOWN_HOSTS" ]; then
    DETECTED_IP=$(grep -oE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' "$KNOWN_HOSTS" | tail -1)
    if [ -n "$DETECTED_IP" ]; then
        VM_HOST="$DETECTED_IP"
        echo "  Detected VM IP from SSH history: $VM_HOST"
    fi
fi

# Auto-detect local IP
HOST_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
if [ -z "$HOST_IP" ]; then
    HOST_IP=$(ip route get 1 2>/dev/null | awk '{print $7; exit}')
fi

# Ask for VM IP (SSH)
echo ""
echo "  VM External IP - used for SSH connection to your game server"
read -rp "  VM Host [$VM_HOST]: " VAL; [ -n "$VAL" ] && VM_HOST="$VAL"

# Ask for Host IP
echo ""
echo "  This Machine's External IP - used for SSL certificate so remote access works"
HOST_IP_HINT="${HOST_IP:-Your machine's external IP}"
read -rp "  Host IP [$HOST_IP_HINT]: " VAL
if [ -n "$VAL" ]; then HOST_IP="$VAL"; elif [ -z "$HOST_IP" ]; then HOST_IP=""; fi

# Ask for domain name (Let's Encrypt)
echo ""
echo "  Domain Name (optional) - for a publicly trusted SSL certificate via Let's Encrypt."
echo "  This removes browser warnings for ALL visitors. Requires:"
echo "    - A domain (or subdomain) pointing to this machine's external IP"
echo "    - Port 80 accessible from the internet"
read -rp "  Domain (leave blank to use local CA instead): " DOMAIN_NAME
LE_EMAIL=""
if [ -n "$DOMAIN_NAME" ]; then
    echo ""
    echo "  Email address is required by Let's Encrypt for expiry notifications."
    read -rp "  Email Address: " VAL
    [ -n "$VAL" ] && LE_EMAIL="$VAL"
fi

# Test SSH with confirmed VM IP
if [ -n "$FOUND_KEY" ] && [ "$VM_HOST" != "YOUR_SERVER_IP" ]; then
    if ssh -i "$FOUND_KEY" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -o BatchMode=yes "dune@$VM_HOST" "echo ok" &>/dev/null; then
        echo "  SSH connection OK"
        NS=$(ssh -i "$FOUND_KEY" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -o BatchMode=yes "dune@$VM_HOST" "sudo kubectl get namespaces -o name" 2>/dev/null | grep 'funcom-seabass-' | head -1 | sed 's|namespace/||')
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

echo "  VM Host: $VM_HOST (IP of your game server VM, used for SSH)"
[ -n "$HOST_IP" ] && echo "  Host IP: $HOST_IP (This machine's external IP, used for SSL cert)"

read -rp "  Server User [$SERVER_USER] (SSH username for the VM): " VAL; [ -n "$VAL" ] && SERVER_USER="$VAL"
read -rp "  SSH Key Path [$FOUND_KEY] (Path to your private SSH key): " VAL; [ -n "$VAL" ] && FOUND_KEY="$VAL"

if [ -z "$K8S_NAMESPACE" ]; then
    echo "  [INFO] To find your namespace, run: ssh dune@YOUR_IP 'sudo kubectl get namespaces'"
    K8S_HINT="funcom-seabass-<id> (Kubernetes cluster namespace)"
else
    K8S_HINT="$K8S_NAMESPACE (Kubernetes cluster namespace)"
fi

read -rp "  K8s Namespace [$K8S_HINT]: " VAL; [ -n "$VAL" ] && K8S_NAMESPACE="$VAL"
read -rp "  Dashboard Port [$DASHBOARD_PORT] (Local web access port): " VAL; [ -n "$VAL" ] && DASHBOARD_PORT="$VAL"
read -rp "  DB Local Port [$DB_PORT] (Local database tunnel port): " VAL; [ -n "$VAL" ] && DB_PORT="$VAL"
read -rp "  Director Port [$DIRECTOR_PORT] (Director API port): " VAL; [ -n "$VAL" ] && DIRECTOR_PORT="$VAL"
read -rp "  FileBrowser Port [$FILEBROWSER_PORT] (File manager port): " VAL; [ -n "$VAL" ] && FILEBROWSER_PORT="$VAL"
read -rp "  Auth Username [$AUTH_USER] (Dashboard login name): " VAL; [ -n "$VAL" ] && AUTH_USER="$VAL"
read -rp "  Auth Password [$AUTH_PASS] (Dashboard login password): " VAL; [ -n "$VAL" ] && AUTH_PASS="$VAL"

# SSL certificate (Let's Encrypt or local CA)
echo ""
echo "  Configuring SSL certificate..."
CERT_DIR="$PROJECT_ROOT/ssl"
mkdir -p "$CERT_DIR"
CA_CERT_PATH="$CERT_DIR/ca.pem"
CA_KEY_PATH="$CERT_DIR/ca-key.pem"
SSL_CERT_PATH="$CERT_DIR/cert.pem"
SSL_KEY_PATH="$CERT_DIR/key.pem"

USE_LETSENCRYPT=false
LE_CERT_PATH=""
LE_KEY_PATH=""

if [ -n "$DOMAIN_NAME" ]; then
    echo "  Attempting Let's Encrypt certificate for $DOMAIN_NAME..."

    # Check for certbot
    if ! command -v certbot &>/dev/null; then
        echo "  Installing certbot..."
        if command -v apt-get &>/dev/null; then
            sudo apt-get update -qq && sudo apt-get install -y -qq certbot 2>/dev/null
        elif command -v yum &>/dev/null; then
            sudo yum install -y certbot 2>/dev/null
        elif command -v dnf &>/dev/null; then
            sudo dnf install -y certbot 2>/dev/null
        fi
    fi

    if command -v certbot &>/dev/null; then
        # Run certbot standalone
        CERTBOT_ARGS="certonly --standalone -d $DOMAIN_NAME --non-interactive --agree-tos"
        [ -n "$LE_EMAIL" ] && CERTBOT_ARGS="$CERTBOT_ARGS --email $LE_EMAIL" || CERTBOT_ARGS="$CERTBOT_ARGS --register-unsafely-without-email"

        if sudo certbot $CERTBOT_ARGS 2>/tmp/certbot-out.txt; then
            USE_LETSENCRYPT=true
            LE_CERT_PATH="/etc/letsencrypt/live/$DOMAIN_NAME/fullchain.pem"
            LE_KEY_PATH="/etc/letsencrypt/live/$DOMAIN_NAME/privkey.pem"

            if [ -f "$LE_CERT_PATH" ]; then
                echo "  Let's Encrypt certificate obtained successfully!"
                echo "  Certificate for $DOMAIN_NAME is publicly trusted."
            else
                echo "  [WARN] Let's Encrypt succeeded but cert files not found."
                echo "  Falling back to local CA."
                USE_LETSENCRYPT=false
            fi
        else
            echo "  [WARN] Let's Encrypt certificate failed."
            cat /tmp/certbot-out.txt 2>/dev/null | head -5
            echo "  Falling back to local CA certificate."
        fi
    else
        echo "  [WARN] certbot not available. Falling back to local CA certificate."
    fi
fi

if [ "$USE_LETSENCRYPT" = false ]; then
    # Generate CA if it doesn't exist
    if [ ! -f "$CA_CERT_PATH" ] || [ ! -f "$CA_KEY_PATH" ]; then
        echo "  Generating local CA..."
        $PYTHON -c "from app.utils.ssl import generate_ca; generate_ca('$CA_CERT_PATH', '$CA_KEY_PATH')"
    fi

    # Build SAN IPs
    SAN_IPS="['127.0.0.1'"
    [ "$VM_HOST" != "YOUR_SERVER_IP" ] && SAN_IPS="$SAN_IPS, '$VM_HOST'"
    if [ -n "$HOST_IP" ]; then
        # Check if HOST_IP already in SAN_IPS
        if [[ "$SAN_IPS" != *"$HOST_IP"* ]]; then
            SAN_IPS="$SAN_IPS, '$HOST_IP'"
        fi
    fi
    SAN_IPS="$SAN_IPS]"

    # Generate server cert signed by CA
    if [ "$VM_HOST" != "YOUR_SERVER_IP" ]; then
        COMMON_NAME="$VM_HOST"
    else
        COMMON_NAME="localhost"
    fi
    $PYTHON -c "from app.utils.ssl import generate_cert; generate_cert('$SSL_CERT_PATH', '$SSL_KEY_PATH', ca_cert_path='$CA_CERT_PATH', ca_key_path='$CA_KEY_PATH', common_name='$COMMON_NAME', san_ips=$SAN_IPS, san_dns=['localhost'])"
    SSL_CERT="'$SSL_CERT_PATH'"
    SSL_KEY="'$SSL_KEY_PATH'"

    # Offer to install CA cert into system trust store
    echo ""
    echo "  A local CA certificate was generated (Let's Encrypt was not used)."
    echo "  Installing it into the system trust store will remove browser warnings on THIS machine only."
    echo "  Visitors from other machines will still see a warning unless they also install the CA cert."
    echo "  To get a publicly trusted certificate, re-run setup and provide a domain name."
    echo ""
    read -rp "  Install CA certificate now? Requires sudo (y/N): " INSTALL_CA
    if [[ "$INSTALL_CA" == "y" || "$INSTALL_CA" == "Y" ]]; then
        if command -v update-ca-certificates &>/dev/null; then
            sudo cp "$CA_CERT_PATH" /usr/local/share/ca-certificates/dune-dashboard-ca.crt
            sudo update-ca-certificates
            echo "  CA certificate installed (Debian/Ubuntu)."
        elif command -v update-ca-trust &>/dev/null; then
            sudo cp "$CA_CERT_PATH" /etc/pki/ca-trust/source/anchors/dune-dashboard-ca.pem
            sudo update-ca-trust
            echo "  CA certificate installed (RHEL/CentOS/Fedora)."
        else
            echo "  [WARN] No supported CA update tool found."
            echo "  Manually trust '$CA_CERT_PATH' in your browser."
        fi
    else
        echo "  Skipped. Install later with:"
        echo "    sudo cp '$CA_CERT_PATH' /usr/local/share/ca-certificates/dune-dashboard-ca.crt"
        echo "    sudo update-ca-certificates"
    fi
else
    SSL_CERT="'$LE_CERT_PATH'"
    SSL_KEY="'$LE_KEY_PATH'"
fi

# Remote access
echo ""
read -rp "  Enable remote access? (y/N): " REMOTE_ANSWER
ENABLE_REMOTE=false

if [[ "$REMOTE_ANSWER" == "y" || "$REMOTE_ANSWER" == "Y" ]]; then
    DASH_HOST="0.0.0.0"
    echo "  Remote access enabled with HTTPS"
else
    DASH_HOST="127.0.0.1"
fi

# Let's Encrypt auto-renewal via cron
if [ "$USE_LETSENCRYPT" = true ]; then
    echo ""
    echo "  Setting up Let's Encrypt auto-renewal..."
    if crontab -l 2>/dev/null | grep -q "certbot.*renew.*$DOMAIN_NAME"; then
        echo "  Renewal cron job already exists."
    else
        (crontab -l 2>/dev/null; echo "0 2 * * * certbot renew --quiet --deploy-hook 'systemctl restart dune-dashboard'") | crontab -
        echo "  Auto-renewal scheduled (daily at 2 AM). Certificates renew automatically."
    fi
fi

echo ""
echo "[5/6] Saving settings..."

# Generate secret key
SECRET=$($PYTHON -c "import secrets; print(secrets.token_hex(32))")

# Escape SSH key path for YAML
SSH_KEY_YAML="null"
if [ -n "$FOUND_KEY" ]; then
    SSH_KEY_YAML="'$FOUND_KEY'"
fi

LE_DOMAIN_YAML="null"
[ -n "$DOMAIN_NAME" ] && LE_DOMAIN_YAML="'$DOMAIN_NAME'"
LE_EMAIL_YAML="null"
[ -n "$LE_EMAIL" ] && LE_EMAIL_YAML="'$LE_EMAIL'"

cat > "$PROJECT_ROOT/settings.yaml" << EOF
server:
  host: '$VM_HOST'
  user: $SERVER_USER
  ssh_key: $SSH_KEY_YAML

dashboard:
  host: $DASH_HOST
  port: $DASHBOARD_PORT
  debug: false
  secret_key: $SECRET
  ssl_cert: $SSL_CERT
  ssl_key: $SSL_KEY
  ssl_domain: $LE_DOMAIN_YAML
  ssl_email: $LE_EMAIL_YAML

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
if [ -n "$FOUND_KEY" ] && [ -f "$FOUND_KEY" ] && [ "$VM_HOST" != "YOUR_SERVER_IP" ]; then
    if ssh -i "$FOUND_KEY" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -o BatchMode=yes "${SERVER_USER}@${VM_HOST}" "echo ok" &>/dev/null; then
        SSH_VALID=true
    fi
fi

if [ "$SSH_VALID" = false ]; then
    if [ "$VM_HOST" = "YOUR_SERVER_IP" ]; then
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
