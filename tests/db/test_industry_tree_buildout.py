"""Tests for the symmetric industry-tree buildout.

Locks: clay_pit / pottery_kiln → clay; mill / bakery → iron.
New buildings:
  smelter      iron T2  (iron → iron_ingot)
  toolmaker    iron T3  (iron_ingot → tools)
  tile_maker   clay T3  (pottery → tiles)
  winery       timber food T2 (berries → wine)
  smokehouse   stone food T2  (fish → smoked_fish)
  cannery      clay food T2   (vegetables → preserves)

Each industry now has the same shape: T1 extractor + T2 processor + T3
processor + T1 food extractor + T2 food processor (+ T3 for iron).
"""
import psycopg2
import pytest


# ── industry locks ───────────────────────────────────────────

@pytest.mark.parametrize("building_key,industry", [
    ('clay_pit',     'clay'),
    ('pottery_kiln', 'clay'),
    ('mill',         'iron'),
    ('bakery',       'iron'),
])
def test_existing_industry_locks(building_key, industry, cur):
    cur.execute("SELECT industry_key FROM building_types WHERE key = %s", (building_key,))
    assert cur.fetchone()[0] == industry, \
        f"{building_key} should be locked to industry={industry}"


def test_stone_player_cannot_build_pottery_kiln(make_player, place, cur, clear_resources):
    """pottery_kiln was 'common'; now locked to clay."""
    p = make_player(industry='stone')
    clear_resources(p['id'])
    hx, hy = p['home_x'], p['home_y']
    try:
        place('pottery_kiln', hx + 1, hy + 1)
        assert False, "should have raised"
    except psycopg2.errors.RaiseException as e:
        assert 'industry' in str(e).lower()


def test_timber_player_cannot_build_mill(make_player, place, cur, clear_resources):
    """mill was 'common'; now locked to iron (grain → flour, iron's chain)."""
    p = make_player(industry='timber')
    clear_resources(p['id'])
    hx, hy = p['home_x'], p['home_y']
    try:
        place('mill', hx + 1, hy + 1)
        assert False, "should have raised"
    except psycopg2.errors.RaiseException as e:
        assert 'industry' in str(e).lower()


# ── new buildings: industry filter ───────────────────────────

@pytest.mark.parametrize("industry,allowed", [
    ('iron',   ['smelter', 'toolmaker']),
    ('clay',   ['tile_maker', 'cannery']),
    ('timber', ['winery']),
    ('stone',  ['smokehouse']),
])
def test_new_buildings_industry_filter(industry, allowed, make_player, place, cur, clear_resources):
    p = make_player(industry=industry)
    clear_resources(p['id'])
    cur.execute("UPDATE public.player_profiles SET money = 5000 WHERE id = %s", (str(p['id']),))
    hx, hy = p['home_x'], p['home_y']
    for i, key in enumerate(allowed):
        result = place(key, hx + 1 + i, hy + 1)
        assert 'building_id' in result, f"{industry} player should be able to build {key}"


@pytest.mark.parametrize("wrong_industry,key", [
    ('timber', 'smelter'),
    ('stone',  'toolmaker'),
    ('clay',   'winery'),
    ('iron',   'smokehouse'),
])
def test_wrong_industry_rejected(wrong_industry, key, make_player, place, cur, clear_resources):
    p = make_player(industry=wrong_industry)
    clear_resources(p['id'])
    hx, hy = p['home_x'], p['home_y']
    try:
        place(key, hx + 1, hy + 1)
        assert False, f"{wrong_industry} should not be able to build {key}"
    except psycopg2.errors.RaiseException as e:
        assert 'industry' in str(e).lower()


# ── new resources are food where appropriate ─────────────────

@pytest.mark.parametrize("resource_key,is_food", [
    ('iron_ingot',  False),
    ('tools',       False),
    ('tiles',       False),
    ('wine',        True),
    ('smoked_fish', True),
    ('preserves',   True),
])
def test_new_resources_food_flag(resource_key, is_food, cur):
    cur.execute("SELECT is_food FROM resources WHERE key = %s", (resource_key,))
    assert cur.fetchone()[0] == is_food


# ── production: smoke-test that one new processor produces ──

def test_winery_produces_wine(make_player, place, cur, clear_resources):
    """Winery: berries → wine. Stock berries, run a tick, expect wine output."""
    p = make_player(industry='timber')
    clear_resources(p['id'])
    cur.execute("UPDATE public.building_types SET worker_cost = 4 WHERE key = 'winery'")
    hx, hy = p['home_x'], p['home_y']
    place('road', hx + 1, hy + 1)  # winery is processor → needs road
    place('winery', hx + 1, hy + 2)
    cur.execute("""INSERT INTO public.inventories (player_id, resource_key, quantity)
                   VALUES (%s, 'berries', 10.0)
                   ON CONFLICT (player_id, resource_key) DO UPDATE SET quantity = 10.0""",
                (str(p['id']),))
    cur.execute("""UPDATE public.buildings
                   SET last_processed_at = now() - interval '60 seconds'
                   WHERE player_id = %s""", (str(p['id']),))
    cur.execute("SELECT public.process_production()")
    cur.execute("SELECT quantity FROM public.inventories WHERE player_id = %s AND resource_key = 'wine'",
                (str(p['id']),))
    wine = float(cur.fetchone()[0])
    # winery: input_rate=2 berries/min, output_rate=1 wine/min
    # in 60s, consumes 2 berries → produces 1 wine
    assert 0.8 < wine < 1.2, f"winery expected ~1 wine after 60s, got {wine}"


def test_smelter_produces_iron_ingot(make_player, place, cur, clear_resources):
    p = make_player(industry='iron')
    clear_resources(p['id'])
    cur.execute("UPDATE public.building_types SET worker_cost = 4 WHERE key = 'smelter'")
    hx, hy = p['home_x'], p['home_y']
    place('road', hx + 1, hy + 1)
    place('smelter', hx + 1, hy + 2)
    cur.execute("""INSERT INTO public.inventories (player_id, resource_key, quantity)
                   VALUES (%s, 'iron', 10.0)
                   ON CONFLICT (player_id, resource_key) DO UPDATE SET quantity = 10.0""",
                (str(p['id']),))
    cur.execute("""UPDATE public.buildings
                   SET last_processed_at = now() - interval '60 seconds'
                   WHERE player_id = %s""", (str(p['id']),))
    cur.execute("SELECT public.process_production()")
    cur.execute("SELECT quantity FROM public.inventories WHERE player_id = %s AND resource_key = 'iron_ingot'",
                (str(p['id']),))
    ingot = float(cur.fetchone()[0])
    # smelter: 1 iron/min → 0.5 ingot/min, so ~0.5 in 60s
    assert 0.4 < ingot < 0.6, f"smelter expected ~0.5 iron_ingot, got {ingot}"


# ── tree symmetry sanity ─────────────────────────────────────

def test_each_industry_has_t1_t2_t3_industry_chain(cur):
    """Every industry should have one extractor (T1), one T2 processor,
    and one T3 processor in its industry chain (not food)."""
    industries = ['timber', 'stone', 'clay', 'iron']
    for ind in industries:
        cur.execute("""SELECT tier, count(*) FROM building_types
                       WHERE industry_key = %s
                         AND category IN ('extractor', 'processor')
                         AND output_resource_key IN (
                           SELECT key FROM resources WHERE NOT is_food)
                       GROUP BY tier ORDER BY tier""", (ind,))
        tiers = {tier: count for tier, count in cur.fetchall()}
        assert 1 in tiers, f"{ind} missing T1 industry building"
        assert 2 in tiers, f"{ind} missing T2 industry building"
        assert 3 in tiers, f"{ind} missing T3 industry building"


def test_each_industry_has_food_chain(cur):
    """Every industry should have a food extractor + at least one food processor."""
    industries = ['timber', 'stone', 'clay', 'iron']
    for ind in industries:
        cur.execute("""SELECT count(*) FROM building_types
                       WHERE industry_key = %s AND category = 'food_extractor'""", (ind,))
        assert cur.fetchone()[0] == 1, f"{ind} missing food extractor"
        cur.execute("""SELECT count(*) FROM building_types
                       WHERE industry_key = %s AND category = 'processor'
                         AND output_resource_key IN (
                           SELECT key FROM resources WHERE is_food)""", (ind,))
        food_processors = cur.fetchone()[0]
        assert food_processors >= 1, f"{ind} missing food processor (got {food_processors})"
