"""Test that administrative API routes require authentication"""

import pytest
import sys
import os

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


ADMIN_ENDPOINTS = [
    ("post", "/server/battlegroup/action"),
    ("post", "/server/battlegroup/update"),
    ("get", "/server/firewall"),
    ("post", "/server/firewall/block"),
    ("post", "/server/firewall/unblock"),
    ("get", "/api/chat_logs"),
    ("post", "/api/set_player_ip"),
    ("post", "/api/detect_player_ips"),
    ("post", "/api/ban_player"),
    ("post", "/api/get_player_ban"),
    ("post", "/api/get_player_history"),
    ("post", "/api/unban_player"),
    ("post", "/api/emergency_unban"),
    ("post", "/api/kick_player"),
    ("post", "/api/edit_vitals"),
    ("post", "/api/maintenance/create_indexes"),
    ("delete", "/api/vehicles/1"),
    ("delete", "/api/buildings/1"),
]


@pytest.fixture
def client(tmp_path, monkeypatch):
    settings_path = tmp_path / "settings.yaml"
    settings_path.write_text(
        """
server:
  host: 127.0.0.1
  user: dune
dashboard:
  host: 127.0.0.1
  port: 5050
  debug: false
  secret_key: test-secret
database:
  host: 127.0.0.1
  port: 15433
  user: postgres
  password: postgres
  name: dune
kubernetes:
  namespace: test
auth:
  enabled: true
  username: admin
  password_hash: "$argon2id$v=19$m=65536,t=3,p=4$invalid$invalid"
logging:
  file: logs/test.log
""",
        encoding="utf-8",
    )

    monkeypatch.setattr("app.services.database.DatabaseService.ensure_tables", lambda self: None)
    monkeypatch.setattr("app.services.admin.AdminService.create_indexes", lambda self: (True, [], None))
    monkeypatch.setattr("app.services.updater.UpdateService.start_checker", lambda self: None)

    from app.factory import create_app
    app, _ = create_app(str(settings_path))
    app.config.update(TESTING=True, WTF_CSRF_ENABLED=False)
    return app.test_client()


@pytest.mark.parametrize(("method", "path"), ADMIN_ENDPOINTS)
def test_admin_endpoints_require_login(client, method, path):
    """All administrative endpoints should require authentication when auth is enabled."""
    response = getattr(client, method)(path)
    assert response.status_code in (302, 401, 403), f"{method.upper()} {path} returned {response.status_code}, expected 302/401/403"