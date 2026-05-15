import sys
sys.path.insert(0, '.')
from app.config import load_settings
from app.services.database import DatabaseService

settings = load_settings()
db_config = {
    'host': settings['database']['host'],
    'port': settings['database']['port'],
    'user': settings['database']['user'],
    'password': settings['database']['password'],
    'database': settings['database']['name'],
}
db = DatabaseService(db_config, 2, 10)

# Check sample transform data for players
sample = db.query('''
    SELECT id, class, map, transform FROM dune.actors
    WHERE class LIKE '%DunePlayerCharacter_%'
    LIMIT 3
''')
for s in sample:
    print('Class:', s['class'])
    print('Map:', s['map'])
    print('Transform:', s['transform'][:500] if s['transform'] else 'None')
    print('---')

# Also check vehicles
print('\n=== Vehicles ===')
veh = db.query('''
    SELECT id, class, map, transform FROM dune.actors
    WHERE class LIKE '%Vehicle%'
    LIMIT 2
''')
for v in veh:
    print('Class:', v['class'])
    print('Map:', v['map'])
    print('Transform:', v['transform'][:500] if v['transform'] else 'None')
    print('---')