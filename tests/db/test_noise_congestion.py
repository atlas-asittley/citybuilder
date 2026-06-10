"""Regression tests for noise_congestion.sql (Civic Metrics Expansion — Phase 4).

Layers on waste → power → brownout. Applied into the session's outer
transaction (rolled back at session end); idempotent once live.
"""
import os
import re
import pytest

MIG = os.path.expanduser("~/citybuilder/city-builder-mvp/migration_patches")
CHAIN = [f"{MIG}/{f}.sql" for f in
         ("waste_management", "power_energy", "power_energy_brownout",
          "fancier_roads", "noise_congestion")]   # congestion uses road_tier from fancier_roads


@pytest.fixture(scope="module", autouse=True)
def _apply_migrations(conn):
    c = conn.cursor()
    for path in CHAIN:
        c.execute(re.sub(r'(?im)^\s*(BEGIN|COMMIT)\s*;\s*$', '', open(path).read()))
    c.close()
    yield


def _noise(cur, uid, x, y):
    cur.execute("SELECT noise FROM public.map_tiles WHERE owner_player_id=%s AND x=%s AND y=%s",
                (str(uid), x, y))
    r = cur.fetchone()
    return float(r[0]) if r else None


def _congestion(cur, uid):
    cur.execute("SELECT congestion FROM public.player_profiles WHERE id=%s", (str(uid),))
    return float(cur.fetchone()[0])


def _productivity(cur, uid):
    cur.execute("SELECT public._pp_compute_productivity(%s)", (str(uid),))
    return float(cur.fetchone()[0])


# ── Schema ──────────────────────────────────────────────────

def test_schema(cur):
    for tbl, col in [('map_tiles', 'noise'), ('building_types', 'noise_emit'),
                     ('building_types', 'noise_radius'), ('player_profiles', 'congestion')]:
        cur.execute("SELECT 1 FROM information_schema.columns WHERE table_name=%s AND column_name=%s",
                    (tbl, col))
        assert cur.fetchone(), f"{tbl}.{col} missing"


# ── Noise (per-tile, toothless on desirability) ─────────────

def test_staffed_processor_emits_noise(cur, make_player, place, clear_resources):
    p = make_player(industry='timber', population=100)
    clear_resources(p['id'])
    hx, hy = p['home_x'], p['home_y']
    place('sawmill', hx + 1, hy + 1)          # processor, noise_emit 3 r2
    cur.execute("SELECT public.process_production()")   # staffs it + computes noise
    assert _noise(cur, p['id'], hx + 2, hy + 1) == 3, "staffed processor should emit noise nearby"


def test_noise_is_toothless_on_desirability(cur, make_player, clear_resources):
    """Noise ships computed-but-toothless: the desirability formula ignores it."""
    p = make_player(industry='timber', population=100)
    clear_resources(p['id'])
    hx, hy = p['home_x'], p['home_y']
    cur.execute("SELECT public._pp_update_desirability(%s)", (str(p['id']),))
    cur.execute("SELECT desirability FROM public.map_tiles WHERE owner_player_id=%s AND x=%s AND y=%s",
                (str(p['id']), hx + 2, hy + 2))
    base = float(cur.fetchone()[0])
    # Force heavy noise on that tile; desirability must not change.
    cur.execute("UPDATE public.map_tiles SET noise=80 WHERE owner_player_id=%s AND x=%s AND y=%s",
                (str(p['id']), hx + 2, hy + 2))
    cur.execute("SELECT public._pp_update_desirability(%s)", (str(p['id']),))
    cur.execute("SELECT desirability FROM public.map_tiles WHERE owner_player_id=%s AND x=%s AND y=%s",
                (str(p['id']), hx + 2, hy + 2))
    assert float(cur.fetchone()[0]) == base, "noise must not affect desirability yet (toothless)"


# ── Congestion (per-player) ─────────────────────────────────

def _compute_congestion(cur, uid):
    cur.execute("SELECT public.compute_congestion(%s)", (str(uid),))
    return float(cur.fetchone()[0])


def test_quiet_city_has_base_congestion(cur, make_player, clear_resources):
    p = make_player(industry='timber', population=50)   # traffic 10 ≤ road capacity (cross)
    clear_resources(p['id'])                            # stamps the road cross
    cur.execute("UPDATE public.player_profiles SET population=50 WHERE id=%s", (str(p['id']),))
    assert _compute_congestion(cur, p['id']) == 5, "an under-trafficked city sits at base congestion"


def test_overloaded_city_congests(cur, make_player, clear_resources):
    p = make_player(industry='timber', population=100)
    clear_resources(p['id'])
    # Heavy population on the small starter road network → traffic >> capacity.
    cur.execute("UPDATE public.player_profiles SET population=400 WHERE id=%s", (str(p['id']),))
    assert _compute_congestion(cur, p['id']) > 40, "heavy traffic on a small road network should congest"


def test_congestion_drag_is_gated_and_bounded(cur, make_player):
    p = make_player(industry='timber', population=100)
    cur.execute("UPDATE public.player_profiles SET power_capacity=0, power_demand=0 WHERE id=%s",
                (str(p['id']),))   # isolate from brownout

    cur.execute("UPDATE public.player_profiles SET congestion=40 WHERE id=%s", (str(p['id']),))
    assert _productivity(cur, p['id']) == 1.0, "congestion <= 40 must not drag"

    cur.execute("UPDATE public.player_profiles SET congestion=90 WHERE id=%s", (str(p['id']),))
    assert _productivity(cur, p['id']) == 0.92, "high congestion drags, floored at -8%"
