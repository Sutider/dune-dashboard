"""Main route blueprints"""

import json
import logging
from flask import Blueprint, render_template, request, jsonify
from flask_login import login_required, current_user
from app.utils.constants import NAV_PAGES, GUILD_ROLES

logger = logging.getLogger(__name__)


def register_routes(app, services, settings):
    db = services['db']
    ssh = services['ssh']
    k8s = services['k8s']
    player_svc = services['player']
    vehicle_svc = services['vehicle']
    chat_svc = services['chat']
    static_cache = services['static_cache']

    def fmt_role(role_id):
        return GUILD_ROLES.get(role_id, f'Role {role_id}')

    def get_static_data():
        current_time = __import__('datetime').datetime.now().timestamp()
        cached = static_cache.get('static_data')
        if cached and (current_time - cached['timestamp']) < settings['cache']['static_data_ttl']:
            return cached

        data = {
            'factions': db.query("SELECT id, name FROM dune.factions ORDER BY id") or [],
            'guilds': db.query("SELECT guild_id, guild_name FROM dune.guilds ORDER BY guild_name") or [],
            'maps': db.query("SELECT DISTINCT map FROM dune.actors WHERE class LIKE %s AND map IS NOT NULL ORDER BY map", ['%DunePlayerCharacter_C']) or [],
            'keystones': db.query("SELECT id, name FROM dune.specialization_keystones_map ORDER BY id") or [],
            'timestamp': current_time,
        }
        static_cache.set('static_data', data)
        logger.info("Static data cache refreshed")
        return data

    @app.context_processor
    def inject_globals():
        conn_ok = db.check_health()
        return dict(
            nav_pages=NAV_PAGES,
            current_path=request.path if request else '/',
            fmt_role=fmt_role,
            conn_ok=conn_ok,
            current_user=current_user,
        )

    @app.template_filter('inv_label')
    def inv_label_filter(inv_type):
        from app.utils.constants import INVENTORY_TYPE_LABELS
        if inv_type is None:
            return 'Unknown'
        return INVENTORY_TYPE_LABELS.get(inv_type, f'Type {inv_type}')

    @app.template_filter('currency_label')
    def currency_label_filter(currency_id):
        from app.utils.constants import CURRENCY_ID_LABELS
        return CURRENCY_ID_LABELS.get(currency_id, f'Currency {currency_id}')

    @app.template_filter('class_name')
    def class_name_filter(s):
        if not s:
            return ''
        short = s.split('/')[-1] if '/' in s else s
        if short.endswith('_C'):
            short = short[:-2]
        if '.' in short:
            short = short.split('.')[-1]
        return short

    @app.template_filter('truncate')
    def truncate_filter(s, length=100):
        if s and len(s) > length:
            return s[:length] + '...'
        return s or ''

    @app.template_filter('json_format')
    def json_format_filter(val):
        if val is None:
            return ''
        if isinstance(val, dict):
            return json.dumps(val, indent=2, ensure_ascii=False)
        return str(val)

    @app.template_filter('format_number')
    def format_number_filter(val):
        if val is None:
            return '0'
        try:
            n = int(val)
            return f'{n:,}'
        except (ValueError, TypeError):
            return str(val)

    # Health check
    @app.route('/health')
    def health_check():
        health = {'status': 'healthy', 'checks': {}}
        port_ok = __import__('socket').socket(__import__('socket').AF_INET, __import__('socket').SOCK_STREAM).connect_ex(('127.0.0.1', settings['database']['port'])) == 0
        health['checks']['ssh_tunnel'] = 'ok' if port_ok else 'down'
        if not port_ok:
            health['status'] = 'degraded'
            health['checks']['database'] = 'unknown'
            return jsonify(health), 503

        if db.check_health():
            health['checks']['database'] = 'ok'
        else:
            health['status'] = 'unhealthy'
            health['checks']['database'] = 'connection failed'
            return jsonify(health), 503
        return jsonify(health)

    # Overview
    @app.route('/')
    @login_required
    def overview():
        try:
            counts = player_svc.get_overview_counts()
            data = {
                'faction_dist': player_svc.get_faction_distribution(),
                'per_map': player_svc.get_players_per_map(),
                'players_online': player_svc.get_players_online(),
            }
            data.update(counts or {})
            return render_template('overview.html', **data)
        except Exception as e:
            logger.exception("Error in overview route")
            return render_template('overview.html', db_error=f"{type(e).__name__}: {e}")

    # Players list
    @app.route('/players')
    @login_required
    def players():
        try:
            search = request.args.get('search', '')
            faction_id = request.args.get('faction', '')
            guild_id = request.args.get('guild', '')
            map_filter = request.args.get('map', '')
            online_filter = request.args.get('online', '')

            players_list = player_svc.get_players_list(
                search=search, faction_id=faction_id, guild_id=guild_id,
                map_filter=map_filter, online_filter=online_filter
            )

            static_data = get_static_data()
            return render_template('players.html',
                players=players_list, factions=static_data['factions'],
                guilds=static_data['guilds'], maps=static_data['maps'],
                search=search, sel_faction=faction_id, sel_guild=guild_id,
                sel_map=map_filter, sel_online=online_filter)
        except Exception as e:
            logger.exception("Error in players route")
            return render_template('players.html', db_error=f"{type(e).__name__}: {e}")

    # Player detail
    @app.route('/players/<int:player_id>')
    @login_required
    def player_detail(player_id):
        try:
            player = player_svc.get_player_detail(player_id)
            if not player:
                return render_template('player_detail.html', not_found=True)

            player_controller_id = player.get('player_controller_id')

            vitals = player_svc.get_player_vitals(player.get('state_pawn_id'))
            guild = player_svc.get_player_guild(player_controller_id)
            player_vehicles = player_svc.get_player_vehicles(player_controller_id)
            buildings_result = player_svc.get_player_buildings(player_id)
            currency = player_svc.get_player_currency(player_controller_id)
            inventories = player_svc.get_player_inventories(player_id)
            landclaims = player_svc.get_player_landclaims(player.get('owner_account_id'))
            specialization = player_svc.get_player_specialization(player_controller_id)
            tech_knowledge = player_svc.get_player_tech_knowledge(player_id)
            purchased_keystones = player_svc.get_player_keystones(player_controller_id)
            faction_reputation = player_svc.get_player_faction_reputation(player_controller_id)
            landsraad_info = player_svc.get_player_landsraad(player_controller_id)

            is_online = player_svc.is_online(player_controller_id) if player_controller_id else False

            static_data = get_static_data()

            return render_template('player_detail.html',
                player=player, guild=guild, vehicles=player_vehicles,
                buildings=buildings_result, currency=currency,
                inventories=inventories, landclaims=landclaims,
                specialization=specialization, tech_knowledge=tech_knowledge,
                purchased_keystones=purchased_keystones, all_keystones=static_data['keystones'],
                faction_reputation=faction_reputation, landsraad_info=landsraad_info,
                vitals=vitals, is_online=is_online)
        except Exception as e:
            logger.exception("Error in player_detail route")
            return render_template('player_detail.html', db_error=f"{type(e).__name__}: {e}")

    # Vehicles
    @app.route('/vehicles')
    @login_required
    def vehicles():
        try:
            vehicles_list = vehicle_svc.get_all_vehicles()
            return render_template('vehicles.html', vehicles=vehicles_list)
        except Exception as e:
            logger.exception("Error in vehicles route")
            return render_template('vehicles.html', db_error=f"{type(e).__name__}: {e}")

    # Vehicle detail
    @app.route('/vehicles/<int:vehicle_id>')
    @login_required
    def vehicle_detail(vehicle_id):
        try:
            vehicle = vehicle_svc.get_vehicle(vehicle_id)
            if not vehicle:
                return render_template('vehicle_detail.html', not_found=True)

            modules = vehicle_svc.get_vehicle_modules(vehicle_id)
            from app.services.vehicle import parse_vehicle_modules
            parsed_modules = parse_vehicle_modules(modules, vehicle.get('class', ''))

            return render_template('vehicle_detail.html', vehicle=vehicle, modules=parsed_modules)
        except Exception as e:
            logger.exception("Error in vehicle_detail route")
            return render_template('vehicle_detail.html', db_error=f"{type(e).__name__}: {e}")

    # Guilds
    @app.route('/guilds')
    @login_required
    def guilds():
        try:
            guilds_list = db.query("""
                SELECT g.*, f.name as faction_name,
                    (SELECT COUNT(*)::int FROM dune.guild_members gm WHERE gm.guild_id = g.guild_id) as member_count,
                    (SELECT COUNT(*)::int FROM dune.guild_members gm
                        JOIN dune.player_state ps ON gm.player_id = ps.player_controller_id
                        WHERE gm.guild_id = g.guild_id AND ps.online_status::text = 'Online') as online_count
                FROM dune.guilds g
                LEFT JOIN dune.factions f ON g.guild_faction = f.id
                ORDER BY g.guild_name
            """) or []
            return render_template('guilds.html', guilds=guilds_list)
        except Exception as e:
            logger.exception("Error in guilds route")
            return render_template('guilds.html', db_error=f"{type(e).__name__}: {e}")

    # Guild detail
    @app.route('/guilds/<int:guild_id>')
    @login_required
    def guild_detail(guild_id):
        try:
            guild = db.query("""
                SELECT g.*, f.name as faction_name
                FROM dune.guilds g
                LEFT JOIN dune.factions f ON g.guild_faction = f.id
                WHERE g.guild_id = %s
            """, [guild_id], one=True)
            if not guild:
                return render_template('guild_detail.html', not_found=True)

            members = db.query("""
                SELECT ps.player_pawn_id as actor_id, ea.user as account_email, gm.role_id,
                    COALESCE(NULLIF(ps.character_name, ''), NULLIF(acc.funcom_id, ''), 'Character ' || ps.player_pawn_id::text) as player_name,
                    ps.online_status::text as online_status,
                    ps.player_controller_id,
                    pawn_a.map as player_map,
                    CASE WHEN pawn_a.properties->'BP_DunePlayerCharacter_C'->>'m_bIsDriving' = 'True' THEN TRUE ELSE FALSE END as is_driving,
                    vehicle_a.class as driving_vehicle_class
                FROM dune.guild_members gm
                JOIN dune.player_state ps ON gm.player_id = ps.player_controller_id
                JOIN dune.encrypted_accounts ea ON ps.account_id = ea.id
                LEFT JOIN dune.accounts acc ON ea.id = acc.id
                LEFT JOIN dune.actors pawn_a ON ps.player_pawn_id = pawn_a.id
                LEFT JOIN dune.actors vehicle_a ON pawn_a.properties->'BP_DunePlayerCharacter_C'->>'m_CurrentVehicleId' = CONCAT('!!act#', vehicle_a.id::text)
                    AND (pawn_a.properties->'BP_DunePlayerCharacter_C'->>'m_bIsDriving')::boolean = TRUE
                WHERE gm.guild_id = %s
                ORDER BY gm.role_id DESC, player_name
            """, [guild_id]) or []

            return render_template('guild_detail.html', guild=guild, members=members)
        except Exception as e:
            logger.exception("Error in guild_detail route")
            return render_template('guild_detail.html', db_error=f"{type(e).__name__}: {e}")

    # Buildings
    @app.route('/buildings')
    @login_required
    def buildings():
        try:
            buildings_list = db.query("""
                SELECT a.id, a.class, a.map, a.transform::text as transform_text,
                    COALESCE(NULLIF(ps.character_name, ''), NULLIF(ea.platform_name, ''), 'ID:' || b.owner_id::text) as owner_name,
                    (SELECT COUNT(*)::int FROM dune.building_instances bi WHERE bi.building_id = b.id) as instance_count,
                    a.properties->>'m_bIsPowered' as is_powered,
                    a.properties->>'m_PowerLevel' as power_level,
                    a.properties->'PowerComponent'->>'m_PowerGridID' as power_grid_id
                FROM dune.buildings b
                JOIN dune.actors a ON b.id = a.id
                LEFT JOIN dune.player_state ps ON b.owner_id = ps.player_pawn_id
                LEFT JOIN dune.encrypted_accounts ea ON ea.id = (
                    SELECT ps2.account_id FROM dune.player_state ps2 WHERE ps2.player_pawn_id = b.owner_id LIMIT 1
                )
                ORDER BY owner_name
                LIMIT 200
            """) or []
            return render_template('buildings.html', buildings=buildings_list)
        except Exception as e:
            logger.exception("Error in buildings route")
            return render_template('buildings.html', db_error=f"{type(e).__name__}: {e}")

    # Events
    @app.route('/events')
    @login_required
    def events_page():
        game_events = []
        event_logs = []

        def safe_query(table, cols, order_col, limit):
            try:
                return db.query(f"SELECT {cols} FROM {table} ORDER BY {order_col} DESC LIMIT {limit}") or []
            except Exception as e:
                logger.error(f"Error fetching {table}: {e}")
                return []

        try:
            game_events = safe_query("dune.game_events", "*", "universe_time", 50)
        except Exception:
            pass

        try:
            event_logs = safe_query("dune.event_log", "*", "event_time", 100)
        except Exception:
            pass

        return render_template('events.html', game_events=game_events, event_logs=event_logs)

    # Chat
    @app.route('/chat')
    @login_required
    def chat_logs():
        return render_template('chat.html', max_lines=200)

    # Shell
    @app.route('/shell')
    @login_required
    def shell_page():
        pods = []
        ssh_command = ''
        namespace = settings['kubernetes']['namespace']
        try:
            out, err, rc = ssh.run(f'sudo kubectl get pods -n {namespace} -o custom-columns=NAME:.metadata.name,ROLE:.metadata.labels.role,STATUS:.status.phase')
            if out:
                for line in out.strip().split('\n')[1:]:
                    parts = line.split()
                    if len(parts) >= 3:
                        pods.append({'name': parts[0], 'role': parts[1] if parts[1] != '<none>' else '', 'status': parts[2]})

            ssh_key = settings['server'].get('ssh_key')
            if ssh_key:
                ssh_command = f'ssh -i "{ssh_key}" {settings["server"]["user"]}@{settings["server"]["host"]}'
        except Exception:
            pass

        return render_template('shell.html', pods=pods, ssh_command=ssh_command, namespace=namespace)

    # Files (stub)
    @app.route('/files')
    @login_required
    def files_page():
        return render_template('files.html')

    @app.route('/files/view')
    @login_required
    def files_view():
        path = request.args.get('path', '')
        return render_template('file_view.html', path=path)

    # Director
    @app.route('/director')
    @login_required
    def director_page():
        director_port = settings.get('director', {}).get('port', 32479)
        return render_template('director.html', director_port=director_port)

    # Server status
    @app.route('/server')
    @login_required
    def server_status():
        try:
            active_servers = db.query("""
                SELECT server_id, map
                FROM dune.world_partition
                WHERE server_id IS NOT NULL
                ORDER BY map, server_id
            """) or []
            per_map = player_svc.get_players_per_map()
            online_players = db.query(
                "SELECT ps.character_name, a.map, ps.online_status::text as online_status, "
                "ps.life_state::text as life_state, ps.last_login_time, ps.last_avatar_activity "
                "FROM dune.player_state ps "
                "JOIN dune.actors a ON ps.player_pawn_id = a.id "
                "WHERE ps.online_status::text = 'Online' "
                "ORDER BY ps.character_name"
            ) or []
            partitions = db.query("SELECT * FROM dune.world_partition ORDER BY map, partition_id LIMIT 50") or []
            overmap_count = db.query("SELECT COUNT(*) c FROM dune.overmap_players", one=True)
            online_count = db.query("SELECT COUNT(*) c FROM dune.player_state WHERE online_status::text = 'Online'", one=True)

            deployments = k8s.get_deployments()
            node_metrics = k8s.get_node_metrics()

            for p in partitions:
                sid = (p.get('server_id') or '').lower().replace('_', '-')
                p['deployment'] = ''
                mp = (p.get('map') or '').lower().replace('_', '-')

                for d in deployments:
                    short = d.replace('deployment.apps/', '')
                    if sid and sid in short.lower():
                        p['deployment'] = d
                        break
                    if mp and mp in short.lower():
                        p['deployment'] = d
                        break

                if not p['deployment']:
                    mid = '-sg-' + sid
                    for d in deployments:
                        short = d.replace('deployment.apps/', '')
                        if mid in short.lower():
                            p['deployment'] = d
                            break

                if not p['deployment'] and mp:
                    for d in deployments:
                        short = d.replace('deployment.apps/', '')
                        if mp in short.lower() and 'pod' in short.lower():
                            p['deployment'] = d
                            break

            return render_template('server.html',
                active_servers=active_servers, per_map=per_map,
                online_players=online_players, partitions=partitions,
                overmap_count=overmap_count.get('c') if overmap_count else 0,
                online_count=online_count.get('c') if online_count else 0,
                deployments=deployments, deploys_ok=True, ssh_error='',
                node_metrics=node_metrics)
        except Exception as e:
            logger.exception("Error in server_status route")
            return render_template('server.html', db_error=f"{type(e).__name__}: {e}")

    # Map - shows locations of players, vehicles, buildings
    @app.route('/map')
    @login_required
    def map_page():
        try:
            # Get players with coordinates
            players = db.query("""
                SELECT
                    a.id,
                    COALESCE(NULLIF(ps.character_name, ''), 'Unknown') as name,
                    a.map,
                    a.transform
                FROM dune.actors a
                JOIN dune.player_state ps ON a.id = ps.player_pawn_id
                WHERE a.transform IS NOT NULL
                ORDER BY a.map, ps.character_name
            """) or []

            # Get vehicles with coordinates
            vehicles = db.query("""
                SELECT v.id, v.name, a.map, a.transform, a.class
                FROM dune.vehicles v
                JOIN dune.actors a ON v.id = a.id
                WHERE a.transform IS NOT NULL
                ORDER BY a.map, v.name
            """) or []

            # Get buildings with coordinates
            buildings = db.query("""
                SELECT b.id, a.map, a.transform, a.class
                FROM dune.buildings b
                JOIN dune.actors a ON b.id = a.id
                WHERE a.transform IS NOT NULL
                ORDER BY a.map
                LIMIT 200
            """) or []

            # Parse coordinates from transform field
            def parse_transform(t):
                if not t:
                    return None
                try:
                    # Format: ("(x,y,z)","(x,y,z,w)")
                    import re
                    pos_match = re.search(r'\(([0-9.e+-]+),([0-9.e+-]+),([0-9.e+-]+)\)', str(t))
                    if pos_match:
                        return {
                            'x': float(pos_match.group(1)),
                            'y': float(pos_match.group(2)),
                            'z': float(pos_match.group(3))
                        }
                except Exception:
                    pass
                return None

            # Process players
            player_locations = []
            for p in players:
                coords = parse_transform(p.get('transform'))
                if coords:
                    player_locations.append({
                        'id': p['id'],
                        'name': p['name'],
                        'map': p['map'],
                        'x': coords['x'],
                        'y': coords['y'],
                        'z': coords['z']
                    })

            # Process vehicles
            vehicle_locations = []
            for v in vehicles:
                coords = parse_transform(v.get('transform'))
                if coords:
                    vehicle_locations.append({
                        'id': v['id'],
                        'name': v.get('name', 'Unknown'),
                        'map': v['map'],
                        'class': v.get('class', '').split('/')[-1] if v.get('class') else '',
                        'x': coords['x'],
                        'y': coords['y'],
                        'z': coords['z']
                    })

            # Process buildings
            building_locations = []
            for b in buildings:
                coords = parse_transform(b.get('transform'))
                if coords:
                    building_locations.append({
                        'id': b['id'],
                        'map': b['map'],
                        'class': b.get('class', '').split('/')[-1] if b.get('class') else '',
                        'x': coords['x'],
                        'y': coords['y'],
                        'z': coords['z']
                    })

            # Get unique maps
            all_maps = set()
            for loc in player_locations + vehicle_locations + building_locations:
                if loc.get('map'):
                    all_maps.add(loc['map'])
            maps = sorted(all_maps)

            return render_template('map.html',
                players=player_locations,
                vehicles=vehicle_locations,
                buildings=building_locations,
                maps=maps)
        except Exception as e:
            logger.exception("Error in map route")
            return render_template('map.html', db_error=f"{type(e).__name__}: {e}")
