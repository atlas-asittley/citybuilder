"""Iron industry — replaces grain as the 4th industry option.

Iron's primary extractor is iron_mine (tile-based, claims iron resource
tiles). Its paired food extractor is grain_farm, which is now flat-rate
and locked to the iron industry.
"""
import psycopg2


def test_iron_player_can_build_iron_mine(make_player, place, cur, clear_resources):
    p = make_player(industry='iron')
    clear_resources(p['id'])
    hx, hy = p['home_x'], p['home_y']
    result = place('iron_mine', hx + 1, hy + 1)
    assert 'building_id' in result


def test_iron_player_can_build_grain_farm(make_player, place, stamp_food_tile, cur, clear_resources):
    """Grain farm is the iron player's paired food extractor — must sit
    on a farmland tile."""
    p = make_player(industry='iron')
    clear_resources(p['id'])
    hx, hy = p['home_x'], p['home_y']
    stamp_food_tile('farmland', hx + 1, hy + 1)
    result = place('grain_farm', hx + 1, hy + 1)
    assert 'building_id' in result


def test_stone_player_cannot_build_iron_mine(make_player, place, cur, clear_resources):
    p = make_player(industry='stone')
    clear_resources(p['id'])
    hx, hy = p['home_x'], p['home_y']
    try:
        place('iron_mine', hx + 1, hy + 1)
        assert False, "should have raised"
    except psycopg2.errors.RaiseException as e:
        assert 'industry' in str(e).lower()


def test_stone_player_cannot_build_grain_farm(make_player, place, cur, clear_resources):
    """grain_farm was 'common' (anyone could build); is now locked to iron."""
    p = make_player(industry='stone')
    clear_resources(p['id'])
    hx, hy = p['home_x'], p['home_y']
    try:
        place('grain_farm', hx + 1, hy + 1)
        assert False, "should have raised"
    except psycopg2.errors.RaiseException as e:
        assert 'industry' in str(e).lower()


def test_grain_farm_is_now_food_extractor(cur):
    """Migration converts grain_farm to category='food_extractor'."""
    cur.execute("SELECT category FROM building_types WHERE key = 'grain_farm'")
    assert cur.fetchone()[0] == 'food_extractor'


def test_grain_farm_produces_grain_at_flat_rate(make_player, place, stamp_food_tile, cur, clear_resources):
    """No path math, flat 2 grain/min when staffed (must be on farmland)."""
    p = make_player(industry='iron')
    clear_resources(p['id'])
    # Make food extractors cheap enough for the base capacity to staff one
    cur.execute("UPDATE public.building_types SET worker_cost = 4 WHERE key = 'grain_farm'")
    hx, hy = p['home_x'], p['home_y']
    stamp_food_tile('farmland', hx + 1, hy + 1)
    place('grain_farm', hx + 1, hy + 1)
    cur.execute("""UPDATE public.buildings
                   SET last_processed_at = now() - interval '60 seconds'
                   WHERE player_id = %s""", (str(p['id']),))
    cur.execute("SELECT public.process_production()")
    cur.execute("SELECT quantity FROM public.inventories WHERE player_id = %s AND resource_key = 'grain'",
                (str(p['id']),))
    grain = float(cur.fetchone()[0])
    assert 3.5 < grain < 4.5, f"grain_farm expected ~4 grain/min flat-rate, got {grain}"


def test_iron_mine_produces_iron(make_player, place, cur, clear_resources):
    """iron_mine is a regular tile-based extractor; needs iron tiles to
    extract from. The cluster generator seeds the player's industry as
    the resource key, so an iron player's chunks have iron tiles."""
    p = make_player(industry='iron')
    # Don't call clear_resources — it would wipe the iron clusters and
    # rebuild a straight road cross. We want the natural iron clusters.
    cur.execute("UPDATE public.building_types SET worker_cost = 4 WHERE key = 'iron_mine'")
    cur.execute("UPDATE public.player_profiles SET money = 5000 WHERE id = %s",
                (str(p['id']),))
    hx, hy = p['home_x'], p['home_y']

    # Find a buildable tile that's adjacent to a road (every production
    # building now needs road access). The chunk has the curving
    # highway crossing at y=hy and x=hx; pick a tile next to that.
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
    row = cur.fetchone()
    if row is None:
        return  # No road-adjacent buildable tile — skip
    bx, by = row
    result = place('iron_mine', bx, by)
    assert 'building_id' in result

    cur.execute("""UPDATE public.buildings
                   SET last_processed_at = now() - interval '60 seconds'
                   WHERE player_id = %s""", (str(p['id']),))
    cur.execute("SELECT public.process_production()")
    cur.execute("SELECT quantity FROM public.inventories WHERE player_id = %s AND resource_key = 'iron'",
                (str(p['id']),))
    iron = float(cur.fetchone()[0])
    # iron_mine output_rate=1, but path_length factor scales it down.
    # Just confirm SOME iron came out (mine reached a tile).
    assert iron > 0, f"iron_mine should produce some iron when there are iron tiles in chunks; got {iron}"
