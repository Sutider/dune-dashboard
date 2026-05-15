"""Shared data constants and helpers"""

INVENTORY_TYPE_LABELS = {
    0: 'Main Inventory',
    1: 'Equipped Items',
    5: 'Hotbar',
    12: 'Storage',
    14: 'Recipes',
    15: 'Key Items',
    20: 'Crafting Queue',
    25: 'Schematics',
    27: 'Emotes',
    29: 'Quest Items',
    30: 'Bank',
    31: 'Power Pack Slots',
    32: 'Module Slots',
    33: 'Augment Slots',
}

CURRENCY_ID_LABELS = {
    0: 'Solari Credits',
    1: 'House Script',
    2: 'Spice',
}

GUILD_ROLES = {100: 'Leader', 90: 'Officer', 80: 'Officer', 50: 'Member', 1: 'Member'}

NAV_PAGES = [
    ('/', 'Overview'),
    ('/server', 'Server'),
    ('/director', 'Director'),
    ('/shell', 'Shell'),
    ('/files', 'Files'),
    ('/events', 'Events'),
    ('/chat', 'Chat'),
    ('/players', 'Players'),
    ('/vehicles', 'Vehicles'),
    ('/guilds', 'Guilds'),
    ('/buildings', 'Buildings'),
    ('/map', 'Map'),
]
