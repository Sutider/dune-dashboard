"""Update service - checks GitHub for new releases and applies updates"""

import os
import sys
import json
import time
import shutil
import logging
import threading
import urllib.request
import zipfile
import tempfile
import subprocess
from datetime import datetime, timezone

logger = logging.getLogger(__name__)

GITHUB_REPO = "Sutider/dune-dashboard"
GITHUB_API = f"https://api.github.com/repos/{GITHUB_REPO}"

# Paths that should NEVER be overwritten during update
PROTECTED_PATHS = {
    'settings.yaml',
    'logs',
    'instance',
    'internal-scripts',
    '.git',
    '.env',
}

# File extensions that are always safe to overwrite
SAFE_EXTENSIONS = {'.py', '.html', '.css', '.js', '.sh', '.ps1', '.md', '.txt', '.yaml', '.yml', '.json', '.ini', '.cfg'}


class UpdateService:
    def __init__(self, project_root):
        self.project_root = project_root
        self._update_available = False
        self._latest_sha = None
        self._current_sha = None
        self._last_check = 0
        self._check_interval = 1800  # 30 minutes
        self._update_in_progress = False
        self._update_status = None
        self._current_branch = self._detect_branch()

    def _detect_branch(self):
        """Detect the current git branch or ZIP branch from folder name."""
        try:
            branch = subprocess.check_output(
                ['git', 'rev-parse', '--abbrev-ref', 'HEAD'],
                cwd=self.project_root, stderr=subprocess.DEVNULL
            ).decode().strip()
            if branch:
                return branch
        except Exception:
            pass

        folder_name = os.path.basename(self.project_root).lower()
        if 'nightly' in folder_name:
            return 'nightly'
        if 'beta' in folder_name:
            return 'beta'
        return 'main'
        except Exception:
            return 'main'

    def start_checker(self):
        """Start background update checker thread."""
        thread = threading.Thread(target=self._checker_loop, daemon=True)
        thread.start()
        logger.info("Update checker started")

    def _checker_loop(self):
        """Periodically check for updates."""
        while True:
            try:
                self.check_for_updates()
            except Exception as e:
                logger.debug(f"Update check failed: {e}")
            time.sleep(self._check_interval)

    def check_for_updates(self):
        """Check GitHub for new commits."""
        try:
            branch = self._current_branch
            git_dir = os.path.join(self.project_root, '.git')
            if os.path.isdir(git_dir):
                # Git clone: compare local HEAD to origin/<branch>
                subprocess.run(
                    ['git', 'fetch', 'origin', branch, '--quiet'],
                    cwd=self.project_root, stderr=subprocess.DEVNULL, timeout=15
                )
                local_sha = subprocess.check_output(
                    ['git', 'rev-parse', 'HEAD'],
                    cwd=self.project_root, stderr=subprocess.DEVNULL
                ).decode().strip()[:7]
                remote_sha = subprocess.check_output(
                    ['git', 'rev-parse', f'origin/{branch}'],
                    cwd=self.project_root, stderr=subprocess.DEVNULL
                ).decode().strip()[:7]
            else:
                # ZIP download: compare VERSION file to GitHub API
                req = urllib.request.Request(f"{GITHUB_API}/commits/{branch}")
                req.add_header('Accept', 'application/vnd.github.v3+json')
                req.add_header('User-Agent', 'DuneDashboard-UpdateChecker')
                with urllib.request.urlopen(req, timeout=10) as resp:
                    data = json.loads(resp.read().decode())
                    remote_sha = data['sha'][:7]

                version_file = os.path.join(self.project_root, 'VERSION')
                if os.path.exists(version_file):
                    with open(version_file) as f:
                        local_sha = f.read().strip().replace('\r', '').replace('\n', '')[:7]
                else:
                    local_sha = "unknown"

            self._latest_sha = remote_sha
            self._current_sha = local_sha
            self._update_available = remote_sha != local_sha and remote_sha != ""
            self._last_check = time.time()
            logger.info(f"Update check ({branch}): {'available' if self._update_available else 'up to date'} (local={local_sha}, remote={remote_sha})")
        except Exception as e:
            logger.debug(f"Update check error: {e}")

    @property
    def update_available(self):
        return self._update_available

    @property
    def update_status(self):
        return self._update_status

    def apply_update(self):
        """Download and apply the latest update."""
        if self._update_in_progress:
            return False, "Update already in progress"

        self._update_in_progress = True
        self._update_status = "Downloading update..."

        try:
            # Download latest zip
            zip_url = f"https://github.com/{GITHUB_REPO}/archive/refs/heads/main.zip"
            req = urllib.request.Request(zip_url)
            req.add_header('User-Agent', 'DuneDashboard-UpdateChecker')
            with urllib.request.urlopen(req, timeout=60) as resp:
                zip_data = resp.read()

            self._update_status = "Extracting update..."

            # Extract to temp directory
            temp_dir = tempfile.mkdtemp(prefix='dune_update_')
            zip_path = os.path.join(temp_dir, 'update.zip')
            with open(zip_path, 'wb') as f:
                f.write(zip_data)

            with zipfile.ZipFile(zip_path, 'r') as zf:
                zf.extractall(temp_dir)

            # Find the extracted folder (e.g., dune-dashboard-main)
            extracted = [d for d in os.listdir(temp_dir) if os.path.isdir(os.path.join(temp_dir, d)) and d != '__MACOSX']
            if not extracted:
                return False, "Failed to extract update"

            source_dir = os.path.join(temp_dir, extracted[0])

            # Create backup
            backup_dir = os.path.join(self.project_root, 'backups', f'update_{datetime.now().strftime("%Y%m%d_%H%M%S")}')
            os.makedirs(backup_dir, exist_ok=True)

            # Copy files, skipping protected paths
            self._update_status = "Applying files..."
            files_updated = 0
            for root, dirs, files in os.walk(source_dir):
                rel_root = os.path.relpath(root, source_dir)
                target_root = os.path.join(self.project_root, rel_root)

                # Skip protected directories
                if any(p in PROTECTED_PATHS for p in rel_root.split(os.sep)):
                    continue

                os.makedirs(target_root, exist_ok=True)

                for file in files:
                    if file.startswith('.'):
                        continue
                    src_file = os.path.join(root, file)
                    dst_file = os.path.join(target_root, file)

                    # Skip protected files
                    if file in PROTECTED_PATHS:
                        continue

                    # Backup existing file if it exists
                    if os.path.exists(dst_file):
                        backup_file = os.path.join(backup_dir, rel_root, file)
                        os.makedirs(os.path.dirname(backup_file), exist_ok=True)
                        shutil.copy2(dst_file, backup_file)

                    shutil.copy2(src_file, dst_file)
                    files_updated += 1

            # Cleanup temp
            shutil.rmtree(temp_dir, ignore_errors=True)

            # Update VERSION file to match new version
            version_file = os.path.join(self.project_root, 'VERSION')
            with open(version_file, 'w') as f:
                f.write(self._latest_sha + '\n')

            self._update_status = f"Update applied! {files_updated} files updated. Restarting..."
            self._update_available = False

            # Restart the application
            self._restart_app()

            return True, f"Update applied successfully ({files_updated} files)"

        except Exception as e:
            logger.error(f"Update failed: {e}")
            self._update_status = f"Update failed: {e}"
            self._update_in_progress = False
            return False, str(e)

    def _restart_app(self):
        """Restart the dashboard via the launcher script to preserve SSH/DB tunnels."""
        try:
            if os.name == 'nt':
                launcher = os.path.join(self.project_root, 'start.bat')
                if os.path.exists(launcher):
                    subprocess.Popen(['cmd', '/c', 'start', '', launcher], shell=True)
                else:
                    subprocess.Popen([sys.executable, os.path.join(self.project_root, 'run.py')], creationflags=subprocess.CREATE_NEW_CONSOLE)
            else:
                launcher = os.path.join(self.project_root, 'start.sh')
                if os.path.exists(launcher):
                    subprocess.Popen(['bash', launcher], start_new_session=True)
                else:
                    subprocess.Popen([sys.executable, os.path.join(self.project_root, 'run.py')], start_new_session=True)
            os._exit(0)
        except Exception as e:
            logger.error(f"Restart failed: {e}")
