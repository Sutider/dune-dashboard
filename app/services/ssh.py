"""SSH service - remote command execution via paramiko."""

import logging
import threading
import paramiko

from app.utils.ssh_key import resolve_ssh_key

logger = logging.getLogger(__name__)


class SSHService:
    """SSH service using paramiko for connection reuse.

    Replaces the previous subprocess-based implementation.
    Benefits:
    - Connection reuse (no SSH handshake per command)
    - Better error handling
    - No dependency on system ssh binary
    - Thread-safe via lock
    """

    def __init__(self, host, user, ssh_key=None):
        self.host = host
        self.user = user
        self.ssh_key = resolve_ssh_key(ssh_key)
        self._client = None
        self._lock = threading.Lock()
        key_status = self.ssh_key if self.ssh_key else 'default ssh identity/agent'
        logger.info("SSHService initialized: %s@%s using %s", user, host, key_status)

    def _get_client(self):
        """Get or create a paramiko SSH client. Thread-safe."""
        with self._lock:
            if self._client is not None:
                transport = self._client.get_transport()
                if transport and transport.is_active():
                    return self._client
                self._client = None

            client = paramiko.SSHClient()
            client.set_missing_host_key_policy(paramiko.WarningPolicy())

            connect_kwargs = {
                'hostname': self.host,
                'username': self.user,
                'timeout': 15,
                'allow_agent': True,
                'look_for_keys': True,
            }
            if self.ssh_key:
                connect_kwargs['key_filename'] = self.ssh_key

            try:
                client.connect(**connect_kwargs)
                logger.debug("SSH connection established to %s@%s", self.user, self.host)
            except paramiko.AuthenticationException:
                logger.error("SSH authentication failed for %s@%s", self.user, self.host)
                raise
            except paramiko.SSHException as e:
                logger.error("SSH connection error: %s", e)
                raise
            except Exception as e:
                logger.error("Unexpected SSH error: %s", e)
                raise

            self._client = client
            return self._client

    def run(self, command, timeout=30):
        """Execute a remote command via SSH.

        Args:
            command: The shell command to execute.
            timeout: Maximum time in seconds to wait for the command.

        Returns:
            Tuple of (stdout, stderr, return_code).
        """
        logger.debug("SSH command: %s...", command[:100] if len(command) > 100 else command)
        try:
            client = self._get_client()
            stdin, stdout, stderr = client.exec_command(command, timeout=timeout)
            out = stdout.read().decode('utf-8', errors='replace')
            err = stderr.read().decode('utf-8', errors='replace')
            rc = stdout.channel.recv_exit_status()
            if rc != 0:
                cmd_short = command[:80] + '...' if len(command) > 80 else command
                logger.warning("SSH command failed (rc=%d): cmd=%s err=%s", rc, cmd_short, err[:100] if err else 'none')
            return out, err, rc
        except paramiko.SSHException as e:
            logger.error("SSH command error: %s", e)
            self._client = None
            return '', str(e), -1
        except Exception as ex:
            logger.error("Unexpected SSH command error: %s", ex)
            self._client = None
            return '', str(ex), -1

    def check_connection(self):
        """Test SSH connectivity with a simple echo command.

        Returns:
            True if the connection works, False otherwise.
        """
        try:
            out, err, rc = self.run('echo ok', timeout=10)
            if rc == 0 and 'ok' in out:
                logger.debug("SSH connection check passed")
                return True
            logger.warning("SSH connection check failed: rc=%d, out=%s", rc, out[:50])
            return False
        except Exception:
            logger.warning("SSH connection check failed with exception")
            return False

    def close(self):
        """Close the SSH connection. Safe to call multiple times."""
        with self._lock:
            if self._client:
                try:
                    self._client.close()
                    logger.debug("SSH connection closed")
                except Exception as e:
                    logger.debug("Error closing SSH connection: %s", e)
                self._client = None
