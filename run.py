#!/usr/bin/env python3
"""Dune Awakening Dashboard - Entry Point"""

import os
import sys

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

    print(f"\n  Dune Awakening Dashboard")
    print(f"  http://{host}:{port}")
    print(f"  Debug: {debug}\n")

    socketio.run(app, host=host, port=port, debug=debug, log_output=False)
