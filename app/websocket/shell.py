"""WebSocket shell handler - interactive terminal via SSH"""

import os
import sys
import time
import threading
import logging
import re
import shlex

try:
    import paramiko
    HAS_PARAMIKO = True
except ImportError:
    HAS_PARAMIKO = False

from flask import request, session
from flask_socketio import emit

logger = logging.getLogger(__name__)

shell_processes = {}

K8S_NAME_RE = re.compile(r"^[a-z0-9]([-a-z0-9]*[a-z0-9])?$")


def require_k8s_name(value, label):
    """Validate that a value is a valid Kubernetes resource name."""
    value = str(value or "").strip()
    if not value or not K8S_NAME_RE.fullmatch(value):
        raise ValueError(f"Invalid {label}")
    return value


def quote_remote(value):
    """Shell-quote a value for safe use in remote commands."""
    return shlex.quote(str(value))


def register_websocket_handlers(socketio, settings):
    if not HAS_PARAMIKO:
        logger.warning("Paramiko not installed. WebSocket shell disabled.")
        return

    @socketio.on('shell_create')
    def handle_shell_create(data):
        # Check if shell access is enabled
        shell_enabled = settings.get('auth', {}).get('shell_enabled', False)
        if not shell_enabled:
            logger.warning(f"WebSocket shell rejected: shell disabled (sid={request.sid})")
            return emit('shell_created', {'success': False, 'error': 'Shell access is disabled'})

        # Check if user is authenticated via Flask-Login session
        auth_enabled = settings.get('auth', {}).get('enabled', True)
        if auth_enabled:
            # Flask-Login stores user ID in session['_user_id']
            if not session.get('_user_id'):
                logger.warning(f"WebSocket shell rejected: unauthenticated (sid={request.sid})")
                return emit('shell_created', {'success': False, 'error': 'Authentication required'})

        shell_type = data.get('type', 'vm')
        shell_id = request.sid

        try:
            ssh_key = _find_ssh_key(settings)
            if not ssh_key:
                return emit('shell_created', {'success': False, 'error': 'SSH key not found'})

            client = paramiko.SSHClient()
            client.set_missing_host_key_policy(paramiko.WarningPolicy())

            server_host = settings['server']['host']
            server_user = settings['server']['user']

            if shell_type == 'vm':
                client.connect(server_host, username=server_user, key_filename=ssh_key, timeout=10)
                chan = client.invoke_shell(term='xterm-256color', width=80, height=24)
            else:
                namespace = settings['kubernetes']['namespace']
                pod = data.get('pod', '')
                try:
                    pod = require_k8s_name(pod, 'pod')
                except ValueError as e:
                    logger.warning(f"WebSocket shell rejected: invalid pod name (sid={request.sid})")
                    return emit('shell_created', {'success': False, 'error': str(e)})

                # Get valid pods and check if requested pod exists
                k8s_ns = settings['kubernetes']['namespace']
                check_cmd = f"sudo kubectl get pods -n {k8s_ns} -o custom-columns=NAME:.metadata.name --no-headers"
                out, _, rc = _run_ssh_check(server_host, server_user, ssh_key, check_cmd)
                if rc == 0:
                    valid_pods = [p.strip() for p in out.strip().split('\n') if p.strip()]
                    if pod not in valid_pods:
                        logger.warning(f"WebSocket shell rejected: unknown pod {pod} (sid={request.sid})")
                        return emit('shell_created', {'success': False, 'error': 'Unknown pod'})

                safe_pod = quote_remote(pod)
                safe_ns = quote_remote(namespace)
                client.connect(server_host, username=server_user, key_filename=ssh_key, timeout=10)
                transport = client.get_transport()
                chan = transport.open_session()
                chan.get_pty(term='xterm-256color', width=80, height=24)
                chan.exec_command(f'sudo kubectl exec -it {safe_pod} -n {safe_ns} -- /bin/bash')

            shell_processes[shell_id] = {'client': client, 'channel': chan, 'type': shell_type}

            def read_channel():
                time.sleep(0.5)
                socketio.emit('shell_output', {'data': '\r\nConnected. Press Enter...\r\n', 'type': 'stdout', 'target': shell_type}, room=shell_id)
                while shell_id in shell_processes:
                    try:
                        while chan.recv_ready():
                            data = chan.recv(65535).decode('utf-8', errors='replace')
                            if data:
                                socketio.emit('shell_output', {'data': data, 'type': 'stdout', 'target': shell_type}, room=shell_id)
                        while chan.recv_stderr_ready():
                            data = chan.recv_stderr(65535).decode('utf-8', errors='replace')
                            if data:
                                socketio.emit('shell_output', {'data': data, 'type': 'stderr', 'target': shell_type}, room=shell_id)
                        if chan.closed:
                            socketio.emit('shell_output', {'data': '\r\n[Disconnected]\r\n', 'type': 'stdout', 'target': shell_type}, room=shell_id)
                            break
                    except Exception as e:
                        logger.error(f"Shell read error: {e}")
                        break
                    time.sleep(0.1)

            threading.Thread(target=read_channel, daemon=True).start()
            socketio.emit('shell_created', {'success': True, 'shell_id': shell_id}, room=shell_id)
        except Exception as e:
            logger.error(f"Shell creation failed: {e}")
            socketio.emit('shell_created', {'success': False, 'error': str(e)}, room=shell_id)

    @socketio.on('shell_input')
    def handle_shell_input(data):
        shell_id = request.sid
        if shell_id in shell_processes:
            try:
                chan = shell_processes[shell_id]['channel']
                if chan and chan.send_ready():
                    chan.send(data.get('data', ''))
            except Exception as e:
                logger.error(f"Shell input error: {e}")

    @socketio.on('shell_disconnect')
    def handle_shell_disconnect():
        shell_id = request.sid
        if shell_id in shell_processes:
            try:
                if 'client' in shell_processes[shell_id]:
                    shell_processes[shell_id]['client'].close()
            except Exception as e:
                logger.error(f"Shell disconnect error: {e}")
            del shell_processes[shell_id]


def _find_ssh_key(settings):
    key = settings['server'].get('ssh_key')
    if key and os.path.exists(key):
        return key

    base_dir = os.path.dirname(os.path.dirname(os.path.dirname(__file__)))
    temp_dir = os.environ.get('TEMP') or os.environ.get('TMPDIR') or ('/tmp' if os.name != 'nt' else 'C:\\Temp')
    local_appdata = os.environ.get('LOCALAPPDATA', '')
    potential_paths = [
        os.path.join(temp_dir, 'dune-tunnel-key'),
        os.path.join(temp_dir, 'dune-awakening-server-sshKey'),
        os.path.join(base_dir, 'internal-scripts', 'ssh', 'sshKey'),
        os.path.join(os.path.dirname(base_dir), 'internal-scripts', 'ssh', 'sshKey'),
    ]
    if local_appdata:
        potential_paths.insert(2, os.path.join(local_appdata, 'DuneAwakeningServer', 'sshKey'))
    for p in potential_paths:
        if os.path.exists(p):
            return p
    return None


def _run_ssh_check(host, user, key, command, timeout=10):
    """Run an SSH command and return output."""
    import subprocess
    try:
        result = subprocess.run(
            ['ssh', '-o', 'StrictHostKeyChecking=no', '-o', 'LogLevel=QUIET',
             '-i', key, f'{user}@{host}', command],
            capture_output=True, text=True, timeout=timeout
        )
        return result.stdout, result.stderr, result.returncode
    except Exception as e:
        return '', str(e), 1
