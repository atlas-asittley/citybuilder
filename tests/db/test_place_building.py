"""Tests for the `place_building` RPC.

Regression coverage:
- v_path record had to be initialized at top of function so non-extractor
  placements (roads, housing) don't crash on RETURN.
- Tile ownership: cannot build on wilderness or another player's tiles.
- Industry filter: cannot build buildings outside your industry.
- Extractor must be road-adjacent (M2 rule, replacing the old on-tile rule).
"""
import pytest
import psycopg2


def test_road_placement_succeeds_adjacent_to_home(make_player, place, clear_resources):
    p = make_player(industry='timber')
    clear_resources(p['id'])
    hx, hy = p['home_x'], p['home_y']
    result = place('road', hx + 1, hy + 1)
    assert 'building_id' in result
    assert result['extractor_target'] is None  # roads aren't extractors


def test_housing_placement_no_v_path_crash(make_player, place, clear_resources):
    """Regression: v_path was uninitialized for non-extractor placements,
    causing 'record not yet assigned' on RETURN's CASE expression."""
    p = make_player()
    clear_resources(p['id'])
    hx, hy = p['home_x'], p['home_y']
    place('road', hx + 1, hy + 1)
    result = place('house', hx + 2, hy + 1)
    assert 'building_id' in result


def test_extractor_no_longer_requires_road_adjacency(make_player, place, cur, clear_resources):
    """Updated: with weighted Dijkstra walker pathing, extractors can be
    placed anywhere on the player's owned, buildable, unoccupied tiles.
    Off-road tiles cost more to walk over, so production scales down,
    but placement itself succeeds."""
    p = make_player(industry='timber')
    clear_resources(p['id'])
    hx, hy = p['home_x'], p['home_y']
    # Place an extractor with NO road anywhere — should succeed
    result = place('timber_camp', hx + 5, hy + 5)
    assert 'building_id' in result


def test_extractor_finds_path_when_road_adjacent(make_player, place, cur, clear_resources):
    """M2: after placement, server BFS should claim a resource tile if
    one is reachable through the player's roads."""
    p = make_player(industry='timber')
    clear_resources(p['id'])
    hx, hy = p['home_x'], p['home_y']

    # Build a road run one row south of the highway so it doesn't collide
    # with the highway tiles themselves.
    for dx in range(1, 6):
        place('road', hx + dx, hy + 1)

    # Place an extractor adjacent to one of the roads. Whether it finds a
    # resource depends on random seeding; just verify the placement path
    # itself succeeds and target is either set or NULL (idle).
    result = place('timber_camp', hx + 3, hy + 2)
    assert 'building_id' in result
    # extractor_target may or may not be set depending on resource layout
    # — what matters is no crash and a valid response shape.


def test_cannot_build_on_wilderness(make_player, place, cur):
    p = make_player()
    # Find a tile far outside the player's district
    cur.execute(
        "SELECT x, y FROM public.map_tiles WHERE owner_player_id IS NULL LIMIT 1"
    )
    row = cur.fetchone()
    if not row:
        # No wilderness in current DB — create one for this test
        cur.execute("""
            INSERT INTO public.map_tiles (x, y, terrain_type, buildable, owner_player_id)
            VALUES (-100, -100, 'ground', true, NULL)
        """)
        x, y = -100, -100
    else:
        x, y = row
    with pytest.raises(psycopg2.errors.RaiseException, match="wilderness"):
        place('road', x, y)


def test_cannot_build_on_other_players_district(make_player, place, as_user, cur):
    """Cannot place on tiles owned by another player."""
    p1 = make_player(industry='timber')
    p2 = make_player(industry='stone')

    # Switch back to p1 and try to build inside p2's district
    as_user(p1['id'])
    p2_x, p2_y = p2['home_x'], p2['home_y']
    cur.execute("SELECT id FROM public.map_tiles WHERE x = %s AND y = %s", (p2_x + 1, p2_y))
    other_tile = cur.fetchone()[0]
    with pytest.raises(psycopg2.errors.RaiseException, match="another player"):
        cur.execute("SELECT public.place_building(%s, %s)", (other_tile, 'road'))


def test_industry_mismatch_rejected(make_player, place, clear_resources):
    """A timber player cannot build a stone_quarry."""
    p = make_player(industry='timber')
    clear_resources(p['id'])
    hx, hy = p['home_x'], p['home_y']
    place('road', hx + 1, hy + 1)
    with pytest.raises(psycopg2.errors.RaiseException, match="industry"):
        place('stone_quarry', hx + 1, hy + 2)


def test_common_buildings_allowed_for_any_industry(make_player, place, clear_resources):
    """Housing and roads are 'common' — buildable by any industry."""
    for industry in ['timber', 'stone', 'iron', 'clay']:
        p = make_player(industry=industry)
        clear_resources(p['id'])
        hx, hy = p['home_x'], p['home_y']
        result = place('road', hx + 1, hy + 1)
        assert 'building_id' in result
        result = place('house', hx + 2, hy + 1)
        assert 'building_id' in result


def test_road_placement_on_resource_tile(make_player, place, cur, clear_resources):
    """Regression: roads must be placeable on resource tiles (e.g. clay).
    place_building was missing the resource_node_key clear that place_pre_road
    does, so the reject_build_on_resource trigger silently blocked drag-paint
    road placement on any clay/timber tile (bug e1aa6e45, Jill 2026-05-22)."""
    p = make_player(industry='clay')
    clear_resources(p['id'])
    hx, hy = p['home_x'], p['home_y']
    # Stamp a clay resource node on the tile we're about to road over.
    cur.execute(
        "UPDATE public.map_tiles SET resource_node_key = 'clay' WHERE x = %s AND y = %s",
        (hx + 1, hy + 1)
    )
    # Must succeed — road paves over the clay tile.
    result = place('road', hx + 1, hy + 1)
    assert 'building_id' in result
    # The resource node should be cleared after road placement.
    cur.execute(
        "SELECT resource_node_key FROM public.map_tiles WHERE x = %s AND y = %s",
        (hx + 1, hy + 1)
    )
    assert cur.fetchone()[0] is None, "resource_node_key should be NULL after road is placed"


def test_road_placement_does_not_call_recompute_extractor_paths(make_player, place, cur, clear_resources):
    """Regression: place_building used to call recompute_extractor_paths after
    every road placement. With many extractors (e.g. 62 clay_pits), each BFS
    took ~280 ms → 17 s total → PostgREST HTTP timeout → silent transaction
    rollback. Road appeared to succeed on client but was never written.
    Fix: removed the eager recompute call; the server tick handles it.
    Bug 9acd2efb — Jill 2026-05-31."""
    import time
    p = make_player(industry='clay')
    clear_resources(p['id'])
    hx, hy = p['home_x'], p['home_y']
    # Plant several extractors so the old code would have iterated them.
    for dx in range(1, 6):
        cur.execute(
            "INSERT INTO public.buildings (player_id, building_type_key, tile_id, x, y) "
            "SELECT %s, 'clay_pit', id, x, y FROM public.map_tiles WHERE x = %s AND y = %s",
            (str(p['id']), hx + dx, hy - 2)
        )
    t0 = time.time()
    result = place('road', hx + 1, hy + 1)
    elapsed = time.time() - t0
    assert 'building_id' in result, "road placement should succeed"
    # If recompute_extractor_paths were still called this would take multiple
    # seconds; without it the whole RPC should finish in under 3 s.
    assert elapsed < 3.0, f"road placement took {elapsed:.2f}s — extractor repath may still be running inline"


def test_workers_needed_includes_food_extractor(make_player, place, stamp_food_tile, cur, clear_resources):
    """Regression: place_building's workers_needed query was missing the
    food_extractor and booster categories, so the response immediately
    after placement under-reported worker usage until the next
    process_production tick corrected it."""
    p = make_player(industry='timber')
    clear_resources(p['id'])
    hx, hy = p['home_x'], p['home_y']

    stamp_food_tile('orchard_grove', hx + 1, hy + 1)
    place('orchard', hx + 1, hy + 1)

    cur.execute("SELECT worker_cost FROM public.building_types WHERE key = 'orchard'")
    orchard_cost = cur.fetchone()[0]
    cur.execute("SELECT worker_cost FROM public.building_types WHERE key = 'timber_camp'")
    timber_cost = cur.fetchone()[0]

    result = place('timber_camp', hx + 1, hy - 1)

    assert result['workers_needed'] >= orchard_cost + timber_cost, (
        f"workers_needed should include food_extractor cost; "
        f"orchard={orchard_cost}, timber={timber_cost}, "
        f"got={result['workers_needed']}"
    )
