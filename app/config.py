"""Settings loader - reads settings.yaml with env var overrides"""

import os
import yaml
import logging
import copy
import secrets

logger = logging.getLogger(__name__)

DEFAULTS = {
    'server': {
        'host': '127.0.0.1',
        'user': 'dune',
        'ssh_key': None,
    },
    'dashboard': {
        'host': '127.0.0.1',
        'port': 5050,
        'debug': False,
        'secret_key': None,  # Generated at runtime if not set
        'ssl_cert': None,
        'ssl_key': None,
        'ssl_domain': None,
        'ssl_email': None,
    },
    'database': {
        'host': '127.0.0.1',
        'port': 15433,
        'user': 'postgres',
        'password': None,  # Must be set via setup or env var
        'name': 'dune',
        'schema': 'dune',
        'min_connections': 2,
        'max_connections': 10,
    },
    'kubernetes': {
        'namespace': '',
        'battlegroup_script': '/home/dune/.dune/bin/battlegroup',
    },
    'director': {
        'port': 32479,
    },
    'filebrowser': {
        'port': 18888,
    },
    'firewall': {
        'block_filebrowser': False,
        'block_director': False,
        'block_postgres': True,
    },
    'cache': {
        'chat_pod_ttl': 60,
        'chat_messages_ttl': 10,
        'static_data_ttl': 300,
    },
    'auth': {
        'enabled': True,
        'username': None,  # Must be set via setup
        'password_hash': None,  # Argon2 hash, never plaintext
    },
    'logging': {
        'level': 'INFO',
        'file': 'logs/dashboard.log',
        'max_bytes': 10485760,
        'backup_count': 5,
    },
    'ssl': {
        'check_interval_hours': 24,
        'renewal_days_before_expiry': 30,
    },
}


def deep_merge(base, override):
    """Deep merge override dict into base dict."""
    result = base.copy()
    for key, value in override.items():
        if key in result and isinstance(result[key], dict) and isinstance(value, dict):
            result[key] = deep_merge(result[key], value)
        else:
            result[key] = value
    return result


def _find_missing_keys(defaults, current, path=""):
    """Find keys present in defaults but missing in current."""
    missing = []
    for key, val in defaults.items():
        new_path = f"{path}.{key}" if path else key
        if key not in current:
            missing.append(new_path)
        elif isinstance(val, dict) and isinstance(current.get(key), dict):
            missing.extend(_find_missing_keys(val, current[key], new_path))
    return missing


def _apply_defaults_to_file(settings_path, defaults):
    """Add missing default keys to settings.yaml and notify user."""
    if not os.path.exists(settings_path):
        return False

    with open(settings_path, 'r') as f:
        try:
            current = yaml.safe_load(f) or {}
        except Exception:
            return False

    missing = _find_missing_keys(defaults, current)
    if not missing:
        return False

    # Merge and save
    merged = deep_merge(defaults, current)
    try:
        with open(settings_path, 'w') as f:
            yaml.dump(merged, f, default_flow_style=False, sort_keys=False)
        print(f"\n  [INFO] Settings updated with new defaults: {', '.join(missing)}")
        return True
    except Exception as e:
        logger.error(f"Failed to update settings file: {e}")
        return False


def load_settings(settings_path=None):
    """Load settings from YAML file with defaults and env var overrides."""
    if settings_path is None:
        settings_path = os.path.join(os.path.dirname(os.path.dirname(__file__)), 'settings.yaml')

    settings = copy.deepcopy(DEFAULTS)

    if os.path.exists(settings_path):
        try:
            with open(settings_path, 'r') as f:
                file_settings = yaml.safe_load(f) or {}
            settings = deep_merge(settings, file_settings)
            logger.info(f"Settings loaded from {settings_path}")
        except Exception as e:
            logger.error(f"Failed to load settings from {settings_path}: {e}")
            logger.warning("Using default settings")
    else:
        logger.warning(f"Settings file not found at {settings_path}, using defaults")

    # Auto-apply new defaults if missing
    _apply_defaults_to_file(settings_path, DEFAULTS)

    env_overrides = {}

    if os.environ.get('DUNE_SERVER_HOST'):
        env_overrides.setdefault('server', {})['host'] = os.environ['DUNE_SERVER_HOST']
    if os.environ.get('DUNE_SERVER_USER'):
        env_overrides.setdefault('server', {})['user'] = os.environ['DUNE_SERVER_USER']
    if os.environ.get('DUNE_DB_PASSWORD'):
        env_overrides.setdefault('database', {})['password'] = os.environ['DUNE_DB_PASSWORD']
    if os.environ.get('DUNE_K8S_NAMESPACE'):
        env_overrides.setdefault('kubernetes', {})['namespace'] = os.environ['DUNE_K8S_NAMESPACE']
    if os.environ.get('DUNE_AUTH_PASSWORD'):
        env_overrides.setdefault('auth', {})['password'] = os.environ['DUNE_AUTH_PASSWORD']
    if os.environ.get('DUNE_DASHBOARD_PORT'):
        env_overrides.setdefault('dashboard', {})['port'] = int(os.environ['DUNE_DASHBOARD_PORT'])

    if env_overrides:
        settings = deep_merge(settings, env_overrides)
        logger.info("Environment variable overrides applied")

    # Generate secure secret_key if not set
    if not settings['dashboard'].get('secret_key'):
        settings['dashboard']['secret_key'] = secrets.token_hex(32)
        logger.info("Generated secure SECRET_KEY")

    # Backward compatibility: migrate old plaintext password to hash
    # This is a one-time migration that hashes the password and removes plaintext
    auth = settings.get('auth', {})
    if auth.get('password') and not auth.get('password_hash'):
        try:
            from argon2 import PasswordHasher
            ph = PasswordHasher()
            settings['auth']['password_hash'] = ph.hash(str(auth['password']))
            # Remove plaintext after hashing
            del settings['auth']['password']
            logger.info("Migrated plaintext password to Argon2 hash")
        except ImportError:
            logger.error("argon2-cffi not installed. Password hashing unavailable.")
            # Fallback: keep plaintext for now but log warning
            settings['auth']['password_hash'] = None

    return settings
