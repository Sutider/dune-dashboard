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
