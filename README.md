# Dune Awakening Dashboard

A comprehensive web-based management dashboard for Dune: Awakening private servers. Provides real-time monitoring, player management, chat logging, file browsing, and server administration tools.

> **Beta Release** — Feature complete for core functionality. Report issues on GitHub.

## Quick Start

### Windows
1. Double-click `setup.bat`
2. Follow the prompts
3. Double-click `start.bat` to launch

> **Tip**: Ensure your SSH key is in `internal-scripts/ssh/sshKey` before running setup.

## Features

- **Real-time Overview**: Server metrics, player counts, pod status, and resource usage.
- **Player Management**: View, search, and filter players. Track online status, factions, guilds, and locations.
- **Chat Logs**: Parsed from text-router pod logs with channel filtering and auto-refresh.
- **Director Controls**: Live battlegroup stats, world state management, and server transfer controls.
- **File Browser**: Secure SSH-based file browser for server configuration and logs.
- **Shell Access**: Interactive VM and Kubernetes pod shells directly in the browser.
- **Admin Tools**: Ban management, IP detection, kick/unban functionality, and player history.
- **Vehicles & Buildings**: Track owned vehicles, modules, and player structures.
- **Auto-Update**: Background checker polls GitHub for new commits. Safe file replacement preserves your settings, logs, and SSH keys. One-click update from the dashboard.
- **Remote Access**: Built-in support for HTTPS and binding to `0.0.0.0` for secure remote management.
- **Let's Encrypt**: Optionally set up publicly trusted SSL certs during setup with automatic renewal via certbot.
- **Firewall Management**: Setup and launcher scripts automatically create/check firewall rules for required ports.
- **Settings Migration**: Automatically adds new configuration options to `settings.yaml` when updating, so you never miss a feature.
- **Cross-Platform**: Works on Windows (`.bat`/`.ps1`) and Linux/macOS (`.sh`).

## License

This project is **Source Available** under the [Dune Dashboard Source License (DDSL)](LICENSE).
- Source code is available for inspection and security auditing.
- **No redistribution** (modified or unmodified).
- **No claiming of credit** or authorship.
- Personal, non-commercial use only.

## Requirements

- Python 3.8+
- OpenSSH client
- `kubectl` access to the Dune: Awakening Kubernetes cluster
- SSH access to the game server VM

## Setup

### Windows

1. **Run Setup**
   ```powershell
   .\setup.ps1
   ```
   This will install dependencies, configure your SSH key, and generate `settings.yaml`.

   During setup you'll be prompted for:
   - **VM External IP** — the IP you SSH into (e.g., `65.21.198.100`)
   - **Host External IP** — the public IP for SSL certificate SANs (e.g., `65.21.198.107`)
   - **Let's Encrypt** — optionally set up a publicly trusted SSL cert with auto-renewal via certbot
   - **Firewall rules** — only prompted if no `DuneDashboard` rule exists yet

2. **Start Dashboard**
   ```powershell
   .\start.ps1
   ```
   This starts the SSH tunnel, database port-forward, and launches the dashboard.

### Linux / macOS

1. **Run Setup**
   ```bash
   chmod +x setup.sh start.sh
   ./setup.sh
   ```

2. **Start Dashboard**
   ```bash
   ./start.sh
   ```

## Configuration

All settings are stored in `settings.yaml`. The setup script generates this automatically. Key settings include:

- `server.host`: Game server VM IP
- `server.ssh_key`: Path to your SSH private key
- `kubernetes.namespace`: Auto-detected K8s namespace
- `database.port`: Local port for database tunnel
- `auth.username` / `auth.password`: Dashboard login credentials

### Remote Access

During setup, answer **y** to "Enable remote access?" to:
- Bind to `0.0.0.0` (accessible from other machines)
- Auto-generate SSL certificates for HTTPS
- Enable secure remote connections via `https://YOUR_IP:5050`

**Firewall rules** are created automatically during setup. On subsequent starts, `start.ps1`/`start.sh` will only prompt if the `DuneDashboard` rule is missing.

You can also manually edit `settings.yaml` later:
```yaml
dashboard:
  host: 0.0.0.0
  ssl_cert: ssl/cert.pem
  ssl_key: ssl/key.pem
```

### Let's Encrypt (Publicly Trusted Certs)

During setup, answer **y** when asked to enable Let's Encrypt. The setup script will:
1. Install `certbot` (tries `winget`, `pip`, and `python -m` fallbacks on Windows)
2. Run `certbot certonly --standalone` to validate your domain
3. Configure auto-renewal via Windows Scheduled Task or Linux cron
4. Point the dashboard to the Let's Encrypt cert paths

> **Note**: Port 80 must be free during certbot validation. The dashboard's HTTP redirect server will release port 80 temporarily for this.

### Local CA Utilities (Windows)

Two helper scripts are included for managing the self-signed CA:
- **`install-ca-cert.bat`** — Installs the local CA (`ssl/ca.pem`) into Windows Trusted Root store. Run as Administrator. Removes browser warnings.
- **`clean-ca-certs.bat`** — Removes the dashboard CA from Windows Trusted Root store. Run as Administrator.

### SSL Configuration

The dashboard supports both self-signed and CA-signed certificates.

**Local CA (auto-generated during setup):**
- A local Certificate Authority (`ssl/ca.pem`) is created during setup
- Server certificates are signed by this CA
- Server certs include SAN for the server IP + `127.0.0.1` + `localhost`
- Valid for 365 days

**Remove browser warnings (Windows):**
1. Run `install-ca-cert.bat` as Administrator
2. Restart your browser
3. Access `https://localhost:5050` — no more warnings

**Remove browser warnings (Linux):**
```bash
sudo cp ssl/ca.pem /usr/local/share/ca-certificates/dune-dashboard-ca.crt
sudo update-ca-certificates
```

**Let's Encrypt or custom CA:**
```yaml
dashboard:
  host: 0.0.0.0
  ssl_cert: /etc/letsencrypt/live/yourdomain.com/fullchain.pem
  ssl_key: /etc/letsencrypt/live/yourdomain.com/privkey.pem
```

When SSL is enabled:
- Session cookies are marked `Secure` (sent only over HTTPS)
- HTTP-to-HTTPS redirect runs on port+1 (e.g., `http://localhost:5051` → `https://localhost:5050`)
- Certificate expiry is checked at startup (warning if < 30 days)

**Regenerate certificates:**
Delete `ssl/cert.pem`, `ssl/key.pem`, and `ssl/ca*.pem`, then re-run setup.

### Auto-Renewal

SSL certificates are automatically regenerated when they approach expiry:
- A background thread checks the certificate every 24 hours (configurable)
- If the certificate expires within 30 days (configurable), a new one is generated
- The server does **not** need to restart — Flask-SocketIO picks up the new cert on the next connection
- Configure thresholds in `settings.yaml` under the `ssl:` section

## Project Structure

```
DuneDashboard/
├── app/                 # Core application package
│   ├── routes/          # HTTP route handlers
│   ├── services/        # Business logic (DB, SSH, K8s, etc.)
│   ├── utils/           # Helpers and constants
│   └── websocket/       # Socket.IO handlers
├── templates/           # Jinja2 HTML templates
├── static/              # CSS and frontend assets
├── setup.ps1 / setup.sh # One-time setup scripts
├── start.ps1 / start.sh # Dashboard launchers
└── settings.yaml        # Configuration (gitignored)
```

## Security Notes

- Never commit `settings.yaml` to version control.
- SSH keys are copied to `%TEMP%` with restricted permissions during startup.
- All database queries use parameterized statements to prevent SQL injection.
- Dashboard authentication is required by default.
