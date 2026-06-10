"""Regression tests for health_education.sql (Civic Metrics Expansion — Phase 5)."""
import os
import re
import pytest

MIG = os.path.expanduser("~/citybuilder/city-builder-mvp/migration_patches")
CHAIN = [f"{MIG}/{f}.sql" for f in
         ("waste_management", "power_energy", "power_energy_brownout",
          "fancier_roads", "noise_congestion", "health_education")]


@pytest.fixture(scope="module", autouse=True)
def _apply_migrations(conn):
    c = conn.cursor()
    for path in CHAIN:
        c.execute(re.sub(r'(?im)^\s*(BEGIN|COMMIT)\s*;\s*$', '', open(path).read()))
    c.close()
    yield


def _set_tier(cur, uid, x, y, tier):
    cur.execute("""UPDATE public.buildings SET housing_tier=%s
                   WHERE player_id=%s AND x=%s AND y=%s""", (tier, str(uid), x, y))


def _staff(cur, uid, key):
    cur.execute("""UPDATE public.buildings SET is_staffed=true
                   WHERE player_id=%s AND building_type_key=%s""", (str(uid), key))


def _education(cur, uid):
    cur.execute("SELECT public.compute_education(%s)", (str(uid),))
    return float(cur.fetchone()[0])


def _health(cur, uid):
    cur.execute("SELECT public.compute_health(%s)", (str(uid),))
    return float(cur.fetchone()[0])


def _productivity(cur, uid):
    cur.execute("SELECT public._pp_compute_productivity(%s)", (str(uid),))
    return float(cur.fetchone()[0])


# ── Schema / catalog ────────────────────────────────────────

def test_schema_and_buildings(cur):
    for col in ('health', 'education'):
        cur.execute("SELECT 1 FROM information_schema.columns WHERE table_name='player_profiles' AND column_name=%s", (col,))
        assert cur.fetchone(), f"player_profiles.{col} missing"
    cur.execute("SELECT 1 FROM information_schema.columns WHERE table_name='housing_tier_config' AND column_name='food_variety_required'")
    assert cur.fetchone()

    cur.execute("SELECT key, category FROM public.building_types WHERE key IN ('clinic','library') ORDER BY key")
    rows = cur.fetchall()
    assert [r[0] for r in rows] == ['clinic', 'library']
    assert all(r[1] == 'service' for r in rows)


def test_food_variety_targets_populated(cur):
    cur.execute("SELECT tier, food_variety_required FROM public.housing_tier_config ORDER BY tier")
    fv = dict(cur.fetchall())
    assert fv[2] == 1 and fv[4] == 2 and fv[6] == 3, f"unexpected food-variety ladder: {fv}"


def test_clinic_consumes_lumber_and_glass(cur):
    cur.execute("""SELECT input_resource_key, input_resource_key_2 FROM public.building_types
                   WHERE key='clinic'""")
    a, b = cur.fetchone()
    assert {a, b} == {'lumber', 'glass'}, "clinic should consume lumber + glass (timber/clay sink)"


# ── Education ───────────────────────────────────────────────

def test_education_tracks_school_and_library_coverage(cur, make_player, place, clear_resources):
    p = make_player(industry='timber', population=100)
    clear_resources(p['id'])
    hx, hy = p['home_x'], p['home_y']
    place('house', hx + 1, hy + 1)
    _set_tier(cur, p['id'], hx + 1, hy + 1, 2)

    assert _education(cur, p['id']) == 0, "no school/library → 0 education"

    place('school', hx + 2, hy + 2)         # 2x2, within Chebyshev 5 of the house
    _staff(cur, p['id'], 'school')
    assert _education(cur, p['id']) == 100, "staffed school covering all housing → 100"

    # A Library covers education just like a school.
    p2 = make_player(industry='timber', population=100)
    clear_resources(p2['id'])
    hx2, hy2 = p2['home_x'], p2['home_y']
    place('house', hx2 + 1, hy2 + 1)
    _set_tier(cur, p2['id'], hx2 + 1, hy2 + 1, 2)
    place('library', hx2 + 2, hy2 + 2)
    _staff(cur, p2['id'], 'library')
    assert _education(cur, p2['id']) == 100, "staffed library should also provide education coverage"


# ── Health ──────────────────────────────────────────────────

def test_health_baseline_without_housing(cur, make_player, clear_resources):
    p = make_player(industry='timber', population=100)
    clear_resources(p['id'])
    assert _health(cur, p['id']) == 50, "no housing, no waste → neutral 50"


def test_clinic_coverage_raises_health(cur, make_player, place, clear_resources):
    p = make_player(industry='timber', population=100)
    clear_resources(p['id'])
    hx, hy = p['home_x'], p['home_y']
    place('house', hx + 1, hy + 1)
    _set_tier(cur, p['id'], hx + 1, hy + 1, 2)
    cur.execute("UPDATE public.player_profiles SET waste=0 WHERE id=%s", (str(p['id']),))

    assert _health(cur, p['id']) == 50, "uncovered housing → baseline 50"
    place('clinic', hx + 2, hy + 2)
    _staff(cur, p['id'], 'clinic')
    assert _health(cur, p['id']) == 80, "full clinic coverage → 50 + 30"


# ── Effects (upside-only health, returns) ───────────────────

def test_high_health_gives_productivity_upside_only(cur, make_player):
    p = make_player(industry='timber', population=100)
    cur.execute("""UPDATE public.player_profiles
                   SET power_capacity=0, power_demand=0, congestion=0 WHERE id=%s""", (str(p['id']),))

    cur.execute("UPDATE public.player_profiles SET health=50 WHERE id=%s", (str(p['id']),))
    base = _productivity(cur, p['id'])
    cur.execute("UPDATE public.player_profiles SET health=80 WHERE id=%s", (str(p['id']),))
    high = _productivity(cur, p['id'])

    assert base == 1.0, "average health → no change"
    assert high == 1.05, "high health → small upside bonus"
    assert high > base


def test_process_production_returns_health_and_education(cur, make_player, clear_resources):
    p = make_player(industry='timber', population=50)
    clear_resources(p['id'])
    cur.execute("SELECT public.process_production()")
    payload = cur.fetchone()[0]
    assert 'health' in payload and 'education' in payload
