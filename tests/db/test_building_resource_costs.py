"""Resource costs for placing buildings.

Atlas (2026-05-08): every non-basic building requires a small set of
resources from the player's inventory at placement time on top of
its money cost. House / road / well / extractors / farms / tree_grove
are the explicit money-only set.
"""
import psycopg2
import pytest


def _set_inv(cur, player_id, resource_key, qty):
    cur.execute(
        "INSERT INTO public.inventories (player_id, resource_key, quantity) "
        "VALUES (%s, %s, %s) "
        "ON CONFLICT (player_id, resource_key) DO UPDATE SET quantity = EXCLUDED.quantity",
        (str(player_id), resource_key, qty)
    )


def _money(cur, player_id, amt):
    cur.execute("UPDATE public.player_profiles SET money = %s WHERE id = %s",
                (amt, str(player_id)))


def test_money_only_buildings_have_no_resource_costs(cur):
    """The 'basic' buildings Atlas exempted should have NO rows in
    building_type_resource_costs.

    Note (2026-05-29, Civic Metrics Expansion): the UPGRADED road tiers
    (paved_road / tiled_avenue / grand_boulevard) now legitimately cost
    materials (brick / tiles / monuments+cabinets+mosaics — the dead-capstone
    sinks), so 'road' is no longer a blanket money-only category. The base
    dirt `road` stays money-only and is still asserted via its key."""
    cur.execute("""
        SELECT bt.key
          FROM public.building_types bt
          JOIN public.building_type_resource_costs btrc
            ON btrc.building_type_key = bt.key
         WHERE bt.is_active
           AND (
             bt.category IN ('housing', 'extractor', 'food_extractor')
             OR bt.key IN ('well', 'tree_grove', 'road')
           )
    """)
    leaks = [r[0] for r in cur.fetchall()]
    assert leaks == [], f"Money-only buildings should have no resource costs: {leaks}"


def _raw_place(cur, building_type_key, x, y):
    """Place a building WITHOUT the place fixture's auto-top-up — this
    test specifically wants the resource gate to fire."""
    cur.execute("SELECT id FROM public.map_tiles WHERE x = %s AND y = %s", (x, y))
    row = cur.fetchone()
    assert row, f"No tile at ({x}, {y})"
    cur.execute("SELECT public.place_building(%s, %s)", (str(row[0]), building_type_key))
    return cur.fetchone()[0]


def test_sawmill_blocked_without_required_resources(make_player, place, cur, clear_resources):
    """sawmill needs timber + brick. Without inventory, placement
    should raise an exception listing the missing materials."""
    p = make_player(industry='timber')
    clear_resources(p['id'])
    _money(cur, p['id'], 100000)
    _set_inv(cur, p['id'], 'timber', 0)
    _set_inv(cur, p['id'], 'brick', 0)
    hx, hy = p['home_x'], p['home_y']
    place('road', hx + 1, hy + 1)  # road for sawmill access (road is money-only)

    # Call place_building directly so the place fixture's auto-top-up
    # doesn't pre-fill the inventory we're testing absence of.
    with pytest.raises(psycopg2.errors.RaiseException) as exc:
        _raw_place(cur, 'sawmill', hx + 1, hy + 2)
    msg = str(exc.value)
    assert 'Not enough resources' in msg
    assert 'timber' in msg.lower()
    assert 'brick' in msg.lower()


def test_sawmill_succeeds_and_deducts_inventory(make_player, place, cur, clear_resources):
    """With timber + brick on hand, sawmill places and the resources
    drop by the listed quantity (10 timber + 5 brick per
    building_resource_costs.sql)."""
    p = make_player(industry='timber')
    clear_resources(p['id'])
    _money(cur, p['id'], 100000)
    _set_inv(cur, p['id'], 'timber', 50)
    _set_inv(cur, p['id'], 'brick', 50)
    hx, hy = p['home_x'], p['home_y']
    place('road', hx + 1, hy + 1)
    place('sawmill', hx + 1, hy + 2)

    cur.execute("SELECT quantity FROM public.inventories "
                "WHERE player_id=%s AND resource_key='timber'",
                (str(p['id']),))
    assert float(cur.fetchone()[0]) == 40.0  # 50 - 10
    cur.execute("SELECT quantity FROM public.inventories "
                "WHERE player_id=%s AND resource_key='brick'",
                (str(p['id']),))
    assert float(cur.fetchone()[0]) == 45.0  # 50 - 5


def test_house_has_no_resource_cost(make_player, place, cur, clear_resources):
    """House is in Atlas's money-only set — should place with empty
    inventory, only consuming money."""
    p = make_player(industry='timber')
    clear_resources(p['id'])
    _money(cur, p['id'], 1000)
    # Empty inventory.
    cur.execute("DELETE FROM public.inventories WHERE player_id = %s", (str(p['id']),))
    hx, hy = p['home_x'], p['home_y']
    place('well', hx + 2, hy + 1)
    bid = place('house', hx + 1, hy + 2)['building_id']
    assert bid is not None


def test_truck_depot_blocked_without_finished_goods(make_player, place, cur, clear_resources):
    """truck_depot needs brick / lumber / iron / nails. Without nails
    in particular (an iron-chain processed good), the timber player
    can't build it without trading."""
    p = make_player(industry='timber')
    clear_resources(p['id'])
    _money(cur, p['id'], 100000)
    # Give them everything except nails.
    _set_inv(cur, p['id'], 'brick', 100)
    _set_inv(cur, p['id'], 'lumber', 100)
    _set_inv(cur, p['id'], 'iron', 100)
    _set_inv(cur, p['id'], 'nails', 0)
    hx, hy = p['home_x'], p['home_y']
    place('road', hx + 1, hy + 1)

    with pytest.raises(psycopg2.errors.RaiseException) as exc:
        _raw_place(cur, 'truck_depot', hx + 1, hy + 2)
    assert 'nails' in str(exc.value).lower()
