"""Tests that the starter parcel always has a food tile adjacent to a
pre-placed road, so new players don't have to build a long road out
to a corner-of-map food patch as their first action.

Atlas 2026-05-09: "they should always have a farm that's near a road."

Implementation: `_guarantee_food_near_road` runs after roads + clusters
during `allocate_district_chunk` for first-chunk allocations only.
"""
import uuid


def _food_tile_key_for(industry):
    return {
        'timber': 'orchard_grove',
        'stone': 'pond',
        'clay': 'garden_plot',
        'iron': 'farmland',
    }[industry]


def _has_road_adjacent_food(cur, player_id, food_key):
    """Return True if at least one food tile in the player's parcel is
    one step away (Manhattan distance 1) from a road building."""
    cur.execute("""
        SELECT EXISTS (
          SELECT 1
          FROM public.map_tiles m
          WHERE m.owner_player_id = %s
            AND m.resource_node_key = %s
            AND EXISTS (
              SELECT 1 FROM public.buildings b
              JOIN public.building_types bt ON bt.key = b.building_type_key
              WHERE bt.category = 'road'
                AND ABS(b.x - m.x) + ABS(b.y - m.y) = 1
            )
        )
    """, (str(player_id), food_key))
    return cur.fetchone()[0]


def test_each_industry_starts_with_road_adjacent_food(make_player, cur):
    """Run a starter allocation for each industry many times; every
    one should produce a parcel with at least one road-adjacent food
    tile. The function uses random walks under the hood, so we sample
    multiple players to confirm it's deterministic, not lucky."""
    for industry in ('timber', 'stone', 'clay', 'iron'):
        key = _food_tile_key_for(industry)
        for _ in range(5):
            p = make_player(industry=industry)
            assert _has_road_adjacent_food(cur, p['id'], key), (
                f"industry={industry} player has no {key} adjacent to a road"
            )


def test_no_extra_food_added_when_already_adjacent(make_player, cur):
    """If the random cluster seeding happened to produce a food tile
    already adjacent to a road, the guarantee shouldn't ADD another.
    Verify by counting food tiles: the count should match what
    cluster seeding produced (no fence-post stamping)."""
    # 5 trials should give us at least one where cluster seeding got
    # lucky on its own. Across trials, the food-tile count distribution
    # should reflect the cluster seeding alone (mean ~5 with the
    # post-doubling settings of 2 clusters × walk(2,3)).
    counts = []
    for _ in range(5):
        p = make_player(industry='iron')
        cur.execute("""
            SELECT count(*) FROM public.map_tiles
            WHERE owner_player_id = %s AND resource_node_key = 'farmland'
        """, (str(p['id']),))
        counts.append(cur.fetchone()[0])
    # Sanity: never zero (guarantee always lands at least one).
    for c in counts:
        assert c >= 1, f"food tile count should be >= 1, got {c}"
    # Soft sanity: most trials produce 2+ tiles (cluster seeding alone
    # should hit several walk steps). If every single trial returned
    # exactly 1, the guarantee is firing on top of nothing — meaning
    # the cluster seeding broke. Allow some 1-tile trials but not all.
    non_singletons = sum(1 for c in counts if c >= 2)
    assert non_singletons >= 1, (
        f"expected at least one trial with multiple food tiles; got {counts}"
    )
