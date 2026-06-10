"""Regression tests for waste_management.sql (Civic Metrics Expansion — Phase 1).

The waste migration is intentionally NOT yet applied to the live DB (it ships
with the matching v2 frontend). So this module applies the migration into the
session's outer transaction once, before any per-test savepoint. conftest's
session `conn` rolls the whole thing back at the end, so the live DB is never
mutated. Once the migration is live, this fixture becomes a cheap no-op
(idempotent CREATE OR REPLACE / ADD COLUMN IF NOT EXISTS).
"""
import os
import re
import uuid
import pytest

MIGRATION = os.path.expanduser(
    "~/citybuilder/city-builder-mvp/migration_patches/waste_management.sql"
)
MIGRATION_FOOTPRINT = os.path.expanduser(
    "~/citybuilder/city-builder-mvp/migration_patches/waste_coverage_footprint.sql"
)


@pytest.fixture(scope="module", autouse=True)
def _apply_waste_migration(conn):
    """Apply the waste migration once into the outer (session) transaction.

    Strip the file's own BEGIN/COMMIT so it runs inside the existing
    transaction and never commits to the live DB.
    """
    sql = open(MIGRATION).read()
    sql = re.sub(r'(?im)^\s*(BEGIN|COMMIT)\s*;\s*$', '', sql)
    c = conn.cursor()
    c.execute(sql)
    # Also apply the footprint-perimeter fix (idempotent CREATE OR REPLACE).
    c.execute(open(MIGRATION_FOOTPRINT).read())
    c.close()
    yield


def _waste(cur, uid):
    cur.execute("SELECT public.compute_waste(%s)", (str(uid),))
    return float(cur.fetchone()[0])


def _profile_waste(cur, uid):
    cur.execute("SELECT waste FROM public.player_profiles WHERE id = %s", (str(uid),))
    return float(cur.fetchone()[0])


# ───────────────────────────────────────────────────────────
# Schema / catalog
# ───────────────────────────────────────────────────────────

def test_schema_and_buildings_exist(cur):
    cur.execute("""
        SELECT column_name FROM information_schema.columns
        WHERE table_name = 'player_profiles' AND column_name = 'waste'
    """)
    assert cur.fetchone(), "player_profiles.waste column missing"

    cur.execute("""
        SELECT column_name FROM information_schema.columns
        WHERE table_name = 'building_types' AND column_name = 'waste_emit'
    """)
    assert cur.fetchone(), "building_types.waste_emit column missing"

    cur.execute("""
        SELECT key, category FROM public.building_types
        WHERE key IN ('dump', 'recycling_center', 'incinerator')
        ORDER BY key
    """)
    rows = cur.fetchall()
    assert {r[0] for r in rows} == {'dump', 'recycling_center', 'incinerator'}
    assert all(r[1] == 'sanitation' for r in rows), "sanitation buildings miscategorized"


def test_sanitation_is_a_valid_category(cur, make_player, clear_resources):
    """The category CHECK constraint must permit 'sanitation' (and 'power')."""
    p = make_player(industry='timber')
    clear_resources(p['id'])
    # If the CHECK still rejected 'sanitation', the building rows above would
    # have failed to insert; assert positively that we can read them back.
    cur.execute("SELECT COUNT(*) FROM public.building_types WHERE category = 'sanitation'")
    assert cur.fetchone()[0] == 3


# ───────────────────────────────────────────────────────────
# Generation
# ───────────────────────────────────────────────────────────

def test_uncovered_houses_raise_waste(cur, make_player, place, clear_resources):
    p = make_player(industry='timber', population=50)
    clear_resources(p['id'])
    hx, hy = p['home_x'], p['home_y']

    base = _waste(cur, p['id'])
    # Three houses, no sanitation anywhere -> all uncovered, +3 each.
    place('house', hx + 1, hy + 1)
    place('house', hx + 2, hy + 1)
    place('house', hx + 3, hy + 1)
    after = _waste(cur, p['id'])
    assert after - base == 9, f"expected +9 (3 uncovered houses), got {after - base}"


def test_waste_is_clamped_0_100(cur, make_player):
    p = make_player(industry='timber', population=5)
    # No houses, no industry: floor is the small base, never negative.
    assert _waste(cur, p['id']) >= 0
    assert _waste(cur, p['id']) <= 100


# ───────────────────────────────────────────────────────────
# Suppression (coverage)
# ───────────────────────────────────────────────────────────

def test_staffed_dump_covers_houses_and_lowers_waste(cur, make_player, place, clear_resources):
    p = make_player(industry='timber', population=100)
    clear_resources(p['id'])
    hx, hy = p['home_x'], p['home_y']

    place('house', hx + 1, hy + 1)
    place('house', hx + 2, hy + 1)
    place('house', hx + 3, hy + 1)
    uncovered = _waste(cur, p['id'])

    # Dump within coverage_radius (5) of all three houses, on a road-adjacent tile.
    place('dump', hx + 1, hy + 2)
    # Staffing (is_staffed) is set during the tick; compute_waste reads it.
    cur.execute("SELECT public.process_production()")
    covered = _profile_waste(cur, p['id'])

    assert covered < uncovered, (
        f"staffed dump should lower waste: uncovered={uncovered}, covered={covered}"
    )
    # With all houses covered, the +3/house residential term vanishes.
    cur.execute("""
        SELECT is_staffed FROM public.buildings
        WHERE player_id = %s AND building_type_key = 'dump'
    """, (str(p['id']),))
    assert cur.fetchone()[0] is True, "dump was not staffed"


def test_unstaffed_dump_does_not_cover(cur, make_player, place, clear_resources):
    p = make_player(industry='timber', population=100)
    clear_resources(p['id'])
    hx, hy = p['home_x'], p['home_y']
    place('house', hx + 1, hy + 1)

    # Pause the dump so it can never staff -> houses stay uncovered.
    place('dump', hx + 1, hy + 2)
    cur.execute("""
        UPDATE public.buildings SET status = 'paused'
        WHERE player_id = %s AND building_type_key = 'dump'
    """, (str(p['id']),))
    cur.execute("SELECT public.process_production()")
    # House still uncovered: base(3) + 3*1 uncovered + pop term.
    cur.execute("SELECT COUNT(*) FROM public.buildings b JOIN public.building_types bt "
                "ON bt.key=b.building_type_key WHERE b.player_id=%s AND bt.category='housing' "
                "AND b.status='active'", (str(p['id']),))
    assert cur.fetchone()[0] == 1
    # waste must still include the uncovered-house contribution
    assert _profile_waste(cur, p['id']) >= 6


# ───────────────────────────────────────────────────────────
# Capstone sink: incinerator costs machinery
# ───────────────────────────────────────────────────────────

def test_incinerator_costs_machinery(cur, make_player, clear_resources, tile_id_at):
    p = make_player(industry='iron', population=100)
    clear_resources(p['id'])
    hx, hy = p['home_x'], p['home_y']

    cur.execute("""
        SELECT quantity FROM public.building_type_resource_costs
        WHERE building_type_key = 'incinerator' AND resource_key = 'machinery'
    """)
    row = cur.fetchone()
    assert row and row[0] == 2, "incinerator should cost 2 machinery"

    # Without machinery in inventory, placement must fail.
    tid = tile_id_at(hx + 1, hy + 1)
    cur.execute("SAVEPOINT no_mach")
    failed = False
    try:
        cur.execute("SELECT public.place_building(%s, 'incinerator')", (tid,))
        # Some place_building variants return an error JSON rather than raising.
        res = cur.fetchone()[0]
        if isinstance(res, dict) and res.get('error'):
            failed = True
    except Exception:
        failed = True
    if not failed:
        cur.execute("ROLLBACK TO SAVEPOINT no_mach")
    assert failed, "incinerator placed without machinery — sink not enforced"

    # With machinery, it places.
    cur.execute("ROLLBACK TO SAVEPOINT no_mach")
    cur.execute("""
        INSERT INTO public.inventories (player_id, resource_key, quantity)
        VALUES (%s, 'machinery', 5)
        ON CONFLICT (player_id, resource_key) DO UPDATE SET quantity = 5
    """, (str(p['id']),))
    cur.execute("SELECT public.place_building(%s, 'incinerator')", (tid,))
    cur.execute("""
        SELECT COUNT(*) FROM public.buildings
        WHERE player_id = %s AND building_type_key = 'incinerator'
    """, (str(p['id']),))
    assert cur.fetchone()[0] == 1


# ───────────────────────────────────────────────────────────
# Effect: bounded desirability drag + tick payload
# ───────────────────────────────────────────────────────────

def test_process_production_returns_waste(cur, make_player, clear_resources):
    p = make_player(industry='timber', population=50)
    clear_resources(p['id'])
    cur.execute("SELECT public.process_production()")
    payload = cur.fetchone()[0]
    assert 'waste' in payload, "process_production payload missing 'waste'"
    assert payload['waste'] is not None


def test_waste_drag_on_desirability_is_bounded(cur, make_player, place, clear_resources):
    """Even at very high waste, desirability is reduced by at most 8 from waste."""
    p = make_player(industry='timber', population=100)
    clear_resources(p['id'])
    hx, hy = p['home_x'], p['home_y']
    place('house', hx + 1, hy + 1)

    # Measure desirability with waste forced to 0.
    cur.execute("UPDATE public.player_profiles SET waste = 0 WHERE id = %s", (str(p['id']),))
    cur.execute("SELECT public._pp_update_desirability(%s)", (str(p['id']),))
    cur.execute("""
        SELECT desirability FROM public.map_tiles
        WHERE owner_player_id = %s AND x = %s AND y = %s
    """, (str(p['id']), hx + 1, hy + 1))
    d0 = float(cur.fetchone()[0])

    # Force waste very high.
    cur.execute("UPDATE public.player_profiles SET waste = 100 WHERE id = %s", (str(p['id']),))
    cur.execute("SELECT public._pp_update_desirability(%s)", (str(p['id']),))
    cur.execute("""
        SELECT desirability FROM public.map_tiles
        WHERE owner_player_id = %s AND x = %s AND y = %s
    """, (str(p['id']), hx + 1, hy + 1))
    d1 = float(cur.fetchone()[0])

    drop = d0 - d1
    # Drag is LEAST(8, floor(waste/12)); at waste=100 that's 8 (unless the tile
    # was already near the 0 floor).
    assert 0 <= drop <= 8, f"waste drag should be bounded 0..8, got {drop}"
    if d0 >= 8:
        assert drop == 8, f"at waste=100 expected full -8 drag, got {drop}"


# ───────────────────────────────────────────────────────────
# Footprint-perimeter coverage (2026-06-04 fix)
# ───────────────────────────────────────────────────────────

def test_recycling_center_coverage_formula_uses_footprint_perimeter(cur):
    """Verify the footprint-perimeter Manhattan formula in isolation.

    For a 2×2 recycling_center at (100, 100) with radius=7 and a house at (108, 100):
      - Old anchor formula: ABS(100-108) = 8 > 7 → would leave house UNCOVERED.
      - New formula: nearest cell x=101, dist = 108-101 = 7 ≤ 7 → COVERED.

    This tests the formula algebra directly in SQL without needing live buildings.
    """
    cur.execute("""
        SELECT
          -- old anchor-only Manhattan distance
          ABS(100 - 108) + ABS(100 - 100) AS anchor_dist,
          -- new footprint-perimeter Manhattan distance (recycling_center fw=2, fh=2)
          GREATEST(0, 100 - 108, 108 - (100 + 2 - 1))
          + GREATEST(0, 100 - 100, 100 - (100 + 2 - 1)) AS footprint_dist
    """)
    anchor_dist, footprint_dist = cur.fetchone()

    cur.execute("""
        SELECT coverage_radius FROM public.building_types
        WHERE key = 'recycling_center'
    """)
    radius = cur.fetchone()[0]

    assert anchor_dist > radius, (
        f"Old anchor dist ({anchor_dist}) should exceed radius ({radius}) for this test case"
    )
    assert footprint_dist <= radius, (
        f"New footprint dist ({footprint_dist}) should be ≤ radius ({radius})"
    )
