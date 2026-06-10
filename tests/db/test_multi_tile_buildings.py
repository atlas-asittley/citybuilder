"""Multi-tile building footprints.

building_types.footprint_w / footprint_h define how many tiles a
building occupies. The anchor (top-left) is the click target;
place_building validates and claims every footprint tile. demolish
relies on the existing FK ON DELETE SET NULL so all footprint tiles
auto-clear when the building is deleted.

First multi-tile picks: tax_man (2x2), school (2x2), temple (2x2),
brewery (2x1).
"""
import psycopg2
import pytest


def test_chosen_buildings_have_expected_footprints(cur):
    cur.execute("""SELECT key, footprint_w, footprint_h FROM public.building_types
                   WHERE footprint_w > 1 OR footprint_h > 1 ORDER BY key""")
    rows = dict((r[0], (r[1], r[2])) for r in cur.fetchall())
    assert rows['tax_man'] == (2, 2)
    assert rows['school']  == (2, 2)
    assert rows['temple']  == (2, 2)
    assert rows['brewery'] == (2, 1)


def test_default_footprint_is_1x1(cur):
    """Most categories stay 1x1. Only the buildings explicitly listed
    here are multi-tile — exhaustive check ensures we didn't accidentally
    widen anything else. Update this list when intentionally giving a
    new building a non-1x1 footprint.

    Current multi-tile set:
    - tax_man / school / temple — 2x2 (original civic buildings)
    - brewery — 2x1 (original processing)
    - airport — 3x3 (transport hub, 2026-05-08)
    - seaport / train_depot — 3x2 (transport hubs, 2026-05-08)
    - truck_depot — 2x2 (transport connector, 2026-05-08)
    - public_garden — 2x2 (civic amenity, 2026-05-21)
    - hospital — 2x2 (service, 2026-05-21)
    - recycling_center / incinerator — 2x2 (sanitation, Civic Metrics 2026-05-28)
    - powerhouse — 2x2 (power, Civic Metrics 2026-05-28)
    - clinic / library — 2x2 (health/education services, Civic Metrics 2026-05-28)
    """
    cur.execute("""SELECT key FROM public.building_types
                   WHERE footprint_w <> 1 OR footprint_h <> 1
                   ORDER BY key""")
    keys = [r[0] for r in cur.fetchall()]
    assert keys == [
        'airport', 'brewery', 'clinic', 'hospital', 'incinerator', 'library',
        'powerhouse', 'public_garden', 'recycling_center', 'school',
        'seaport', 'tax_man', 'temple', 'train_depot', 'truck_depot'
    ]


def test_has_road_access_perimeter_for_multitile(make_player, place, cur, clear_resources):
    """Regression: has_road_access() used to check only the 4 tiles
    orthogonal to the anchor. A 2x2 truck_depot with a road touching
    only its right edge (e.g. (anchor_x + 2, anchor_y + 1)) returned
    false. Fixed to check the full perimeter of the footprint."""
    p = make_player(industry='timber')
    clear_resources(p['id'])
    cur.execute("UPDATE public.player_profiles SET money = 50000 WHERE id = %s", (str(p['id']),))
    hx, hy = p['home_x'], p['home_y']

    # Place a 2x2 truck_depot off the test-fixture's highway cross
    # (vertical at x=hx, horizontal at y=hy). Anchor (hx+1, hy+2)
    # covers (hx+1..hx+2, hy+2..hy+3).
    ax, ay = hx + 1, hy + 2
    place('truck_depot', ax, ay)

    # Test-only road INSERT — bypasses the road-must-connect-to-road
    # placement rule, which would force us to chain roads from the
    # highway and complicate the test. We're verifying has_road_access,
    # not place_building.
    def _put_road(rx, ry):
        cur.execute(
            "DELETE FROM public.buildings WHERE player_id=%s AND building_type_key='road'",
            (str(p['id']),)
        )
        cur.execute("SELECT id FROM public.map_tiles WHERE x=%s AND y=%s", (rx, ry))
        tile_id = cur.fetchone()[0]
        cur.execute(
            "INSERT INTO public.buildings (id, player_id, building_type_key, tile_id, x, y, status) "
            "VALUES (gen_random_uuid(), %s, 'road', %s, %s, %s, 'active') RETURNING id",
            (str(p['id']), tile_id, rx, ry)
        )
        rid = cur.fetchone()[0]
        cur.execute(
            "UPDATE public.map_tiles SET occupied_building_id=%s WHERE id=%s",
            (rid, tile_id)
        )

    # Right-edge: (ax+2, ay+1) — adjacent to interior (ax+1, ay+1) only.
    # Anchor-only check missed this; perimeter check finds it.
    _put_road(ax + 2, ay + 1)
    cur.execute("SELECT public.has_road_access(%s, %s, %s)", (str(p['id']), ax, ay))
    assert cur.fetchone()[0] is True, \
        'road on right-edge of 2x2 footprint should grant road access'

    # Bottom-edge: (ax+1, ay+2) — adjacent to interior (ax+1, ay+1) only.
    _put_road(ax + 1, ay + 2)
    cur.execute("SELECT public.has_road_access(%s, %s, %s)", (str(p['id']), ax, ay))
    assert cur.fetchone()[0] is True, \
        'road on bottom-edge of 2x2 footprint should grant road access'

    # Diagonal-only: (ax+2, ay+2) — kitty-corner from bottom-right interior,
    # not orthogonal to ANY footprint cell. Should NOT grant access.
    _put_road(ax + 2, ay + 2)
    cur.execute("SELECT public.has_road_access(%s, %s, %s)", (str(p['id']), ax, ay))
    assert cur.fetchone()[0] is False, \
        'diagonal-only road should NOT grant access (perimeter is ortho-strict)'


def test_school_claims_all_4_tiles(make_player, place, cur, clear_resources):
    p = make_player(industry='timber')
    clear_resources(p['id'])
    cur.execute("UPDATE public.player_profiles SET money = 50000 WHERE id = %s", (str(p['id']),))
    hx, hy = p['home_x'], p['home_y']
    bid = place('school', hx + 1, hy + 2)['building_id']
    cur.execute("""SELECT count(*) FROM public.map_tiles
                   WHERE occupied_building_id = %s""", (bid,))
    assert cur.fetchone()[0] == 4, 'school should claim its 4 footprint tiles'


def test_brewery_claims_2_tiles(make_player, place, cur, clear_resources):
    p = make_player(industry='iron')
    clear_resources(p['id'])
    cur.execute("UPDATE public.player_profiles SET money = 50000 WHERE id = %s", (str(p['id']),))
    hx, hy = p['home_x'], p['home_y']
    place('road', hx + 1, hy + 1)  # brewery is processor; needs road for staffing, not placement
    bid = place('brewery', hx + 2, hy + 2)['building_id']
    cur.execute("""SELECT count(*) FROM public.map_tiles
                   WHERE occupied_building_id = %s""", (bid,))
    assert cur.fetchone()[0] == 2


def test_school_rejects_partial_overlap(make_player, place, cur, clear_resources):
    """Placing a 1x1 building inside a 2x2 footprint must fail."""
    p = make_player(industry='timber')
    clear_resources(p['id'])
    cur.execute("UPDATE public.player_profiles SET money = 50000 WHERE id = %s", (str(p['id']),))
    hx, hy = p['home_x'], p['home_y']
    place('school', hx + 1, hy + 2)  # claims (hx+1..2, hy+2..3)
    with pytest.raises(psycopg2.errors.RaiseException):
        place('well', hx + 2, hy + 3)  # interior of school's footprint


def test_school_rejects_overlap_with_existing_building(make_player, place, cur, clear_resources):
    """A pre-existing building blocks the school's footprint from claiming."""
    p = make_player(industry='timber')
    clear_resources(p['id'])
    cur.execute("UPDATE public.player_profiles SET money = 50000 WHERE id = %s", (str(p['id']),))
    hx, hy = p['home_x'], p['home_y']
    place('well', hx + 2, hy + 3)  # would be the SE corner of the school footprint
    with pytest.raises(psycopg2.errors.RaiseException):
        place('school', hx + 1, hy + 2)


def test_school_rejects_offmap_footprint(make_player, place, cur, clear_resources):
    """If the footprint extends past the player's owned tiles, reject."""
    p = make_player(industry='timber')
    clear_resources(p['id'])
    cur.execute("UPDATE public.player_profiles SET money = 50000 WHERE id = %s", (str(p['id']),))
    # Find a buildable tile at the SE corner of an owned chunk so the footprint hangs off.
    cur.execute("""SELECT MAX(x), MAX(y) FROM public.map_tiles
                   WHERE owner_player_id = %s AND buildable""", (str(p['id']),))
    mx, my = cur.fetchone()
    with pytest.raises(psycopg2.errors.RaiseException):
        place('school', mx, my)  # 2x2 anchor at the corner = (mx, my, mx+1, my+1) and the latter two are unowned


def test_demolish_clears_all_footprint_tiles(make_player, place, cur, clear_resources):
    """Deleting a multi-tile building should free every footprint tile.
    The FK ON DELETE SET NULL on map_tiles.occupied_building_id handles this."""
    p = make_player(industry='timber')
    clear_resources(p['id'])
    cur.execute("UPDATE public.player_profiles SET money = 50000 WHERE id = %s", (str(p['id']),))
    hx, hy = p['home_x'], p['home_y']
    bid = place('school', hx + 1, hy + 2)['building_id']
    cur.execute("DELETE FROM public.buildings WHERE id = %s", (bid,))
    cur.execute("""SELECT count(*) FROM public.map_tiles
                   WHERE x BETWEEN %s AND %s AND y BETWEEN %s AND %s
                     AND occupied_building_id IS NOT NULL""",
                (hx + 1, hx + 2, hy + 2, hy + 3))
    assert cur.fetchone()[0] == 0, 'all 4 tiles should be unoccupied after demolish'


def test_after_demolish_can_rebuild_in_same_spot(make_player, place, cur, clear_resources):
    """Sanity: after demolishing a school, the same anchor accepts a fresh school."""
    p = make_player(industry='timber')
    clear_resources(p['id'])
    cur.execute("UPDATE public.player_profiles SET money = 50000 WHERE id = %s", (str(p['id']),))
    hx, hy = p['home_x'], p['home_y']
    bid = place('school', hx + 1, hy + 2)['building_id']
    cur.execute("DELETE FROM public.buildings WHERE id = %s", (bid,))
    bid2 = place('school', hx + 1, hy + 2)['building_id']
    assert bid2 != bid


def test_temple_2x2_footprint(make_player, place, cur, clear_resources):
    p = make_player(industry='stone')
    clear_resources(p['id'])
    cur.execute("UPDATE public.player_profiles SET money = 50000 WHERE id = %s", (str(p['id']),))
    hx, hy = p['home_x'], p['home_y']
    bid = place('temple', hx + 1, hy + 2)['building_id']
    cur.execute("""SELECT count(*) FROM public.map_tiles
                   WHERE occupied_building_id = %s""", (bid,))
    assert cur.fetchone()[0] == 4
