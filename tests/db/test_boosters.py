"""Tests for production boosters.

8 boosters total — one resource booster + one food booster per industry,
all with boost_multiplier=1.25 (+25%) and boost_range=2 (Manhattan
distance).

Behavior the tests pin:
  - Adjacent extractor / food_extractor gets the boost
  - Out-of-range buildings don't get boosted
  - Wrong-target boosters don't apply (resource booster doesn't boost
    food extractors and vice versa)
  - Booster must be staffed to apply
  - Industry filter on placement
  - Multiple boosters take MAX, not stack
"""
import psycopg2
import pytest


def _cheap_extractors_and_boosters(cur):
    """Bring worker_cost down so a base-capacity (5w) test can staff
    one extractor + one booster (10w + 3w = 13w usually too high)."""
    cur.execute("UPDATE public.building_types SET worker_cost = 1 WHERE category = 'booster'")
    cur.execute("UPDATE public.building_types SET worker_cost = 2 WHERE category IN ('extractor', 'food_extractor')")


# ── industry filter ─────────────────────────────────────────

@pytest.mark.parametrize("industry,allowed", [
    ('timber', ['foresters_office', 'apiary']),
    ('stone',  ['foreman_office',   'hatchery']),
    ('clay',   ['clay_master_hut',  'compost_heap']),
    ('iron',   ['mine_office',      'irrigation_channel']),
])
def test_industry_can_place_its_boosters(industry, allowed, make_player, place, cur, clear_resources):
    p = make_player(industry=industry)
    clear_resources(p['id'])
    cur.execute("UPDATE public.player_profiles SET money = 5000 WHERE id = %s", (str(p['id']),))
    hx, hy = p['home_x'], p['home_y']
    for i, key in enumerate(allowed):
        result = place(key, hx + 1 + i, hy + 1)
        assert 'building_id' in result


def test_timber_player_cannot_place_hatchery(make_player, place, cur, clear_resources):
    p = make_player(industry='timber')
    clear_resources(p['id'])
    hx, hy = p['home_x'], p['home_y']
    try:
        place('hatchery', hx + 1, hy + 1)
        assert False, "should have raised"
    except psycopg2.errors.RaiseException as e:
        assert 'industry' in str(e).lower()


# ── adjacent boost ──────────────────────────────────────────

def test_resource_booster_boosts_adjacent_extractor(make_player, place, cur, clear_resources):
    """Forester's Office adjacent to a Timber Camp should bump its rate by +25%."""
    p = make_player(industry='timber')
    # Don't clear resources — the timber_camp needs an actual timber tile.
    _cheap_extractors_and_boosters(cur)
    cur.execute("UPDATE public.player_profiles SET money = 5000 WHERE id = %s", (str(p['id']),))
    hx, hy = p['home_x'], p['home_y']

    # Place the timber camp on a road-adjacent tile (production now
    # requires road access). The chunk has the highway cross at y=hy
    # and x=hx; find a buildable tile adjacent to that.
    cur.execute("""SELECT mt.x, mt.y FROM public.map_tiles mt
                   WHERE mt.owner_player_id = %s AND mt.buildable
                     AND mt.resource_node_key IS NULL
                     AND mt.terrain_type != 'highway'
                     AND mt.occupied_building_id IS NULL
                     AND EXISTS (
                       SELECT 1 FROM public.buildings r
                       JOIN public.building_types rt ON rt.key = r.building_type_key
                       WHERE rt.category = 'road' AND r.status = 'active'
                         AND r.player_id = mt.owner_player_id
                         AND ((r.x = mt.x - 1 AND r.y = mt.y) OR (r.x = mt.x + 1 AND r.y = mt.y)
                            OR (r.x = mt.x AND r.y = mt.y - 1) OR (r.x = mt.x AND r.y = mt.y + 1))
                     )
                   LIMIT 1""", (str(p['id']),))
    bx, by = cur.fetchone()
    place('timber_camp', bx, by)
    # Booster goes on an adjacent (road-bordered) tile. Wipe any
    # resource that happened to seed there. We can't be picky about the
    # specific tile; if (bx+1, by) isn't road-adjacent, place a road
    # there to give it access.
    cur.execute("UPDATE public.map_tiles SET resource_node_key = NULL WHERE x = %s AND y = %s",
                (bx + 1, by))
    cur.execute("""SELECT 1 FROM public.buildings r
                   JOIN public.building_types rt ON rt.key = r.building_type_key
                   WHERE rt.category = 'road' AND r.player_id = %s AND r.status = 'active'
                     AND ((r.x = %s AND r.y = %s) OR (r.x = %s AND r.y = %s)
                        OR (r.x = %s AND r.y = %s) OR (r.x = %s AND r.y = %s))""",
                (str(p['id']),
                 bx + 0, by + 0,  # tile itself shouldn't be road
                 bx + 2, by + 0, bx + 1, by - 1, bx + 1, by + 1))
    has_road = cur.fetchone() is not None
    if not has_road:
        # Add a connecting road. We know (bx, by) is road-adjacent
        # (timber_camp passed staffing), so neighbors of (bx, by) include
        # at least one road; place a road at (bx+1, by) by connecting
        # through a chain. Simpler: just place road at a nearby spot.
        # Easiest: connect via a tile that's road-adjacent to (bx+1, by)
        # using existing roads — try (bx, by-1) or (bx, by+1) etc.
        for nx, ny in [(bx + 1, by - 1), (bx + 1, by + 1), (bx + 2, by)]:
            cur.execute("SAVEPOINT road_try")
            try:
                cur.execute("UPDATE public.map_tiles SET resource_node_key = NULL WHERE x = %s AND y = %s",
                            (nx, ny))
                place('road', nx, ny)
                cur.execute("RELEASE SAVEPOINT road_try")
                break
            except Exception:
                cur.execute("ROLLBACK TO SAVEPOINT road_try")
                continue
    # The previous (bx + 1, by) target sometimes lands on the vertical
    # highway road (when the resource tile happens to sit one tile west
    # of x=hx). Walk around 4 candidate slots and pick the first one
    # that's not occupied by a road / building.
    placement_target = None
    for tx, ty in [(bx + 1, by), (bx, by + 1), (bx - 1, by), (bx, by - 1)]:
        cur.execute("SELECT occupied_building_id FROM public.map_tiles WHERE x=%s AND y=%s", (tx, ty))
        row = cur.fetchone()
        if row and row[0] is None:
            cur.execute("UPDATE public.map_tiles SET resource_node_key = NULL WHERE x = %s AND y = %s",
                        (tx, ty))
            placement_target = (tx, ty)
            break
    assert placement_target is not None, 'no buildable adjacent tile for foresters_office'
    place('foresters_office', placement_target[0], placement_target[1])

    # Run a tick from a fresh state
    cur.execute("""UPDATE public.buildings SET last_processed_at = now() - interval '60 seconds'
                   WHERE player_id = %s""", (str(p['id']),))
    cur.execute("SELECT public.process_production()")
    cur.execute("SELECT quantity FROM public.inventories WHERE player_id = %s AND resource_key = 'timber'",
                (str(p['id']),))
    boosted = float(cur.fetchone()[0])

    # Reset by demolishing the booster, run another tick
    cur.execute("""UPDATE public.buildings SET status = 'paused' WHERE player_id = %s
                   AND building_type_key = 'foresters_office'""", (str(p['id']),))
    cur.execute("""UPDATE public.buildings SET last_processed_at = now() - interval '60 seconds'
                   WHERE player_id = %s""", (str(p['id']),))
    cur.execute("""DELETE FROM public.inventories WHERE player_id = %s AND resource_key = 'timber'""",
                (str(p['id']),))
    cur.execute("SELECT public.process_production()")
    cur.execute("SELECT quantity FROM public.inventories WHERE player_id = %s AND resource_key = 'timber'",
                (str(p['id']),))
    unboosted = float(cur.fetchone()[0])

    assert boosted > unboosted * 1.20, \
        f"booster should add ~25% — boosted={boosted}, unboosted={unboosted}"


def test_food_booster_boosts_adjacent_food_extractor(make_player, place, stamp_food_tile, cur, clear_resources):
    p = make_player(industry='timber')
    clear_resources(p['id'])
    _cheap_extractors_and_boosters(cur)
    cur.execute("UPDATE public.player_profiles SET money = 5000 WHERE id = %s", (str(p['id']),))
    hx, hy = p['home_x'], p['home_y']
    stamp_food_tile('orchard_grove', hx + 1, hy + 1)
    place('orchard', hx + 1, hy + 1)
    place('apiary',  hx + 2, hy + 1)
    cur.execute("""UPDATE public.buildings SET last_processed_at = now() - interval '60 seconds'
                   WHERE player_id = %s""", (str(p['id']),))
    cur.execute("SELECT public.process_production()")
    cur.execute("SELECT quantity FROM public.inventories WHERE player_id = %s AND resource_key = 'berries'",
                (str(p['id']),))
    boosted = float(cur.fetchone()[0])
    # orchard rate 4/min, +25% = 5/min, in 60s ≈ 5 berries
    assert boosted > 4.8, f"orchard with apiary should produce >4.8 berries/min, got {boosted}"


def test_resource_booster_does_not_boost_food_extractor(make_player, place, stamp_food_tile, cur, clear_resources):
    """Forester's Office (boost_target='extractor') should NOT boost an Orchard."""
    p = make_player(industry='timber')
    clear_resources(p['id'])
    _cheap_extractors_and_boosters(cur)
    cur.execute("UPDATE public.player_profiles SET money = 5000 WHERE id = %s", (str(p['id']),))
    hx, hy = p['home_x'], p['home_y']
    stamp_food_tile('orchard_grove', hx + 1, hy + 1)
    place('orchard',           hx + 1, hy + 1)
    place('foresters_office',  hx + 2, hy + 1)
    cur.execute("""UPDATE public.buildings SET last_processed_at = now() - interval '60 seconds'
                   WHERE player_id = %s""", (str(p['id']),))
    cur.execute("SELECT public.process_production()")
    cur.execute("SELECT quantity FROM public.inventories WHERE player_id = %s AND resource_key = 'berries'",
                (str(p['id']),))
    yield_ = float(cur.fetchone()[0])
    # No boost — should be exactly ~4 (orchard's base rate, no multiplier)
    assert 3.8 < yield_ < 4.2, \
        f"resource booster shouldn't boost food extractor; got {yield_} (expected ~4)"


def test_out_of_range_booster_doesnt_apply(make_player, place, stamp_food_tile, cur, clear_resources):
    """Booster at distance 3 (range = 2) shouldn't boost the orchard."""
    p = make_player(industry='timber')
    clear_resources(p['id'])
    _cheap_extractors_and_boosters(cur)
    cur.execute("UPDATE public.player_profiles SET money = 5000 WHERE id = %s", (str(p['id']),))
    hx, hy = p['home_x'], p['home_y']
    stamp_food_tile('orchard_grove', hx + 1, hy + 1)
    place('orchard', hx + 1, hy + 1)
    # Distance 3+ → out of range
    place('apiary',  hx + 5, hy + 1)
    cur.execute("""UPDATE public.buildings SET last_processed_at = now() - interval '60 seconds'
                   WHERE player_id = %s""", (str(p['id']),))
    cur.execute("SELECT public.process_production()")
    cur.execute("SELECT quantity FROM public.inventories WHERE player_id = %s AND resource_key = 'berries'",
                (str(p['id']),))
    yield_ = float(cur.fetchone()[0])
    assert 3.8 < yield_ < 4.2, f"out-of-range booster should not boost; got {yield_}"


def test_unstaffed_booster_doesnt_apply(make_player, place, stamp_food_tile, cur, clear_resources):
    """Pause the booster — it should drop out of v_staffed_ids and stop applying."""
    p = make_player(industry='timber')
    clear_resources(p['id'])
    _cheap_extractors_and_boosters(cur)
    cur.execute("UPDATE public.player_profiles SET money = 5000 WHERE id = %s", (str(p['id']),))
    hx, hy = p['home_x'], p['home_y']
    stamp_food_tile('orchard_grove', hx + 1, hy + 1)
    place('orchard', hx + 1, hy + 1)
    apiary_id = place('apiary', hx + 2, hy + 1)['building_id']
    cur.execute("UPDATE public.buildings SET status = 'paused' WHERE id = %s", (apiary_id,))
    cur.execute("""UPDATE public.buildings SET last_processed_at = now() - interval '60 seconds'
                   WHERE player_id = %s""", (str(p['id']),))
    cur.execute("SELECT public.process_production()")
    cur.execute("SELECT quantity FROM public.inventories WHERE player_id = %s AND resource_key = 'berries'",
                (str(p['id']),))
    yield_ = float(cur.fetchone()[0])
    assert 3.8 < yield_ < 4.2, f"paused booster should not apply; got {yield_}"


def test_two_boosters_dont_stack(make_player, place, stamp_food_tile, cur, clear_resources):
    """Two boosters within range should still apply only the MAX multiplier
    (1.25), not stack to 1.5625."""
    p = make_player(industry='timber')
    clear_resources(p['id'])
    _cheap_extractors_and_boosters(cur)
    cur.execute("UPDATE public.player_profiles SET money = 5000 WHERE id = %s", (str(p['id']),))
    hx, hy = p['home_x'], p['home_y']
    stamp_food_tile('orchard_grove', hx + 1, hy + 1)
    place('orchard', hx + 1, hy + 1)
    place('apiary',  hx + 2, hy + 1)
    place('apiary',  hx + 1, hy + 2)  # second apiary, also within range 2
    cur.execute("""UPDATE public.buildings SET last_processed_at = now() - interval '60 seconds'
                   WHERE player_id = %s""", (str(p['id']),))
    cur.execute("SELECT public.process_production()")
    cur.execute("SELECT quantity FROM public.inventories WHERE player_id = %s AND resource_key = 'berries'",
                (str(p['id']),))
    yield_ = float(cur.fetchone()[0])
    # Single 1.25x = ~5 berries (4 × 1.25); stacked 1.5625x would be
    # ~6.25. Should stay at ~5.
    assert 4.8 < yield_ < 5.3, f"two boosters should not stack — got {yield_} (expected ~5)"
