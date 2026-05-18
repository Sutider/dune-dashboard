"""Authentication routes - login, logout"""

from flask import render_template, request, redirect, url_for, flash
from flask_login import LoginManager, UserMixin, login_user, logout_user, login_required, current_user
from flask_limiter import Limiter
from flask_limiter.util import get_remote_address

login_manager = LoginManager()
login_manager.login_view = 'login'
login_manager.login_message = 'Please log in.'

class AdminUser(UserMixin):
    def __init__(self, username):
        self.id = username

def init_auth(app, settings, limiter=None, audit_svc=None):
    login_manager.init_app(app)

    @login_manager.user_loader
    def load_user(user_id):
        auth = settings.get('auth', {})
        if str(auth.get('username')) == str(user_id):
            return AdminUser(user_id)
        return None

    @app.route('/login', methods=['GET', 'POST'])
    @limiter.limit("5 per hour") if limiter else lambda f: f
    def login():
        if current_user.is_authenticated:
            return redirect(url_for('overview'))

        if request.method == 'POST':
            u = request.form.get('username', '')
            p = request.form.get('password', '')
            auth = settings.get('auth', {})

            cfg_u = str(auth.get('username', ''))
            password_hash = auth.get('password_hash')

            # Verify username matches
            if u != cfg_u:
                if audit_svc:
                    audit_svc.log('login_failed', {'username': u, 'reason': 'invalid_username'}, user='unknown', severity='warning')
                flash('Invalid username or password')
                return render_template('login.html')

            # Verify password using Argon2 hash
            if password_hash:
                try:
                    from argon2 import PasswordHasher, exceptions
                    ph = PasswordHasher()
                    if ph.verify(password_hash, p):
                        login_user(AdminUser(u))
                        if audit_svc:
                            audit_svc.log('login_success', {'username': u}, user=u, severity='info')
                        return redirect(url_for('overview'))
                    else:
                        if audit_svc:
                            audit_svc.log('login_failed', {'username': u, 'reason': 'invalid_password'}, user=u, severity='warning')
                except exceptions.VerifyMismatchError:
                    if audit_svc:
                        audit_svc.log('login_failed', {'username': u, 'reason': 'invalid_password'}, user=u, severity='warning')
                    pass
                except Exception:
                    flash('Authentication error. Please try again.')
                    return render_template('login.html')
            else:
                flash('Authentication not configured. Please run setup.')
                return render_template('login.html')

            flash('Invalid username or password')

        return render_template('login.html')

    @app.route('/logout')
    @login_required
    def logout():
        user = current_user.id if current_user.is_authenticated else 'unknown'
        logout_user()
        if audit_svc:
            audit_svc.log('logout', {}, user=user, severity='info')
        return redirect(url_for('login'))
