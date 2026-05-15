"""Application factory - creates and configures the Flask app"""

import os
import sys
import logging
import logging.handlers
import threading
from flask import Flask, request
from flask_socketio import SocketIO
from flask_limiter import Limiter
from flask_wtf.csrf import CSRFProtect
from flask_limiter.util import get_remote_address

from app.config import load_settings
from app.services.database import DatabaseService
from app.services.ssh import SSHService
from app.services.k8s import K8sService
from app.services.player import PlayerService
from app.services.vehicle import VehicleService
from app.services.chat import ChatService
from app.services.admin import AdminService
from app.services.updater import UpdateService
from app.utils.cache import MultiCache
from app.routes.main import register_routes
from app.routes.api import register_api_routes
from app.routes.auth import init_auth
from app.websocket.shell import register_websocket_handlers


def create_app(settings_path=None):
    settings = load_settings(settings_path)

    base_dir = os.path.dirname(os.path.dirname(__file__))

    app = Flask(
        __name__,
        template_folder=os.path.join(base_dir, 'templates'),
        static_folder=os.path.join(base_dir, 'static'),
        static_url_path='/static'
    )
    app.config['SECRET_KEY'] = settings['dashboard']['secret_key']
    app.config['SESSION_COOKIE_HTTPONLY'] = True
    app.config['SESSION_COOKIE_SAMESITE'] = 'Lax'
    app.config['WTF_CSRF_ENABLED'] = True
    app.config['WTF_CSRF_TIME_LIMIT'] = None

    csrf = CSRFProtect(app)
    csrf.init_app(app)

    ssl_enabled = bool(
        settings['dashboard'].get('ssl_cert')
        and settings['dashboard'].get('ssl_key')
        and settings['dashboard']['ssl_cert'] != 'null'
        and settings['dashboard']['ssl_key'] != 'null'
    )

    # Set SESSION_COOKIE_SECURE conditional on SSL being enabled
    app.config['SESSION_COOKIE_SECURE'] = ssl_enabled

    # Add security headers manually (replaces deprecated Flask-Talisman)
    if not settings['dashboard']['debug']:
        @app.after_request
        def add_security_headers(response):
            # HSTS - only when SSL is enabled
            if ssl_enabled:
                response.headers['Strict-Transport-Security'] = 'max-age=31536000; includeSubDomains'
            # Prevent clickjacking
            response.headers['X-Frame-Options'] = 'SAMEORIGIN'
            # Prevent MIME-type sniffing
            response.headers['X-Content-Type-Options'] = 'nosniff'
            # XSS protection
            response.headers['X-XSS-Protection'] = '1; mode=block'
            return response

    _setup_logging(settings)

    db_config = {
        'host': settings['database']['host'],
        'port': settings['database']['port'],
        'user': settings['database']['user'],
        'password': settings['database']['password'],
        'database': settings['database']['name'],
    }

    db_service = DatabaseService(
        db_config,
        min_conn=settings['database']['min_connections'],
        max_conn=settings['database']['max_connections']
    )
    db_service.ensure_tables()

    # Create performance indexes if they don't exist
    try:
        admin_svc_for_indexes = AdminService(db_service, None)
        success, created, error = admin_svc_for_indexes.create_indexes()
        if success and created:
            logging.info(f"Created {len(created)} database indexes")
    except Exception as e:
        logging.warning(f"Could not create indexes: {e}")

    ssh_service = SSHService(
        host=settings['server']['host'],
        user=settings['server']['user'],
        ssh_key=settings['server'].get('ssh_key')
    )

    k8s_service = K8sService(
        ssh_service=ssh_service,
        namespace=settings['kubernetes']['namespace']
    )

    static_cache = MultiCache(ttl_seconds=settings['cache']['static_data_ttl'])

    player_svc = PlayerService(db_service)
    vehicle_svc = VehicleService(db_service)
    chat_svc = ChatService(db_service, k8s_service, ssh_service, static_cache)
    admin_svc = AdminService(db_service, ssh_service)
    updater_svc = UpdateService(base_dir)

    services = {
        'db': db_service,
        'ssh': ssh_service,
        'k8s': k8s_service,
        'player': player_svc,
        'vehicle': vehicle_svc,
        'chat': chat_svc,
        'admin': admin_svc,
        'static_cache': static_cache,
        'updater': updater_svc,
    }

    socketio = SocketIO(app, cors_allowed_origins=[], async_mode='threading')

    # Initialize rate limiter
    limiter = Limiter(
        app=app,
        key_func=get_remote_address,
        default_limits=["200 per day", "50 per hour"],
        storage_uri="memory://",
    )

    if settings['auth']['enabled']:
        init_auth(app, settings, limiter)

    register_routes(app, services, settings)
    register_api_routes(app, services, settings)
    register_websocket_handlers(socketio, settings)

    # Start update checker
    updater_svc.start_checker()

    @app.teardown_appcontext
    def cleanup_db(exc):
        pass

    if settings['kubernetes']['namespace'] == '':
        try:
            k8s_service.auto_detect_namespace()
            if k8s_service.namespace:
                settings['kubernetes']['namespace'] = k8s_service.namespace
        except Exception as e:
            logging.warning(f"Could not auto-detect K8s namespace: {e}")

    # Check SSL certificate expiry and start background monitor
    if ssl_enabled:
        try:
            from app.utils.ssl import check_cert_expiry, generate_cert
            cert_path = str(settings['dashboard']['ssl_cert']).strip("'\"")
            key_path = str(settings['dashboard']['ssl_key']).strip("'\"")
            is_expiring, days_remaining, msg = check_cert_expiry(cert_path)
            if is_expiring:
                logging.warning(f"SSL: {msg}")
            else:
                logging.info(f"SSL: {msg}")

            def _cert_monitor():
                """Background thread that checks and regenerates expiring SSL certs."""
                import time
                check_interval = settings.get('ssl', {}).get('check_interval_hours', 24) * 3600
                renewal_days = settings.get('ssl', {}).get('renewal_days_before_expiry', 30)
                server_ip = settings['server'].get('host', '')
                ssl_dir = os.path.dirname(cert_path)
                ca_cert = os.path.join(ssl_dir, 'ca.pem')
                ca_key = os.path.join(ssl_dir, 'ca-key.pem')
                ca_available = os.path.exists(ca_cert) and os.path.exists(ca_key)

                is_le = 'letsencrypt' in cert_path.lower() or 'certbot' in cert_path.lower()
                le_domain = settings['dashboard'].get('ssl_domain')

                def _restart_app():
                    import subprocess
                    if os.name == 'nt':
                        launcher = os.path.join(os.path.dirname(os.path.dirname(__file__)), 'start.bat')
                        if os.path.exists(launcher):
                            subprocess.Popen(['cmd', '/c', 'start', '', launcher], shell=True)
                        else:
                            subprocess.Popen([sys.executable, os.path.join(os.path.dirname(os.path.dirname(__file__)), 'run.py')], creationflags=subprocess.CREATE_NEW_CONSOLE)
                    else:
                        launcher = os.path.join(os.path.dirname(os.path.dirname(__file__)), 'start.sh')
                        if os.path.exists(launcher):
                            subprocess.Popen(['bash', launcher], start_new_session=True)
                        else:
                            subprocess.Popen([sys.executable, os.path.join(os.path.dirname(os.path.dirname(__file__)), 'run.py')], start_new_session=True)
                    os._exit(0)

                while True:
                    time.sleep(check_interval)
                    try:
                        is_expiring, days_left, _ = check_cert_expiry(cert_path, warning_days=renewal_days)
                        if is_expiring:
                            if is_le and le_domain:
                                logging.info(f"SSL: Let's Encrypt certificate expiring soon ({days_left} days). Running certbot renew...")
                                import subprocess
                                result = subprocess.run(['certbot', 'renew', '--quiet'], capture_output=True, timeout=300)
                                if result.returncode == 0:
                                    logging.info("SSL: Let's Encrypt certificate renewed. Restarting to apply...")
                                    _restart_app()
                                else:
                                    logging.error(f"SSL: certbot renew failed: {result.stderr.decode()}")
                            elif ca_available:
                                logging.info(f"SSL: Certificate expiring soon ({days_left} days). Regenerating...")
                                san_ips = [server_ip, '127.0.0.1'] if server_ip else ['127.0.0.1']
                                generate_cert(
                                    cert_path=cert_path,
                                    key_path=key_path,
                                    common_name=server_ip or 'localhost',
                                    san_ips=san_ips,
                                    san_dns=['localhost'],
                                    ca_cert_path=ca_cert,
                                    ca_key_path=ca_key,
                                )
                                logging.info("SSL: Certificate regenerated. Restarting to apply...")
                                _restart_app()
                            else:
                                logging.warning("SSL: Certificate expiring but no CA key available. Cannot regenerate.")
                    except Exception as e:
                        logging.error(f"SSL: Background cert check failed: {e}")

            monitor_thread = threading.Thread(target=_cert_monitor, daemon=True)
            monitor_thread.start()
            logging.info("SSL: Background certificate monitor started")
        except Exception as e:
            logging.debug(f"Could not initialize SSL cert monitor: {e}")

    app.dune_settings = settings
    app.dune_services = services

    return app, socketio


def _setup_logging(settings):
    log_level = getattr(logging, settings['logging']['level'].upper(), logging.INFO)
    log_file = settings['logging']['file']

    os.makedirs(os.path.dirname(log_file), exist_ok=True)

    handler = logging.handlers.RotatingFileHandler(
        log_file,
        maxBytes=settings['logging']['max_bytes'],
        backupCount=settings['logging']['backup_count']
    )
    handler.setFormatter(logging.Formatter(
        '%(asctime)s - %(name)s - %(levelname)s - %(message)s'
    ))
    handler.setLevel(log_level)

    console_handler = logging.StreamHandler(sys.stdout)
    console_handler.setFormatter(logging.Formatter(
        '%(asctime)s - %(levelname)s - %(message)s'
    ))
    console_handler.setLevel(log_level)

    root_logger = logging.getLogger()
    root_logger.setLevel(log_level)
    root_logger.addHandler(handler)
    root_logger.addHandler(console_handler)

    audit_logger = logging.getLogger('audit')
    audit_handler = logging.handlers.RotatingFileHandler(
        'logs/audit.log',
        maxBytes=settings['logging']['max_bytes'],
        backupCount=settings['logging']['backup_count']
    )
    audit_handler.setFormatter(logging.Formatter(
        '%(asctime)s - %(message)s'
    ))
    audit_logger.addHandler(audit_handler)
    audit_logger.setLevel(logging.INFO)
