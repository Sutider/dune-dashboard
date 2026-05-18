"""Audit logging service - tracks important admin actions"""

import os
import json
import logging
from datetime import datetime
from threading import Lock

logger = logging.getLogger(__name__)


class AuditService:
    """In-memory audit log service (could be extended to database)."""
    
    SENSITIVE_KEYS = {'password', 'password_hash', 'secret_key', 'token', 'ssh_key', 'key', 'cert', 'credentials'}
    
    def __init__(self, log_dir=None):
        self._lock = Lock()
        self._logs = []
        self._max_logs = 1000
        self._log_dir = log_dir or os.path.join(os.path.dirname(os.path.dirname(__file__)), 'logs')
        os.makedirs(self._log_dir, exist_ok=True)
    
    def _filter_sensitive(self, data):
        """Remove sensitive data from details before logging to file."""
        if not isinstance(data, dict):
            return data
        filtered = {}
        for k, v in data.items():
            if any(s in k.lower() for s in self.SENSITIVE_KEYS):
                filtered[k] = '[REDACTED]'
            elif isinstance(v, dict):
                filtered[k] = self._filter_sensitive(v)
            elif isinstance(v, list):
                filtered[k] = [self._filter_sensitive(i) if isinstance(i, dict) else i for i in v]
            else:
                filtered[k] = v
        return filtered
    
    def log(self, action, details=None, user='system', severity='info'):
        """Log an audit event."""
        with self._lock:
            entry = {
                'timestamp': datetime.now().isoformat(),
                'action': action,
                'user': user,
                'severity': severity,
                'details': details or {}
            }
            self._logs.append(entry)
            # Trim old logs
            if len(self._logs) > self._max_logs:
                self._logs = self._logs[-self._max_logs:]
            # Also write to file (with sensitive data filtered)
            safe_entry = entry.copy()
            safe_entry['details'] = self._filter_sensitive(entry.get('details', {}))
            self._write_to_file(safe_entry)
            logger.info(f"Audit: {action} by {user}")
    
    def _write_to_file(self, entry):
        """Write audit entry to daily log file."""
        try:
            date = datetime.now().strftime('%Y-%m-%d')
            log_file = os.path.join(self._log_dir, f'audit-{date}.log')
            with open(log_file, 'a') as f:
                f.write(json.dumps(entry) + '\n')
        except Exception as e:
            logger.warning(f"Failed to write audit log to file: {e}")
    
    def get_logs(self, action=None, user=None, limit=100, offset=0):
        """Query audit logs."""
        with self._lock:
            results = self._logs
            if action:
                results = [e for e in results if e['action'] == action]
            if user:
                results = [e for e in results if e['user'] == user]
            results = results[offset:offset+limit]
            return results
    
    def clear_old_logs(self, days=30):
        """Remove log files older than specified days."""
        try:
            import time
            cutoff = time.time() - (days * 86400)
            for f in os.listdir(self._log_dir):
                if f.startswith('audit-') and f.endswith('.log'):
                    fpath = os.path.join(self._log_dir, f)
                    if os.path.getmtime(fpath) < cutoff:
                        os.remove(fpath)
                        logger.info(f"Removed old audit log: {f}")
        except Exception as e:
            logger.warning(f"Failed to clear old logs: {e}")
    
    def get_stats(self):
        """Get audit log statistics."""
        with self._lock:
            return {
                'total_entries': len(self._logs),
                'by_severity': self._count_by('severity'),
                'by_action': self._count_by('action'),
            }
    
    def _count_by(self, key):
        """Count entries by a specific key."""
        counts = {}
        for entry in self._logs:
            val = entry.get(key, 'unknown')
            counts[val] = counts.get(val, 0) + 1
        return counts