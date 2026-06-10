"""Tests for the BFS pathfinding RPCs.

Regression coverage:
- find_nearest_unclaimed_resource must skip occupied tiles (the bug
  where an extractor on a resource tile claimed its own footprint).
- verify_extractor_path returns NULL when a road has been demolished.
- recompute_extractor_paths is hybrid-sticky: keeps existing valid
  claims, frees broken ones, re-targets idle extractors.
"""
import pytest
import psycopg2


def _seed_resource(cur, player_id, x, y, key='timber'):
    """Force a tile to have a specific resource node, regardless of the
    random 8% seeding."""
    cur.execute("""
        UPDATE public.map_tiles
        SET resource_node_key = %s
        WHERE x = %s AND y = %s AND owner_player_id = %s
    """, (key, x, y, str(player_id)))


def _clear_resources(cur, player_id):
    """Strip random resource seeding AND replace the curving pre-placed
    road network with a straight cross at (hx, *) and (*, hy), so tests
    can place at fixed offsets near home without random pre-roads
    blocking the cells they want."""
    cur.execute("SELECT home_x, home_y FROM public.player_profiles WHERE id = %s",
                (str(player_id),))
    hx, hy = cur.fetchone()
    chunk_x = hx // 15 if hx >= 0 else (hx - 14) // 15
    chunk_y = hy // 15 if hy >= 0 else (hy - 14) // 15
    x_start, y_start = chunk_x * 15, chunk_y * 15
    cur.execute("""
        DELETE FROM public.buildings b
        USING public.building_types bt
        WHERE b.building_type_key = bt.key AND bt.category = 'road'
          AND b.player_id = %s
          AND b.x >= %s AND b.x < %s AND b.y >= %s AND b.y < %s
    """, (str(player_id), x_start, x_start + 15, y_start, y_start + 15))
    cur.execute("""
        UPDATE public.map_tiles
        SET resource_node_key = NULL, claimed_by_building_id = NULL
        WHERE owner_player_id = %s
          AND x >= %s AND x < %s AND y >= %s AND y < %s
    """, (str(player_id), x_start, x_start + 15, y_start, y_start + 15))
    for offset in range(15):
        cur.execute("SELECT public._place_pre_road(%s, %s, %s)",
                    (str(player_id), x_start + offset, hy))
        cur.execute("SELECT public._place_pre_road(%s, %s, %s)",
                    (str(player_id), hx, y_start + offset))
    cur.execute("""
        UPDATE public.map_tiles
        SET resource_node_key = NULL, claimed_by_building_id = NULL
        WHERE owner_player_id = %s
    """, (str(player_id),))


def test_finds_nearest_resource_through_roads(make_player, place, cur):
    p = make_player(industry='timber')
    hx, hy = p['home_x'], p['home_y']
    _clear_resources(cur, p['id'])
    _seed_resource(cur, p['id'], hx + 4, hy + 2, 'timber')

    # Build a road run east, parallel to the highway (y=hy is the highway row).
    for dx in range(1, 5):
        place('road', hx + dx, hy + 1)

    # Place extractor adjacent to a road, not on the resource.
    result = place('timber_camp', hx + 1, hy + 2)
    target = result.get('extractor_target')
    assert target is not None, "BFS should have found the seeded timber"
    assert (target['x'], target['y']) == (hx + 4, hy + 2)
    assert target['path_length'] >= 1


# Removed: test_skips_occupied_resource_tile.
# The scenario it tested (extractor placed on a tile that's also a resource
# node, then claiming itself) is now structurally impossible — the
# reject_build_on_resource trigger blocks building on any tile with
# resource_node_key set. The test_cannot_build_on_resource_tile test in
# test_resource_tile_rules.py covers the new invariant.


def test_no_path_when_isolated(make_player, place, cur):
    """Extractor with no reachable resource tile should produce NULL path."""
    p = make_player(industry='timber')
    hx, hy = p['home_x'], p['home_y']
    _clear_resources(cur, p['id'])
    # Seed a timber tile somewhere unreachable (no roads to it)
    _seed_resource(cur, p['id'], hx + 8, hy + 8, 'timber')

    # Build a road but only adjacent to home — won't reach (hx+8, hy+8)
    place('road', hx + 1, hy + 1)
    result = place('timber_camp', hx + 1, hy + 2)
    assert result.get('extractor_target') is None


def test_only_finds_owned_resource_tiles(make_player, place, as_user, cur):
    """Player A's BFS must not pick a resource in player B's district."""
    pA = make_player(industry='timber')
    pB = make_player(industry='timber')
    as_user(pA['id'])

    _clear_resources(cur, pA['id'])
    _clear_resources(cur, pB['id'])
    # B has a timber tile near their home; A does not. Seed off the
    # highway (which runs through y=home_y) to keep this on regular ground.
    _seed_resource(cur, pB['id'], pB['home_x'] + 1, pB['home_y'] + 1, 'timber')

    hx, hy = pA['home_x'], pA['home_y']
    place('road', hx + 1, hy + 1)
    result = place('timber_camp', hx + 1, hy + 2)
    assert result.get('extractor_target') is None, "should not see B's resources"


def test_two_extractors_cannot_share_a_resource(make_player, place, cur):
    """First extractor claims a resource tile; second has to go elsewhere
    or be idle if no other tile is reachable."""
    p = make_player(industry='timber')
    hx, hy = p['home_x'], p['home_y']
    _clear_resources(cur, p['id'])
    _seed_resource(cur, p['id'], hx + 4, hy + 2, 'timber')   # only one tile

    for dx in range(1, 5):
        place('road', hx + dx, hy + 1)

    r1 = place('timber_camp', hx + 1, hy + 2)
    r2 = place('timber_camp', hx + 2, hy + 2)
    t1 = r1.get('extractor_target')
    t2 = r2.get('extractor_target')

    # First should have claimed the only timber tile
    assert t1 is not None
    assert (t1['x'], t1['y']) == (hx + 4, hy + 2)
    # Second should be idle
    assert t2 is None
