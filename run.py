#!/usr/bin/env python3
"""Dune Awakening Dashboard - Entry Point"""

import os
import sys
import socket
import threading

sys.path.insert(0, os.path.dirname(__file__))

from app.factory import create_app

app, socketio = create_app()

if __name__ == '__main__':
    import logging
    logging.getLogger('werkzeug').setLevel(logging.ERROR)

    settings = app.dune_settings
    host = settings['dashboard']['host']
    port = settings['dashboard']['port']
    debug = settings['dashboard']['debug']

    # SSL Configuration
    ssl_context = None
    ssl_cert = settings['dashboard'].get('ssl_cert')
    ssl_key = settings['dashboard'].get('ssl_key')

    if ssl_cert and ssl_key and ssl_cert != 'null' and ssl_key != 'null':
        cert_path = str(ssl_cert).strip("'\"")
        key_path = str(ssl_key).strip("'\"")
        if os.path.exists(cert_path) and os.path.exists(key_path):
            ssl_context = (cert_path, key_path)
            protocol = "https"
        else:
            print(f"  [WARN] SSL files not found: {cert_path}")
            protocol = "http"
    else:
        protocol = "http"

    print(f"\n  Dune Awakening Dashboard")
    print(f"  {protocol}://{host}:{port}")
    print(f"  Debug: {debug}")
    if ssl_context:
        print(f"  SSL: Enabled\n")
    else:
        print(f"  SSL: Disabled (use http:// not https://)\n")
        if host == '0.0.0.0':
            print("  [WARN] Binding to 0.0.0.0 without SSL! Credentials sent in cleartext.")
            print("  [WARN] Enable SSL in settings.yaml or bind to 127.0.0.1\n")

    # Start HTTP → HTTPS redirect server when SSL is enabled
    if ssl_context:
        from http.server import HTTPServer, BaseHTTPRequestHandler

        class RedirectHandler(BaseHTTPRequestHandler):
            def do_GET(self):
                self.send_response(301)
                self.send_header('Location', f'https://{self.headers.get("Host", "localhost")}:{port}{self.path}')
                self.end_headers()

            def do_HEAD(self):
                self.do_GET()

            def do_POST(self):
                self.do_GET()

            def log_message(self, format, *args):
                pass

        # Try port 80 first, fall back to port+1
        # Try 0.0.0.0 first (all interfaces), fall back to 127.0.0.1 (localhost only)
        http_port = None
        redirect_host = None
        for try_port in [80, port + 1]:
            for try_host in ['0.0.0.0', '127.0.0.1']:
                try:
                    test_sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
                    test_sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
                    test_sock.bind((try_host, try_port))
                    test_sock.close()
                    http_port = try_port
                    redirect_host = try_host
                    break
                except OSError:
                    continue
            if http_port:
                break

        if http_port:
            redirect_server = HTTPServer((redirect_host, http_port), RedirectHandler)
            redirect_thread = threading.Thread(target=redirect_server.serve_forever, daemon=True)
            redirect_thread.start()
            print(f"  HTTP redirect: http://0.0.0.0:{http_port} → https://{host}:{port}" if redirect_host == '0.0.0.0' else f"  HTTP redirect: http://localhost:{http_port} → https://{host}:{port}")
            if http_port == 80:
                print(f"  (visit http://localhost — auto redirects to https://)\n")
            else:
                print(f"  (visit http://localhost:{http_port} — auto redirects to https://)\n")
        else:
            print("  [WARN] Could not start HTTP redirect server\n")

    socketio.run(app, host=host, port=port, debug=debug, log_output=False, ssl_context=ssl_context)
