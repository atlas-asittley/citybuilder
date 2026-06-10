"""Tests for pollution v1.

Each player's tiles get pollution accumulated from active+staffed
production buildings within radius. Parks dampen (negative emit,
always count). Re-derived each tick.
"""
import pytest


def _force_staff_then_pollute(cur, player_id):
    """Bypass process_production's population clamp by staffing directly,
    then computing pollution. Standalone path for unit tests — production
    does the same two phases, but population is clamped to housing_supply
    so we can't just pop=200 and hope."""
    cur.execute("SELECT public._pp_staff_buildings(%s::uuid, 200)", (str(player_id),))
    cur.execute("SELECT public._pp_update_pollution(%s)", (str(player_id),))


def _get_pollution(cur, player_id, x, y):
    cur.execute("""SELECT pollution FROM public.map_tiles
                   WHERE owner_player_id = %s AND x = %s AND y = %s""",
                (str(player_id), x, y))
    row = cur.fetchone()
    return float(row[0]) if row else 0


def test_clean_district_has_zero_pollution(make_player, cur, clear_resources):
    p = make_player(industry='timber')
    clear_resources(p['id'])
    cur.execute("SELECT public._pp_update_pollution(%s)", (str(p['id']),))
    cur.execute("""SELECT MAX(pollution) FROM public.map_tiles WHERE owner_player_id = %s""",
                (str(p['id']),))
    assert cur.fetchone()[0] == 0


def test_extractor_emits_to_nearby_tiles(make_player, place, cur, clear_resources):
    p = make_player(industry='timber')
    clear_resources(p['id'])
    hx, hy = p['home_x'], p['home_y']
    place('timber_camp', hx + 1, hy - 1)
    _force_staff_then_pollute(cur, p['id'])

    # timber_camp emits 2 within radius 2 — adjacent tiles should be 2
    nearby = _get_pollution(cur, p['id'], hx + 1, hy)
    far    = _get_pollution(cur, p['id'], hx + 1, hy - 6)  # well outside radius
    assert nearby == 2, f"adjacent tile should pick up extractor's emit; got {nearby}"
    assert far == 0, f"far tile should not pick up emit; got {far}"


def test_smelter_emits_heavily(make_player, place, cur, clear_resources):
    p = make_player(industry='iron')
    clear_resources(p['id'])
    hx, hy = p['home_x'], p['home_y']
    place('iron_mine', hx + 1, hy - 1)
    place('smelter', hx + 1, hy + 1)
    _force_staff_then_pollute(cur, p['id'])

    # iron_mine emits 2/r2; smelter emits 10/r4. A tile in BOTH ranges
    # gets the sum.
    overlap = _get_pollution(cur, p['id'], hx + 1, hy)
    assert overlap == 12, f"overlap of mine(2) + smelter(10) = 12; got {overlap}"


def test_park_dampens_pollution(make_player, place, cur, clear_resources):
    p = make_player(industry='timber')
    clear_resources(p['id'])
    hx, hy = p['home_x'], p['home_y']

    place('timber_camp', hx + 1, hy - 1)  # emits 2 within r2
    place('park', hx + 1, hy + 1)         # dampens 8 within r3
    _force_staff_then_pollute(cur, p['id'])

    # Tile at (hx+1, hy) is within both. emit + dampen = 2 - 8 = -6, clamped to 0.
    val = _get_pollution(cur, p['id'], hx + 1, hy)
    assert val == 0, f"park should dampen extractor's emit to 0; got {val}"


def test_unstaffed_source_does_not_pollute(make_player, place, cur, clear_resources):
    """A timber_camp without workers shouldn't emit. Pass a tiny supply
    to _pp_staff_buildings so the camp doesn't get staffed."""
    p = make_player(industry='timber')
    clear_resources(p['id'])
    hx, hy = p['home_x'], p['home_y']
    place('timber_camp', hx + 1, hy - 1)

    # Staff with supply=0 → camp can't be staffed. Then compute pollution.
    cur.execute("SELECT public._pp_staff_buildings(%s::uuid, 0)", (str(p['id']),))
    cur.execute("SELECT public._pp_update_pollution(%s)", (str(p['id']),))
    val = _get_pollution(cur, p['id'], hx + 1, hy)
    assert val == 0, f"unstaffed extractor shouldn't pollute; got {val}"


def test_park_works_without_staffing(make_player, place, cur, clear_resources):
    """Parks don't have worker_cost so they're never in the staffed list — but
    pollution dampening should still apply (gated on emit < 0)."""
    p = make_player(industry='timber')
    clear_resources(p['id'])
    hx, hy = p['home_x'], p['home_y']
    place('park', hx + 5, hy + 5)
    cur.execute("""UPDATE public.map_tiles SET pollution = 50
                   WHERE owner_player_id = %s AND x = %s AND y = %s""",
                (str(p['id']), hx + 5, hy + 6))
    cur.execute("SELECT public._pp_staff_buildings(%s::uuid, 0)", (str(p['id']),))
    cur.execute("SELECT public._pp_update_pollution(%s)", (str(p['id']),))
    val = _get_pollution(cur, p['id'], hx + 5, hy + 6)
    # No emit sources, only the park dampening. Pollution clamped to 0.
    assert val == 0, f"park should reset polluted tile; got {val}"
