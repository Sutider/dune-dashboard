"""API routes - server actions, player management, debug endpoints"""

import json
import logging
from flask import Blueprint, request, jsonify
from flask_login import login_required
from flask_limiter import Limiter
from flask_limiter.util import get_remote_address
from app.utils.constants import NAV_PAGES

logger = logging.getLogger(__name__)


def register_api_routes(app, services, settings):
    db = services['db']
    ssh = services['ssh']
    k8s = services['k8s']
    chat_svc = services['chat']
    admin_svc = services['admin']
    vehicle_svc = services['vehicle']

    # Get or create rate limiter - use existing one from factory if available
    if not hasattr(app, 'limiter'):
        limiter = Limiter(
            app=app,
            key_func=get_remote_address,
            default_limits=["200 per day", "50 per hour"],
            storage_uri="memory://",
        )
    else:
        limiter = app.limiter

    # Only require login if auth is enabled
    auth_req = login_required if settings.get('auth', {}).get('enabled', True) else lambda f: f

    # Server actions
    @app.route('/server/action', methods=['POST'])
    @auth_req
    @limiter.limit("20 per hour")
    def server_action():
        deployment = request.form.get('deployment', '')
        action = request.form.get('action', '')
        if not deployment or not action:
            return jsonify({'success': False, 'output': 'Missing deployment or action'})

        actions = {
            'restart': f'rollout restart deployment/{deployment}',
            'status': f'rollout status deployment/{deployment}',
            'scale_0': f'scale deployment/{deployment} --replicas=0',
            'scale_1': f'scale deployment/{deployment} --replicas=1',
            'describe': f'describe deployment/{deployment}',
        }
        cmd = actions.get(action)
        if not cmd:
            return jsonify({'success': False, 'output': f'Unknown action: {action}'})

        out, err, rc = k8s.run(cmd)
        return jsonify({'success': rc == 0, 'output': out + '\n' + err})

    @app.route('/server/pods')
    @auth_req
    def server_pods():
        out, err, rc = k8s.run('get pods -o wide')
        if rc != 0:
            return jsonify({'success': False, 'output': err})
        return jsonify({'success': True, 'output': out})

    @app.route('/server/metrics')
    @auth_req
    def server_metrics():
        metrics = k8s.get_node_metrics()
        if metrics:
            return jsonify(metrics)
        return jsonify({'cpu': 'N/A', 'memory': 'N/A'})

    # Battlegroup
    @app.route('/server/battlegroup/status')
    @auth_req
    def battlegroup_status():
        bg_script = settings['kubernetes']['battlegroup_script']
        out, err, rc = ssh.run(f'{bg_script} status', timeout=30)
        return jsonify({'success': rc == 0, 'output': out + err if out or err else 'No output'})

    @app.route('/server/battlegroup/action', methods=['POST'])
    @limiter.limit("10 per hour")
    def battlegroup_action():
        action = request.form.get('action', '')
        if action not in ('start', 'stop', 'restart'):
            return jsonify({'success': False, 'output': f'Unknown action: {action}'})
        bg_script = settings['kubernetes']['battlegroup_script']
        out, err, rc = ssh.run(f'{bg_script} {action}', timeout=120)
        return jsonify({'success': rc == 0, 'output': out + err if out or err else 'No output'})

    @app.route('/server/battlegroup/update', methods=['POST'])
    @limiter.limit("5 per hour")
    def battlegroup_update():
        bg_script = settings['kubernetes']['battlegroup_script']
        out, err, rc = ssh.run(f'{bg_script} update', timeout=600)
        return jsonify({'success': rc == 0, 'output': out + err if out or err else 'No output'})

    # Firewall management
    @app.route('/server/firewall')
    def firewall_status():
        port_map = {
            'filebrowser': {'port': 18888, 'name': 'File Browser'},
            'director': {'port': 31820, 'name': 'Battlegroup Director'},
            'postgres': {'port': 15432, 'name': 'PostgreSQL'},
        }

        out, _, _ = ssh.run('sudo iptables -L INPUT -n 2>/dev/null | grep -E "dpt:(18888|31820|15432)"; sudo iptables -L FORWARD -n 2>/dev/null | grep -E "dpt:(18888|31820|15432)"; sudo iptables -t mangle -L PREROUTING -n 2>/dev/null | grep -E "dpt:(18888|31820|15432)"', timeout=15)

        blocked_ports = set()
        rules = {}
        for line in out.split('\n'):
            for port in ['18888', '31820', '15432']:
                if f'dpt:{port}' in line and 'DROP' in line:
                    blocked_ports.add(port)
                    rules[port] = line.strip()

        blocked = []
        available = []
        for key, info in port_map.items():
            port_str = str(info['port'])
            if port_str in blocked_ports:
                blocked.append(info)
            else:
                available.append(info)

        return jsonify({
            'success': True,
            'blocked': blocked,
            'available': available,
            'iptables_rules': rules,
        })

    @app.route('/server/firewall/block', methods=['POST'])
    @limiter.limit("10 per hour")
    def firewall_block():
        port = request.form.get('port', type=int)
        if port not in (18888, 31820, 15432):
            return jsonify({'success': False, 'output': 'Invalid port'})

        cmd = (
            f'sudo iptables -I INPUT 1 -p tcp --dport {port} -s 127.0.0.1 -j ACCEPT && '
            f'sudo iptables -I INPUT 2 -p tcp --dport {port} -j DROP && '
            f'sudo iptables -I FORWARD 1 -p tcp --dport {port} -s 127.0.0.1 -j ACCEPT && '
            f'sudo iptables -I FORWARD 2 -p tcp --dport {port} -j DROP && '
            f'sudo iptables -t mangle -I PREROUTING 1 -p tcp --dport {port} -s 127.0.0.1 -j ACCEPT && '
            f'sudo iptables -t mangle -I PREROUTING 2 -p tcp --dport {port} -j DROP'
        )
        out, err, rc = ssh.run(cmd, timeout=20)
        if rc != 0 and 'already exists' not in (out + err):
            return jsonify({'success': False, 'output': err})

        port_key = {18888: 'block_filebrowser', 31820: 'block_director', 15432: 'block_postgres'}.get(port)
        if port_key:
            settings.setdefault('firewall', {})[port_key] = True
            import yaml
            settings_path = None
            for p in ['settings.yaml', 'settings.yml']:
                import os
                if os.path.exists(p):
                    settings_path = p
                    break
            if settings_path:
                with open(settings_path, 'w') as f:
                    yaml.dump(dict(settings), f)

        return jsonify({'success': True, 'output': f'Port {port} blocked (localhost allowed)'})

    @app.route('/server/firewall/unblock', methods=['POST'])
    @limiter.limit("10 per hour")
    def firewall_unblock():
        port = request.form.get('port', type=int)
        if port not in (18888, 31820, 15432):
            return jsonify({'success': False, 'output': 'Invalid port'})

        cmd = (
            f'sudo iptables -D INPUT -p tcp --dport {port} -j DROP 2>/dev/null; '
            f'sudo iptables -D INPUT -p tcp --dport {port} -s 127.0.0.1 -j ACCEPT 2>/dev/null; '
            f'sudo iptables -D FORWARD -p tcp --dport {port} -j DROP 2>/dev/null; '
            f'sudo iptables -D FORWARD -p tcp --dport {port} -s 127.0.0.1 -j ACCEPT 2>/dev/null; '
            f'sudo iptables -t mangle -D PREROUTING -p tcp --dport {port} -j DROP 2>/dev/null; '
            f'sudo iptables -t mangle -D PREROUTING -p tcp --dport {port} -s 127.0.0.1 -j ACCEPT 2>/dev/null; '
            f'echo DONE'
        )
        out, err, rc = ssh.run(cmd, timeout=20)
        combined = (out + err).strip()
        all_ok = 'DONE' in out or rc == 0

        port_key = {18888: 'block_filebrowser', 31820: 'block_director', 15432: 'block_postgres'}.get(port)
        if port_key:
            settings.setdefault('firewall', {})[port_key] = False
            import yaml
            settings_path = None
            for p in ['settings.yaml', 'settings.yml']:
                import os
                if os.path.exists(p):
                    settings_path = p
                    break
            if settings_path:
                with open(settings_path, 'w') as f:
                    yaml.dump(dict(settings), f)

        return jsonify({'success': all_ok, 'output': 'Port unblocked' if all_ok else combined})

    # Chat API
    @app.route('/api/chat_logs')
    def api_chat_logs():
        try:
            chat_svc.ensure_history_table()

            db_messages = chat_svc.get_history(1)
            if not db_messages or len(db_messages) < 10:
                chat_svc.catch_up(settings['kubernetes']['namespace'])

            db_messages = chat_svc.get_history(200)
            messages = []
            for row in db_messages:
                ts = row.get('timestamp')
                messages.append({
                    'channel': row.get('channel', ''),
                    'sender': row.get('sender', ''),
                    'message': row.get('message', ''),
                    'timestamp': ts.isoformat() if ts else '',
                    'location': {'X': row.get('location_x', 0), 'Y': row.get('location_y', 0), 'Z': row.get('location_z', 0)},
                    'target': row.get('target', ''),
                    'is_admin': row.get('is_admin', False),
                })

            return jsonify({'success': True, 'messages': messages, 'count': len(messages)})
        except Exception as e:
            return jsonify({'success': False, 'error': str(e)})

    # Player IP management
    @app.route('/api/set_player_ip', methods=['POST'])
    def api_set_player_ip():
        try:
            player_id = request.form.get('player_id', type=int)
            ip_address = request.form.get('ip_address', '').strip()
            if not player_id:
                return jsonify({'success': False, 'error': 'Missing player_id'})
            if not ip_address:
                return jsonify({'success': False, 'error': 'Missing ip_address'})

            if admin_svc.set_player_ip(player_id, ip_address):
                return jsonify({'success': True, 'message': f'IP {ip_address} set for player {player_id}'})
            return jsonify({'success': False, 'error': 'Failed to set IP'})
        except Exception as e:
            return jsonify({'success': False, 'error': str(e)})

    @app.route('/api/detect_player_ips', methods=['POST'])
    def api_detect_player_ips():
        try:
            success, message = admin_svc.detect_player_ips(settings['kubernetes']['namespace'])
            return jsonify({'success': success, 'message': message})
        except Exception as e:
            return jsonify({'success': False, 'error': str(e)})

    # Ban management
    @app.route('/api/ban_player', methods=['POST'])
    @limiter.limit("20 per hour")
    def api_ban_player():
        try:
            player_id = request.form.get('player_id', type=int)
            duration = request.form.get('duration', '0')
            reason = request.form.get('reason', '')
            note = request.form.get('note', '')

            if not player_id:
                return jsonify({'success': False, 'error': 'Missing player_id'})

            success, message = admin_svc.ban_player(player_id, duration, reason, note)
            return jsonify({'success': success, 'message': message})
        except Exception as e:
            return jsonify({'success': False, 'error': str(e)})

    @app.route('/api/get_player_ban', methods=['POST'])
    def api_get_player_ban():
        try:
            player_id = request.form.get('player_id', type=int)
            if not player_id:
                return jsonify({'success': False, 'error': 'Missing player_id'})

            ban = admin_svc.get_player_ban(player_id)
            if ban:
                return jsonify({
                    'success': True, 'banned': True,
                    'reason': ban.get('reason', ''),
                    'note': ban.get('note', ''),
                    'duration': ban.get('duration', 0),
                    'banned_at': ban.get('banned_at').isoformat() if ban.get('banned_at') else '',
                    'expires_at': ban.get('expires_at').isoformat() if ban.get('expires_at') else 'Permanent'
                })
            return jsonify({'success': True, 'banned': False})
        except Exception as e:
            return jsonify({'success': False, 'error': str(e)})

    @app.route('/api/get_player_history', methods=['POST'])
    def api_get_player_history():
        try:
            player_id = request.form.get('player_id', type=int)
            if not player_id:
                return jsonify({'success': False, 'error': 'Missing player_id'})

            actions = admin_svc.get_player_history(player_id)
            history = []
            for a in actions:
                history.append({
                    'action': a.get('action_type', ''),
                    'reason': a.get('reason', ''),
                    'note': a.get('note', ''),
                    'duration': a.get('duration_minutes', 0),
                    'ip': a.get('ip_address', ''),
                    'created_at': a.get('created_at').isoformat() if a.get('created_at') else ''
                })
            return jsonify({'success': True, 'history': history})
        except Exception as e:
            return jsonify({'success': False, 'error': str(e)})

    @app.route('/api/unban_player', methods=['POST'])
    @limiter.limit("20 per hour")
    def api_unban_player():
        try:
            player_id = request.form.get('player_id', type=int)
            if not player_id:
                return jsonify({'success': False, 'error': 'Missing player_id'})

            success, message = admin_svc.unban_player(player_id)
            return jsonify({'success': success, 'message': message})
        except Exception as e:
            return jsonify({'success': False, 'error': str(e)})

    @app.route('/api/emergency_unban', methods=['POST'])
    def api_emergency_unban():
        try:
            ip = request.form.get('ip', '').strip()
            if not ip:
                return jsonify({'success': False, 'error': 'Missing IP'})
            success, message = admin_svc.emergency_unban(ip)
            return jsonify({'success': success, 'message': message})
        except Exception as e:
            return jsonify({'success': False, 'error': str(e)})

    @app.route('/api/kick_player', methods=['POST'])
    @limiter.limit("30 per hour")
    def api_kick_player():
        try:
            player_id = request.form.get('player_id', type=int)
            if not player_id:
                return jsonify({'success': False, 'error': 'Missing player_id'})

            success, message = admin_svc.kick_player(player_id)
            return jsonify({'success': success, 'message': message})
        except Exception as e:
            return jsonify({'success': False, 'error': str(e)})

    # Vitals editing
    @app.route('/api/edit_vitals', methods=['POST'])
    @limiter.limit("30 per hour")
    def api_edit_vitals():
        try:
            pawn_id = request.form.get('pawn_id', type=int)
            current_health = request.form.get('current_health', type=float)
            max_health = request.form.get('max_health', type=float)
            current_hydration = request.form.get('current_hydration', type=float)
            current_spice = request.form.get('current_spice', type=float)

            success, result = admin_svc.edit_vitals(pawn_id, current_health, max_health, current_hydration, current_spice)
            if success:
                return jsonify({'success': True, **result})
            return jsonify({'success': False, 'error': result})
        except Exception as e:
            return jsonify({'success': False, 'error': str(e)})

    # Player editing endpoints
    @app.route('/api/edit_faction', methods=['POST'])
    @auth_req
    def api_edit_faction():
        try:
            player_controller_id = request.form.get('player_controller_id', type=int)
            faction_id = request.form.get('faction_id', type=int)
            if not player_controller_id:
                return jsonify({'success': False, 'error': 'Missing player_controller_id'})
            if faction_id is None:
                return jsonify({'success': False, 'error': 'Missing faction_id'})

            success, result = admin_svc.edit_faction(player_controller_id, faction_id)
            if success:
                return jsonify({'success': True, 'message': f'Faction changed to {result["faction_id"]}'})
            return jsonify({'success': False, 'error': result})
        except Exception as e:
            return jsonify({'success': False, 'error': str(e)})

    @app.route('/api/edit_xp', methods=['POST'])
    @auth_req
    def api_edit_xp():
        try:
            player_id = request.form.get('player_id', type=int)
            track_type = request.form.get('track_type', '').strip()
            xp_amount = request.form.get('xp_amount', type=float)
            level = request.form.get('level', type=float)

            if not player_id or not track_type or xp_amount is None:
                return jsonify({'success': False, 'error': 'Missing required parameters'})

            success, result = admin_svc.edit_xp(player_id, track_type, xp_amount, level)
            if success:
                return jsonify({'success': True, 'message': f'XP updated for {track_type}'})
            return jsonify({'success': False, 'error': result})
        except Exception as e:
            return jsonify({'success': False, 'error': str(e)})

    @app.route('/api/edit_tech_knowledge', methods=['POST'])
    @auth_req
    def api_edit_tech_knowledge():
        try:
            player_id = request.form.get('player_id', type=int)
            xp_points = request.form.get('xp_points', type=int)

            if not player_id or xp_points is None:
                return jsonify({'success': False, 'error': 'Missing required parameters'})

            success, result = admin_svc.edit_tech_knowledge(player_id, xp_points)
            if success:
                return jsonify({'success': True, 'message': 'Tech knowledge updated'})
            return jsonify({'success': False, 'error': result})
        except Exception as e:
            return jsonify({'success': False, 'error': str(e)})

    @app.route('/api/edit_currency', methods=['POST'])
    @auth_req
    def api_edit_currency():
        try:
            player_controller_id = request.form.get('player_controller_id', type=int)
            currency_id = request.form.get('currency_id', type=int)
            new_balance = request.form.get('new_balance', type=int)

            if not player_controller_id or currency_id is None or new_balance is None:
                return jsonify({'success': False, 'error': 'Missing required parameters'})

            success, result = admin_svc.edit_currency(player_controller_id, currency_id, new_balance)
            if success:
                return jsonify({'success': True, 'message': 'Currency updated', 'new_balance': result['new_balance']})
            return jsonify({'success': False, 'error': result})
        except Exception as e:
            return jsonify({'success': False, 'error': str(e)})

    @app.route('/api/edit_item', methods=['POST'])
    @auth_req
    def api_edit_item():
        try:
            item_id = request.form.get('item_id', type=int)
            field = request.form.get('field', '').strip()
            value = request.form.get('value', '').strip()

            if not item_id or not field or value == '':
                return jsonify({'success': False, 'error': 'Missing required parameters'})

            success, result = admin_svc.edit_item(item_id, field, value)
            if success:
                return jsonify({'success': True, 'value': result['value']})
            return jsonify({'success': False, 'error': result})
        except Exception as e:
            return jsonify({'success': False, 'error': str(e)})

    @app.route('/api/delete_item', methods=['POST'])
    @auth_req
    def api_delete_item():
        try:
            item_id = request.form.get('item_id', type=int)
            if not item_id:
                return jsonify({'success': False, 'error': 'Missing item_id'})

            success, result = admin_svc.delete_item(item_id)
            if success:
                return jsonify({'success': True, 'message': f'Item {result["template_id"]} deleted'})
            return jsonify({'success': False, 'error': result})
        except Exception as e:
            return jsonify({'success': False, 'error': str(e)})

    @app.route('/api/add_item', methods=['POST'])
    @auth_req
    def api_add_item():
        try:
            inventory_id = request.form.get('inventory_id', type=int)
            template_id = request.form.get('template_id', '').strip()
            stack_size = request.form.get('stack_size', type=int, default=1)
            quality_level = request.form.get('quality_level', type=int, default=0)

            if not inventory_id or not template_id:
                return jsonify({'success': False, 'error': 'Missing inventory_id or template_id'})

            success, result = admin_svc.add_item(inventory_id, template_id, stack_size, quality_level)
            if success:
                return jsonify({'success': True, 'message': 'Item added', 'item_id': result['item_id']})
            return jsonify({'success': False, 'error': result})
        except Exception as e:
            return jsonify({'success': False, 'error': str(e)})

    # Maintenance
    @app.route('/api/maintenance/create_indexes', methods=['POST'])
    def api_create_indexes():
        try:
            success, created, error = admin_svc.create_indexes()
            if success:
                return jsonify({'success': True, 'created': created, 'count': len(created)})
            return jsonify({'success': False, 'error': error})
        except Exception as e:
            return jsonify({'success': False, 'error': str(e)})

    # Delete vehicle
    @app.route('/api/vehicles/<int:vehicle_id>', methods=['DELETE'])
    def delete_vehicle(vehicle_id):
        success, message = vehicle_svc.delete_vehicle(vehicle_id)
        if success:
            return jsonify({'success': True, 'message': message})
        return jsonify({'success': False, 'error': message}), 404 if 'not found' in message.lower() else 500

    # Delete building
    @app.route('/api/buildings/<int:building_id>', methods=['DELETE'])
    def delete_building(building_id):
        conn = db.get_connection()
        if not conn:
            return jsonify({'success': False, 'error': 'Database connection failed'}), 500
        cur = None
        try:
            cur = conn.cursor()
            cur.execute("SET session_replication_role = replica")
            cur.execute("DELETE FROM dune.building_instances WHERE building_id = %s", [building_id])
            cur.execute("DELETE FROM dune.buildings WHERE id = %s RETURNING id", [building_id])
            deleted = cur.fetchone()
            if deleted:
                cur.execute("DELETE FROM dune.actors WHERE id = %s RETURNING id", [building_id])
                conn.commit()
                cur.execute("SET session_replication_role = default")
                return jsonify({'success': True, 'message': f'Building {building_id} deleted'})
            else:
                conn.rollback()
                cur.execute("SET session_replication_role = default")
                return jsonify({'success': False, 'error': 'Building not found'}), 404
        except Exception as e:
            logger.error(f"Failed to delete building {building_id}: {e}")
            try:
                cur.execute("SET session_replication_role = default")
            except Exception:
                pass
            return jsonify({'success': False, 'error': str(e)}), 500
        finally:
            if cur:
                cur.close()
            db.return_connection(conn)

    # Debug endpoints (should be restricted in production)
    @app.route('/api/debug/vehicle_properties/<int:vehicle_id>')
    @auth_req
    def debug_vehicle_properties(vehicle_id):
        try:
            vehicle = db.query("""
                SELECT a.id, a.class, a.properties
                FROM dune.actors a JOIN dune.vehicles v ON a.id = v.id WHERE a.id = %s
            """, [vehicle_id], one=True)
            if not vehicle:
                return jsonify({'error': 'Vehicle not found'}), 404

            props = vehicle.get('properties', {})
            keys = list(props.keys()) if props else []
            damageable = props.get('DamageableActorComponent', {})
            damageable_keys = list(damageable.keys()) if damageable else []
            weapon_comp = props.get('WeaponActorComponent', {})
            weapon_keys = list(weapon_comp.keys()) if weapon_comp else []

            class_key = [k for k in keys if k.startswith('BP_')][0] if [k for k in keys if k.startswith('BP_')] else None
            vehicle_bp = props.get(class_key, {}) if class_key else {}

            def extract_all_keys(d, prefix='', max_depth=3, depth=0):
                if depth >= max_depth:
                    return []
                result = []
                if isinstance(d, dict):
                    for k, v in d.items():
                        result.append(prefix + k)
                        if isinstance(v, dict):
                            result.extend(extract_all_keys(v, prefix + k + '.', max_depth, depth + 1))
                        elif isinstance(v, list) and v and isinstance(v[0], dict):
                            result.append(prefix + k + '[]')
                            result.extend(extract_all_keys(v[0], prefix + k + '[0].', max_depth, depth + 1))
                return result

            all_keys = extract_all_keys(props)[:100]
            relevant = [k for k in all_keys if any(x in k.lower() for x in ['health', 'damage', 'part', 'module', 'component', 'hit', 'armor', 'slot', 'fuel', 'gas', 'energy', 'resource'])]

            return jsonify({
                'id': vehicle_id, 'class': vehicle['class'],
                'all_keys_sample': all_keys[:50], 'relevant_keys': relevant[:30]
            })
        except Exception as e:
            logger.exception("Error fetching vehicle properties")
            return jsonify({'error': str(e)}), 500

    @app.route('/api/debug/vehicle_children/<int:vehicle_id>/')
    @auth_req
    def debug_vehicle_children(vehicle_id):
        try:
            children = db.query("""
                SELECT a.id, a.class, a.map, a.properties
                FROM dune.actors a
                WHERE a.properties::text LIKE %s LIMIT 50
            """, [f'!!act#{vehicle_id}']) or []

            results = []
            for c in children:
                props = c.get('properties', {})
                results.append({
                    'id': c['id'], 'class': c['class'], 'map': c['map'],
                    'keys': list(props.keys())[:15] if props else []
                })
            return jsonify({'vehicle_id': vehicle_id, 'found_children': len(results), 'children': results})
        except Exception as e:
            logger.exception("Error fetching vehicle children")
            return jsonify({'error': str(e)}), 500

    @app.route('/api/debug/vehicle_parts/<int:vehicle_id>')
    @auth_req
    def debug_vehicle_parts(vehicle_id):
        try:
            parts = db.query("""
                SELECT a.id, a.class, a.properties FROM dune.actors
                WHERE a.properties::text LIKE %s LIMIT 100
            """, [f'%!!act#{vehicle_id}%']) or []

            results = []
            for p in parts:
                props = p.get('properties', {})
                current_health = props.get('DamageableActorComponent', {}).get('m_CurrentMaxHealth')
                max_health = props.get('DamageableActorComponent', {}).get('m_TotalMaxHealth')
                results.append({
                    'id': p['id'],
                    'class': p['class'][:100] if p.get('class') else '',
                    'current_health': current_health, 'max_health': max_health
                })

            vehicle = db.query("""
                SELECT a.id, a.class, a.properties FROM dune.actors a
                JOIN dune.vehicles v ON a.id = v.id WHERE a.id = %s
            """, [vehicle_id], one=True)

            return jsonify({
                'vehicle_id': vehicle_id,
                'vehicle_class': vehicle.get('class', '') if vehicle else '',
                'keys': list(vehicle.get('properties', {}).keys()) if vehicle else [],
                'bp_keys': list(vehicle.get('properties', {}).get('BP_MediumOrnithopter_CHOAM_C', {}).keys()) if vehicle else []
            })
        except Exception as e:
            logger.exception("Error fetching vehicle parts")
            return jsonify({'error': str(e)}), 500

    @app.route('/api/debug/list_tables')
    @auth_req
    def list_tables():
        try:
            tables = db.query("""
                SELECT table_name FROM information_schema.tables
                WHERE table_schema = 'dune' ORDER BY table_name
            """) or []
            return jsonify({'tables': [t.get('table_name', '') for t in tables]})
        except Exception as e:
            return jsonify({'error': str(e)}), 500

    @app.route('/api/debug/vehicle_modules/<int:vehicle_id>')
    @auth_req
    def debug_vehicle_modules(vehicle_id):
        try:
            vehicle_modules = db.query("SELECT * FROM dune.vehicle_modules WHERE vehicle_id = %s LIMIT 50", [vehicle_id]) or []
            return jsonify({'vehicle_id': vehicle_id, 'found': len(vehicle_modules), 'modules': vehicle_modules})
        except Exception as e:
            logger.exception("Error fetching vehicle modules")
            return jsonify({'error': str(e)}), 500

    @app.route('/api/debug/vmi/<int:vehicle_id>')
    @auth_req
    def debug_vmi(vehicle_id):
        try:
            invs = db.query("SELECT * FROM dune.vehicle_module_inventories WHERE vehicle_id = %s LIMIT 10", [vehicle_id])
            return jsonify({'data': invs})
        except Exception as e:
            return jsonify({'error': str(e)[:100]})

    @app.route('/api/debug/vm_schema')
    @auth_req
    def debug_vm_schema():
        try:
            cols = db.query("""
                SELECT column_name, data_type FROM information_schema.columns
                WHERE table_name = 'vehicle_modules' AND table_schema = 'dune'
                ORDER BY ordinal_position
            """) or []
            return jsonify({'columns': cols})
        except Exception as e:
            return jsonify({'error': str(e)}), 500

    @app.route('/api/debug/vm_stats/<int:vehicle_id>')
    @auth_req
    def debug_vm_stats(vehicle_id):
        try:
            modules = db.query("SELECT id, template_id, stats FROM dune.vehicle_modules WHERE vehicle_id = %s", [vehicle_id]) or []
            results = []
            for m in modules:
                stats = m.get('stats', {})
                durability = stats.get('FVehicleModuleDurabilityStats', [{}])[1] if stats.get('FVehicleModuleDurabilityStats') else {}
                results.append({
                    'id': m['id'], 'template': m['template_id'],
                    'durability_keys': list(durability.keys()) if durability else [],
                    'durability': durability
                })
            return jsonify({'vehicle_id': vehicle_id, 'modules': results})
        except Exception as e:
            return jsonify({'error': str(e)}), 500

    @app.route('/api/debug/vehicle_row/<int:vehicle_id>')
    @auth_req
    def debug_vehicle_row(vehicle_id):
        try:
            v = db.query("SELECT * FROM dune.vehicles WHERE id = %s", [vehicle_id], one=True)
            return jsonify({'vehicle': v})
        except Exception as e:
            return jsonify({'error': str(e)}), 500

    @app.route('/api/debug/module_tables')
    @auth_req
    def debug_module_tables():
        try:
            tables = db.query("""
                SELECT table_name FROM information_schema.tables
                WHERE table_schema = 'dune' AND (table_name LIKE '%module%' OR table_name LIKE '%vehicle%')
                ORDER BY table_name
            """) or []
            return jsonify({'tables': [t.get('table_name', '') for t in tables]})
        except Exception as e:
            return jsonify({'error': str(e)}), 500

    # File browser
    FILEBROWSER_BASE_PATH = '/srv'

    def _validate_fb_path(path):
        """Validate filebrowser path is within allowed directory."""
        import posixpath
        normalized = posixpath.normpath(path)
        if not normalized.startswith(FILEBROWSER_BASE_PATH):
            return False
        if '..' in path or '\x00' in path:
            return False
        return True

    def _get_fb_pod():
        """Get the FileBrowser pod name dynamically."""
        pod = k8s.find_pod_by_pattern('fb-deploy')
        return pod

    def _fb_exec(command, timeout=10):
        """Execute kubectl exec in the FileBrowser pod with correct namespace placement."""
        pod = _get_fb_pod()
        if not pod:
            return '', 'FileBrowser pod not found', 1
        full_cmd = f'sudo kubectl exec {pod} -n {k8s.namespace} -- {command}'
        return k8s.ssh.run(full_cmd, timeout=timeout)

    @app.route('/api/files/list', methods=['POST'])
    def api_files_list():
        path = request.form.get('path', '/srv')
        if not _validate_fb_path(path):
            return jsonify({'success': False, 'error': 'Invalid path: access denied'})
        out, err, rc = _fb_exec(f'ls -la "{path}"', timeout=10)
        if rc != 0:
            return jsonify({'success': False, 'error': err or 'Failed to list directory'})

        files = []
        for line in out.strip().split('\n')[1:]:
            parts = line.split(None, 8)
            if len(parts) >= 9:
                perms = parts[0]
                size = parts[4]
                date = ' '.join(parts[5:8])
                name = parts[8]
                if name in ('.', '..'):
                    continue
                files.append({
                    'name': name,
                    'is_dir': perms.startswith('d'),
                    'size': size if not perms.startswith('d') else '',
                    'perms': perms,
                    'date': date,
                })
        return jsonify({'success': True, 'files': files})

    @app.route('/api/files/view')
    def api_files_view():
        path = request.args.get('path', '')
        if not path:
            return jsonify({'success': False, 'error': 'Missing path'})
        if not _validate_fb_path(path):
            return jsonify({'success': False, 'error': 'Invalid path: access denied'})
        out, err, rc = _fb_exec(f'head -c 100000 "{path}"', timeout=10)
        if rc != 0:
            return jsonify({'success': False, 'error': err or 'Failed to read file'})
        return jsonify({'success': True, 'content': out, 'path': path})

    @app.route('/api/files/save', methods=['POST'])
    @limiter.limit("50 per hour")
    def api_files_save():
        path = request.form.get('path', '')
        content = request.form.get('content', '')
        if not path:
            return jsonify({'success': False, 'error': 'Missing path'})
        if not _validate_fb_path(path):
            return jsonify({'success': False, 'error': 'Invalid path: access denied'})
        import base64
        content_b64 = base64.b64encode(content.encode()).decode()
        out, err, rc = _fb_exec(f'sh -c \'echo {content_b64} | base64 -d > "{path}"\'', timeout=15)
        if rc != 0:
            return jsonify({'success': False, 'error': err or 'Failed to save file'})
        return jsonify({'success': True})

    director_port = settings.get('director', {}).get('port', 32479)
    director_node_port = settings.get('director', {}).get('node_port', 30822)
    director_base = f"http://{settings['server']['host']}:{director_node_port}"
    k8s_ns = settings['kubernetes']['namespace']
    cm_name = f"{k8s_ns}-bgd-conf-cm"

    def _director_request(path, method='GET', data=None, timeout=15, raw_data=False):
        """Execute HTTP request to director service via NodePort."""
        import urllib.request
        url = f"{director_base}{path}"
        if method == 'GET':
            req = urllib.request.Request(url)
        else:
            if raw_data and isinstance(data, str):
                body = data.encode()
            elif data is not None:
                body = json.dumps(data).encode()
            else:
                body = None
            req = urllib.request.Request(url, data=body, headers={'Content-Type': 'application/json'}, method=method)
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return resp.read().decode()

    def _patch_configmap(new_ini_content):
        """Patch the BGD ConfigMap with new director.ini content via base64 pipe."""
        import base64
        cm_out, cm_err, cm_rc = k8s.run(f'get configmap {cm_name} -o json')
        if cm_rc != 0 or not cm_out:
            logger.warning(f"Could not get ConfigMap: {cm_err}")
            return False
        cm = json.loads(cm_out)
        cm['data']['director.ini'] = new_ini_content
        cm_json = json.dumps(cm)
        cm_b64 = base64.b64encode(cm_json.encode()).decode()
        patch_cmd = f'echo {cm_b64} | base64 -d | sudo kubectl apply -f - -n {k8s_ns}'
        out, err, rc = ssh.run(patch_cmd, timeout=15)
        if rc != 0:
            logger.warning(f"ConfigMap patch failed: {err}")
            return False
        return True

    def _update_ini_section(map_name, key_values, remove_section=False):
        """Read ConfigMap INI, modify section, write back."""
        import configparser
        import io
        cm_out, _, cm_rc = k8s.run(f'get configmap {cm_name} -o json')
        if cm_rc != 0 or not cm_out:
            return False
        cm = json.loads(cm_out)
        ini_content = cm['data'].get('director.ini', '')
        cfg = configparser.ConfigParser()
        cfg.read_string(ini_content)
        if remove_section:
            if cfg.has_section(map_name):
                cfg.remove_section(map_name)
        else:
            if not cfg.has_section(map_name):
                cfg.add_section(map_name)
            for key, value in key_values.items():
                if value is not None:
                    cfg.set(map_name, key, str(value))
        buf = io.StringIO()
        cfg.write(buf)
        return _patch_configmap(buf.getvalue())

    # Director API proxy
    @app.route('/api/director/battlegroup')
    def director_battlegroup():
        try:
            logger.info(f"Director request: {director_base}/v0/battlegroup")
            data = _director_request('/v0/battlegroup')
            return data, 200, {'Content-Type': 'application/json'}
        except Exception as e:
            logger.error(f"Director battlegroup error: {e}")
            return jsonify({'success': False, 'error': str(e)}), 500

    @app.route('/api/director/update_config', methods=['POST'])
    def director_update_config():
        try:
            config = request.get_json()
            map_name = config.get('MapName', '')
            result = _director_request('/v0/BattlegroupUpdateServerGroupConfig', method='POST', data=config, timeout=30)

            if map_name:
                kv = {}
                if 'DimensionServerGroupConfig' in config:
                    dcfg = config['DimensionServerGroupConfig']
                    if dcfg.get('playerHardCap') is not None:
                        kv['PlayerHardCap'] = dcfg['playerHardCap']
                    if dcfg.get('minServers') is not None:
                        kv['MinServers'] = dcfg['minServers']
                    if dcfg.get('numExtraServers') is not None:
                        kv['NumExtraServers'] = dcfg['numExtraServers']
                    if 'enableAutomaticInstanceScaling' in dcfg:
                        kv['EnableAutomaticInstanceScaling'] = str(dcfg['enableAutomaticInstanceScaling'])
                    if dcfg.get('instanceScalingThrottlingSeconds') is not None:
                        kv['InstanceScalingThrottlingSeconds'] = dcfg['instanceScalingThrottlingSeconds']
                elif 'ClassicalInstancingGroupConfig' in config:
                    icfg = config['ClassicalInstancingGroupConfig']
                    if icfg.get('playerHardCap') is not None:
                        kv['PlayerHardCap'] = icfg['playerHardCap']
                    if icfg.get('minServers') is not None:
                        kv['MinServers'] = icfg['minServers']
                    if icfg.get('numExtraServers') is not None:
                        kv['NumExtraServers'] = icfg['numExtraServers']
                    if 'enableAutomaticInstanceScaling' in icfg:
                        kv['EnableAutomaticInstanceScaling'] = str(icfg['enableAutomaticInstanceScaling'])
                    if icfg.get('instanceScalingThrottlingSeconds') is not None:
                        kv['InstanceScalingThrottlingSeconds'] = icfg['instanceScalingThrottlingSeconds']
                elif 'SingleServerConfig' in config:
                    scfg = config['SingleServerConfig']
                    if scfg.get('playerHardCap') is not None:
                        kv['PlayerHardCap'] = scfg['playerHardCap']
                if kv:
                    _update_ini_section(map_name, kv)

            return result, 200, {'Content-Type': 'application/json'}
        except Exception as e:
            return jsonify({'success': False, 'error': str(e)}), 500

    @app.route('/api/director/clear_config', methods=['POST'])
    def director_clear_config():
        try:
            map_name = request.get_data(as_text=True).strip()
            result = _director_request('/v0/BattlegroupClearMapConfigOverrides', method='POST', data=map_name, timeout=30, raw_data=True)
            if map_name:
                _update_ini_section(map_name, {}, remove_section=True)
            return result, 200, {'Content-Type': 'application/json'}
        except Exception as e:
            return jsonify({'success': False, 'error': str(e)}), 500

    @app.route('/api/director/character_transfer', methods=['GET'])
    def director_character_transfer_get():
        try:
            data = _director_request('/v0/BattlegroupFetchCharacterTransferRules')
            return data, 200, {'Content-Type': 'application/json'}
        except Exception as e:
            return jsonify({'success': False, 'error': str(e)}), 500

    @app.route('/api/director/character_transfer', methods=['POST'])
    def director_character_transfer_update():
        try:
            config = request.get_json()
            result = _director_request('/v0/BattlegroupUpdateCharacterTransferSettings', method='POST', data=config, timeout=30)

            kv = {}
            if 'ForceIsWorldClosed' in config:
                kv['ForceIsWorldClosed'] = str(config['ForceIsWorldClosed'])
            if 'ForceIsWorldClosingSoon' in config:
                kv['ForceIsWorldClosingSoon'] = str(config['ForceIsWorldClosingSoon'])
            if kv:
                _update_ini_section('CharacterTransfers', kv)

            return result, 200, {'Content-Type': 'application/json'}
        except Exception as e:
            return jsonify({'success': False, 'error': str(e)}), 500

    @app.route('/api/director/character_transfer_clear', methods=['POST'])
    def director_character_transfer_clear():
        try:
            result = _director_request('/v0/BattlegroupClearCharacterTransferOverrides', method='POST', timeout=30)

            _update_ini_section('CharacterTransfers', {}, remove_section=True)

            return result, 200, {'Content-Type': 'application/json'}
        except Exception as e:
            return jsonify({'success': False, 'error': str(e)}), 500

    # Update management
    @app.route('/api/update/status')
    def api_update_status():
        updater = services.get('updater')
        if not updater:
            return jsonify({'available': False})
        return jsonify({
            'available': updater.update_available,
            'status': updater.update_status,
        })

    @app.route('/api/update/apply', methods=['POST'])
    def api_update_apply():
        updater = services.get('updater')
        if not updater:
            return jsonify({'success': False, 'error': 'Updater not available'})
        success, message = updater.apply_update()
        return jsonify({'success': success, 'message': message})

    @app.route('/api/update/test', methods=['POST'])
    def api_update_test():
        """Force show update banner for testing."""
        updater = services.get('updater')
        if updater:
            updater._update_available = True
            return jsonify({'success': True, 'message': 'Update banner triggered'})
        return jsonify({'success': False, 'error': 'Updater not available'})

    @app.route('/api/update/check', methods=['POST'])
    def api_update_check():
        """Force a fresh check against GitHub."""
        updater = services.get('updater')
        if not updater:
            return jsonify({'success': False, 'error': 'Updater not available'})
        updater.check_for_updates()
        return jsonify({
            'available': updater.update_available,
            'status': updater.update_status,
            'local_version': updater._current_sha,
            'remote_version': updater._latest_sha,
        })
