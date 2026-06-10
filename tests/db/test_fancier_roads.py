"""Regression tests for fancier_roads.sql (Civic Metrics Expansion — Phase 3).

Roads layer on waste's _pp_update_desirability, and neither is live yet, so this
module applies BOTH migrations (waste first, then roads) into the session's outer
transaction once; conftest rolls it back at session end. Idempotent once live.
"""
import os
import re
import pytest

WASTE = os.path.expanduser("~/citybuilder/city-builder-mvp/migration_patches/waste_management.sql")
ROADS = os.path.expanduser("~/citybuilder/city-builder-mvp/migration_patches/fancier_roads.sql")


@pytest.fixture(scope="module", autouse=True)
def _apply_migrations(conn):
    c = conn.cursor()
    for path in (WASTE, ROADS):   # roads redefines _pp_update_desirability on top of waste
        sql = re.sub(r'(?im)^\s*(BEGIN|COMMIT)\s*;\s*$', '', open(path).read())
        c.execute(sql)
    c.close()
    yield


def _desir(cur, uid, x, y):
    cur.execute("""SELECT desirability FROM public.map_tiles
                   WHERE owner_player_id = %s AND x = %s AND y = %s""", (str(uid), x, y))
    row = cur.fetchone()
    return float(row[0]) if row else None


# ───────────────────────────────────────────────────────────
# Catalog / schema
# ───────────────────────────────────────────────────────────

def test_schema_and_roads_exist(cur):
    cur.execute("SELECT 1 FROM information_schema.columns WHERE table_name='building_types' AND column_name='road_tier'")
    assert cur.fetchone(), "building_types.road_tier missing"

    cur.execute("""SELECT key, category, road_tier, desirability_bonus, desirability_radius
                   FROM public.building_types
                   WHERE key IN ('paved_road','tiled_avenue','grand_boulevard') ORDER BY road_tier""")
    rows = cur.fetchall()
    assert [r[0] for r in rows] == ['paved_road', 'tiled_avenue', 'grand_boulevard']
    assert all(r[1] == 'road' for r in rows), "fancy roads must stay category='road'"
    assert [r[2] for r in rows] == [2, 3, 4]
    assert [r[3] for r in rows] == [2, 4, 6]            # desirability_bonus

    cur.execute("SELECT pollution_emit FROM public.building_types WHERE key='grand_boulevard'")
    assert float(cur.fetchone()[0]) == -3, "grand boulevard should dampen pollution"


def test_grand_boulevard_costs_the_art_capstones(cur):
    cur.execute("""SELECT resource_key, quantity FROM public.building_type_resource_costs
                   WHERE building_type_key='grand_boulevard' ORDER BY resource_key""")
    costs = {r[0]: r[1] for r in cur.fetchall()}
    assert costs == {'cabinets': 1, 'monuments': 1, 'mosaics': 1}, \
        f"grand boulevard should sink the three art capstones, got {costs}"


# ───────────────────────────────────────────────────────────
# Connectivity: fancy roads ARE roads
# ───────────────────────────────────────────────────────────

def test_paved_road_provides_road_access(cur, make_player, place, clear_resources):
    p = make_player(industry='timber', population=100)
    clear_resources(p['id'])
    hx, hy = p['home_x'], p['home_y']

    # Paved road adjacent to the existing cross (connectivity rule satisfied).
    place('paved_road', hx + 1, hy + 1)
    # A tile whose ONLY road neighbour is that paved road.
    cur.execute("SELECT public.has_road_access(%s, %s, %s)", (str(p['id']), hx + 2, hy + 1))
    assert cur.fetchone()[0] is True, "a paved road must grant road access like any road"


def test_fancy_road_obeys_road_connectivity_rule(cur, make_player, place, clear_resources, tile_id_at):
    """A fancy road, like any road, must connect to an existing road."""
    p = make_player(industry='timber', population=100)
    clear_resources(p['id'])
    hx, hy = p['home_x'], p['home_y']
    # Far from the cross, no adjacent road → placement should be rejected.
    tid = tile_id_at(hx + 5, hy + 5)
    cur.execute("SAVEPOINT iso")
    failed = False
    try:
        cur.execute("SELECT public.place_building(%s, 'tiled_avenue')", (tid,))
        res = cur.fetchone()[0]
        if isinstance(res, dict) and res.get('error'):
            failed = True
    except Exception:
        failed = True
    cur.execute("ROLLBACK TO SAVEPOINT iso")
    assert failed, "disconnected fancy road should be rejected by the road connectivity rule"


# ───────────────────────────────────────────────────────────
# Desirability aura (unstaffed road bypass)
# ───────────────────────────────────────────────────────────

def test_paved_road_raises_nearby_desirability(cur, make_player, place, clear_resources):
    p = make_player(industry='timber', population=100)
    clear_resources(p['id'])
    hx, hy = p['home_x'], p['home_y']
    tx, ty = hx + 2, hy + 2   # the tile we'll watch (within r1 of a road at hx+1,hy+1)

    cur.execute("SELECT public._pp_update_desirability(%s)", (str(p['id']),))
    base = _desir(cur, p['id'], tx, ty)

    place('paved_road', hx + 1, hy + 1)   # +2 desirability, radius 1, never staffed
    cur.execute("SELECT public._pp_update_desirability(%s)", (str(p['id']),))
    after = _desir(cur, p['id'], tx, ty)

    assert after - base == 2, f"paved road should lift adjacent desirability by 2, got {after - base}"


def test_higher_tier_road_gives_bigger_aura(cur, make_player, place, clear_resources):
    p = make_player(industry='timber', population=100)
    clear_resources(p['id'])
    hx, hy = p['home_x'], p['home_y']
    tx, ty = hx + 2, hy + 2

    cur.execute("SELECT public._pp_update_desirability(%s)", (str(p['id']),))
    base = _desir(cur, p['id'], tx, ty)

    place('tiled_avenue', hx + 1, hy + 1)   # +4, radius 2
    cur.execute("SELECT public._pp_update_desirability(%s)", (str(p['id']),))
    after = _desir(cur, p['id'], tx, ty)

    assert after - base == 4, f"tiled avenue should lift desirability by 4, got {after - base}"
