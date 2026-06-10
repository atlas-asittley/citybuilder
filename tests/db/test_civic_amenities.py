"""Civic amenities — Public Garden + Monument add per-tile desirability
within their declared Chebyshev radius while staffed. Migration:
desirability_amenities.sql (2026-05-22).
"""
import pytest


def _set_money(cur, player_id, amount):
    cur.execute("UPDATE public.player_profiles SET money=%s WHERE id=%s",
                (amount, str(player_id)))


def _give_lots_of_workers(cur, player_id):
    cur.execute("""UPDATE public.player_profiles
                   SET worker_capacity=100, population=100 WHERE id=%s""",
                (str(player_id),))


def test_public_garden_bumps_tile_desirability_when_staffed(make_player, place, cur, clear_resources):
    """A staffed Public Garden at Chebyshev=0 from a tile adds +5 to that
    tile's desirability."""
    p = make_player()
    clear_resources(p['id'])
    _set_money(cur, p['id'], 100000)
    _give_lots_of_workers(cur, p['id'])
    hx, hy = p['home_x'], p['home_y']

    # Baseline desirability of the test tile (no amenity yet).
    cur.execute("SELECT public._pp_update_desirability(%s)", (str(p['id']),))
    cur.execute("""SELECT desirability FROM public.map_tiles
                   WHERE owner_player_id=%s AND x=%s AND y=%s""",
                (str(p['id']), hx + 4, hy + 4))
    baseline = cur.fetchone()[0]

    # Place + staff a 2x2 Public Garden at (hx+2, hy+3). Top-left corner
    # is (hx+2, hy+3); the building footprint also covers (hx+3, hy+3),
    # (hx+2, hy+4), (hx+3, hy+4). Test tile at (hx+4, hy+4) is
    # Chebyshev=1 from the anchor — within radius 3.
    place('public_garden', hx + 2, hy + 3)
    cur.execute("""UPDATE public.buildings SET is_staffed=true
                   WHERE player_id=%s AND building_type_key='public_garden'""",
                (str(p['id']),))
    cur.execute("SELECT public._pp_update_desirability(%s)", (str(p['id']),))
    cur.execute("""SELECT desirability FROM public.map_tiles
                   WHERE owner_player_id=%s AND x=%s AND y=%s""",
                (str(p['id']), hx + 4, hy + 4))
    after = cur.fetchone()[0]
    assert after - baseline == 5, (
        f'staffed Public Garden should add +5 desirability, got Δ {after - baseline}'
    )


def test_civic_bonus_does_not_apply_when_unstaffed(make_player, place, cur, clear_resources):
    """Same setup but the garden is paused → no desirability bonus."""
    p = make_player()
    clear_resources(p['id'])
    _set_money(cur, p['id'], 100000)
    _give_lots_of_workers(cur, p['id'])
    hx, hy = p['home_x'], p['home_y']

    cur.execute("SELECT public._pp_update_desirability(%s)", (str(p['id']),))
    cur.execute("""SELECT desirability FROM public.map_tiles
                   WHERE owner_player_id=%s AND x=%s AND y=%s""",
                (str(p['id']), hx + 4, hy + 4))
    baseline = cur.fetchone()[0]

    place('public_garden', hx + 2, hy + 3)
    cur.execute("""UPDATE public.buildings SET status='paused', is_staffed=false
                   WHERE player_id=%s AND building_type_key='public_garden'""",
                (str(p['id']),))
    cur.execute("SELECT public._pp_update_desirability(%s)", (str(p['id']),))
    cur.execute("""SELECT desirability FROM public.map_tiles
                   WHERE owner_player_id=%s AND x=%s AND y=%s""",
                (str(p['id']), hx + 4, hy + 4))
    after = cur.fetchone()[0]
    assert after == baseline, (
        f'paused garden should not bump desirability; baseline={baseline}, after={after}'
    )


def test_civic_bonus_decays_outside_radius(make_player, place, cur, clear_resources):
    """Chebyshev distance > desirability_radius gets no bonus."""
    p = make_player()
    clear_resources(p['id'])
    _set_money(cur, p['id'], 100000)
    _give_lots_of_workers(cur, p['id'])
    hx, hy = p['home_x'], p['home_y']

    # The default starter chunk covers x in [0, 14], y in [75, 89]
    # (a 15×15 box). Pick two tiles inside the parcel that are
    # Chebyshev=10 apart — well outside any civic radius. Garden at
    # (hx-5, hy-5) = (2, 77), test tile at (hx+5, hy+5) = (12, 87).
    cur.execute("SELECT public._pp_update_desirability(%s)", (str(p['id']),))
    cur.execute("""SELECT desirability FROM public.map_tiles
                   WHERE owner_player_id=%s AND x=%s AND y=%s""",
                (str(p['id']), hx + 5, hy + 5))
    baseline = cur.fetchone()[0]

    place('public_garden', hx - 5, hy - 5)
    cur.execute("""UPDATE public.buildings SET is_staffed=true
                   WHERE player_id=%s AND building_type_key='public_garden'""",
                (str(p['id']),))
    cur.execute("SELECT public._pp_update_desirability(%s)", (str(p['id']),))
    cur.execute("""SELECT desirability FROM public.map_tiles
                   WHERE owner_player_id=%s AND x=%s AND y=%s""",
                (str(p['id']), hx + 5, hy + 5))
    after = cur.fetchone()[0]
    assert after == baseline, (
        f'tile outside Chebyshev=3 should get 0 bonus; baseline={baseline}, after={after}'
    )


def test_civic_buildings_auto_staff_through_process_production(make_player, place, cur, clear_resources):
    """Regression: 2026-05-22 — `_pp_staff_buildings` had a hardcoded
    category IN(...) list that omitted 'civic', so Public Garden /
    Monument / Marketplace never flipped is_staffed=true, and every
    effect that gates on staffing silently no-op'd.

    This test drives the real staffing path (process_production) — it
    must not hand-set is_staffed.
    """
    p = make_player()
    clear_resources(p['id'])
    _set_money(cur, p['id'], 100000)
    _give_lots_of_workers(cur, p['id'])
    hx, hy = p['home_x'], p['home_y']

    # Place adjacent to the road column (clear_resources stamps a road
    # cross at x=hx and y=hy). 2x2 garden at (hx+1, hy+1) → its left
    # perimeter strip sits on x=hx, satisfying has_road_access.
    place('public_garden', hx + 1, hy + 1)
    # Sanity: a freshly placed civic building starts unstaffed.
    cur.execute("""SELECT is_staffed FROM public.buildings
                   WHERE player_id=%s AND building_type_key='public_garden'""",
                (str(p['id']),))
    assert cur.fetchone()[0] is False

    cur.execute("SELECT public.process_production()")

    cur.execute("""SELECT is_staffed FROM public.buildings
                   WHERE player_id=%s AND building_type_key='public_garden'""",
                (str(p['id']),))
    assert cur.fetchone()[0] is True, (
        'civic building must be staffed after process_production '
        '(check that _pp_staff_buildings includes the civic category)'
    )


def test_monument_requires_tier_5_unlock(make_player, place, cur, clear_resources):
    """Monument is gated behind highest_housing_tier_ever ≥ 5. A fresh
    player whose watermark is 0 cannot place one."""
    p = make_player(unlock_all=False)   # watermark stays at 0
    clear_resources(p['id'])
    _set_money(cur, p['id'], 100000)
    _give_lots_of_workers(cur, p['id'])
    # Also stock the required statuary so we know the failure is on
    # the unlock gate and not the resource cost.
    cur.execute("""INSERT INTO public.inventories (player_id, resource_key, quantity)
                   VALUES (%s, 'statuary', 100)
                   ON CONFLICT (player_id, resource_key) DO UPDATE SET quantity=100""",
                (str(p['id']),))
    hx, hy = p['home_x'], p['home_y']
    import psycopg2
    with pytest.raises(psycopg2.errors.RaiseException) as exc:
        place('monument', hx + 2, hy + 2)
    assert 'locked' in str(exc.value).lower() or 'unlocks' in str(exc.value).lower(), (
        f'expected unlock-gate error, got: {exc.value}'
    )
