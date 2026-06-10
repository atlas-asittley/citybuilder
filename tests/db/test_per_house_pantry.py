"""Tests for the per-house pantry buffer model.

Old behavior: every house drew from a shared city pool. When the pool
emptied, every house simultaneously failed its consumption check and
all entered the devolve countdown together — a thundering-herd cascade.

New behavior: each house has a per-resource pantry buffer (capacity =
30 minutes of consumption at the current tier rate). Consumption is
from the pantry; refill happens from the city pool each tick. When
the city pool empties, pantries trickle toward zero — devolves happen
gradually as individual buffers empty, not all at once.
"""
import datetime
import pytest


def _force_pp(cur, p):
    """Trigger process_production. Returns the JSON event list."""
    cur.execute("SELECT public.process_production()")
    return cur.fetchone()[0]


def _set_house_tier(cur, building_id, tier):
    """Bump a house's housing_tier directly (the trigger will sync buffers)."""
    cur.execute(
        "UPDATE public.buildings SET housing_tier = %s, last_processed_at = now() WHERE id = %s",
        (tier, str(building_id))
    )


def _place_houses(cur, place, clear_resources, player, n=1, with_well=True):
    """Place N housing buildings around the player's home coordinates.
    Drops a well next to them so tier-2+ gates don't flag a missing well
    (this test file is about the consumption-buffer cascade, not service
    coverage)."""
    clear_resources(player['id'])
    hx, hy = player['home_x'], player['home_y']
    if with_well:
        place('well', hx + 1, hy + 1)
    house_ids = []
    for i in range(n):
        result = place('house', hx + 1 + i, hy + 2)
        if isinstance(result, dict):
            house_ids.append(result.get('building_id'))
        else:
            import json
            d = json.loads(result) if isinstance(result, str) else result
            house_ids.append(d.get('building_id'))
    return house_ids


def test_buffer_seeded_on_house_placement(cur, make_player, place, clear_resources):
    """A freshly-placed house gets buffer rows for its tier's gated
    resources, all filled to capacity."""
    p = make_player()
    house_ids = _place_houses(cur, place, clear_resources, p, 1)
    bid = house_ids[0]

    # New houses arrive at tier 1 (Mud Hut). Tier 1 has no food /
    # lifestyle gates, so it should have no buffer rows.
    cur.execute(
        "SELECT count(*) FROM public.building_resource_buffers WHERE building_id = %s",
        (str(bid),)
    )
    assert cur.fetchone()[0] == 0, "tier 1 has no consumption gates"

    # Bump to tier 2 (Cottage) — needs food + pottery.
    _set_house_tier(cur, bid, 2)
    cur.execute("""
        SELECT resource_key, quantity, capacity FROM public.building_resource_buffers
        WHERE building_id = %s ORDER BY resource_key
    """, (str(bid),))
    rows = cur.fetchall()
    keys = {r[0]: (float(r[1]), float(r[2])) for r in rows}
    assert 'food' in keys, "tier 2 should have food buffer"
    assert 'pottery' in keys, "tier 2 should have pottery buffer"
    # 30-min capacity at the tier-2 rates: food 0.24/min, pottery 0.05/min
    assert abs(keys['food'][1] - 0.24 * 30) < 0.01, keys['food']
    assert abs(keys['pottery'][1] - 0.05 * 30) < 0.01, keys['pottery']
    # New rows arrive at full capacity (no instant-devolve on placement).
    assert keys['food'][0] == keys['food'][1]
    assert keys['pottery'][0] == keys['pottery'][1]


def test_buffer_extended_on_tier_upgrade(cur, make_player, place, clear_resources):
    """When a house upgrades, new tier's gated resources get added to
    its pantry (at full capacity); existing buffers are clamped to new
    capacity if rates changed."""
    p = make_player()
    house_ids = _place_houses(cur, place, clear_resources, p, 1)
    bid = house_ids[0]

    _set_house_tier(cur, bid, 3)  # Townhouse — adds bread, raises pottery rate
    cur.execute("""
        SELECT resource_key, capacity FROM public.building_resource_buffers
        WHERE building_id = %s ORDER BY resource_key
    """, (str(bid),))
    keys = {r[0]: float(r[1]) for r in cur.fetchall()}
    assert 'bread' in keys, "tier 3 added bread"
    assert 'pottery' in keys
    assert 'food' in keys
    # Tier 3 rates: food 0.40/min, pottery 0.075/min, bread 0.025/min
    # (bread halved 2026-05-21 — see halve_bread_demand migration).
    assert abs(keys['food'] - 0.40 * 30) < 0.01
    assert abs(keys['pottery'] - 0.075 * 30) < 0.01
    assert abs(keys['bread'] - 0.025 * 30) < 0.01


def test_buffer_shrinks_on_devolve(cur, make_player, place, clear_resources):
    """When a house devolves to a tier with fewer gated resources, the
    no-longer-needed buffers are removed."""
    p = make_player()
    house_ids = _place_houses(cur, place, clear_resources, p, 1)
    bid = house_ids[0]

    _set_house_tier(cur, bid, 4)  # Villa: pottery + bread + furniture + food
    cur.execute("SELECT count(*) FROM public.building_resource_buffers WHERE building_id = %s", (str(bid),))
    assert cur.fetchone()[0] == 4

    _set_house_tier(cur, bid, 2)  # Devolve all the way to Cottage
    cur.execute("""
        SELECT resource_key FROM public.building_resource_buffers
        WHERE building_id = %s ORDER BY resource_key
    """, (str(bid),))
    keys = [r[0] for r in cur.fetchall()]
    assert sorted(keys) == ['food', 'pottery'], f"got {keys}"


def test_consume_drains_buffer(cur, make_player, place, clear_resources, tick):
    """A tick with elapsed time should decrement each house's buffer
    by rate * minutes."""
    p = make_player()
    house_ids = _place_houses(cur, place, clear_resources, p, 1)
    bid = house_ids[0]
    _set_house_tier(cur, bid, 2)

    # Reset last_food_tick_at to 5 minutes ago so the next tick consumes 5min worth.
    cur.execute(
        "UPDATE public.player_profiles SET last_food_tick_at = now() - interval '5 minutes' WHERE id = %s",
        (str(p['id']),)
    )
    # Empty the city's pottery so refill can't top the buffer back up.
    cur.execute("DELETE FROM public.inventories WHERE player_id = %s AND resource_key = 'pottery'", (str(p['id']),))

    # Snapshot buffer pre-tick.
    cur.execute(
        "SELECT quantity FROM public.building_resource_buffers WHERE building_id = %s AND resource_key='pottery'",
        (str(bid),)
    )
    before = float(cur.fetchone()[0])

    cur.execute("SELECT public.process_production()")

    cur.execute(
        "SELECT quantity FROM public.building_resource_buffers WHERE building_id = %s AND resource_key='pottery'",
        (str(bid),)
    )
    after = float(cur.fetchone()[0])

    # 5 minutes at 0.05/min = 0.25 consumed.
    consumed = before - after
    assert 0.20 <= consumed <= 0.30, f"expected ~0.25 consumed, got {consumed:.3f}"


def test_refill_tops_up_from_city_stock(cur, make_player, place, clear_resources):
    """When the city has pottery in inventory, a partially-empty house
    pantry should refill toward capacity on the next tick."""
    p = make_player()
    house_ids = _place_houses(cur, place, clear_resources, p, 1)
    bid = house_ids[0]
    _set_house_tier(cur, bid, 2)

    # Drain the buffer manually to simulate prior consumption.
    cur.execute(
        "UPDATE public.building_resource_buffers SET quantity = 0 WHERE building_id = %s AND resource_key='pottery'",
        (str(bid),)
    )
    # Stock the city with plenty of pottery.
    cur.execute(
        "INSERT INTO public.inventories (player_id, resource_key, quantity) VALUES (%s, 'pottery', 100) "
        "ON CONFLICT (player_id, resource_key) DO UPDATE SET quantity = 100",
        (str(p['id']),)
    )
    # No elapsed time — only refill phase will run.
    cur.execute("UPDATE public.player_profiles SET last_food_tick_at = now() WHERE id = %s", (str(p['id']),))

    cur.execute("SELECT public.process_production()")

    cur.execute(
        "SELECT quantity, capacity FROM public.building_resource_buffers WHERE building_id = %s AND resource_key='pottery'",
        (str(bid),)
    )
    qty, cap = [float(x) for x in cur.fetchone()]
    assert qty >= cap * 0.95, f"buffer should be ~full after refill: {qty}/{cap}"


def test_buffer_absorbs_brief_shortage(cur, make_player, place, clear_resources):
    """The headline behavior: when city pottery hits zero, a tier-2
    cottage with a partially-full pantry should NOT devolve immediately
    on the next tick. Its own buffer carries it through.

    OLD model: city pottery = 0 → ALL houses fail v_lifestyle_for_cur_ok
    on the same tick → all enter devolve grace simultaneously → cascade.
    NEW model: city pottery = 0 → pantries drain at per-house rate →
    each house only fails when ITS OWN buffer empties.
    """
    p = make_player()
    house_ids = _place_houses(cur, place, clear_resources, p, 1)
    bid = house_ids[0]
    _set_house_tier(cur, bid, 2)

    # Wipe city pottery + age last_processed_at past devolve_secs.
    cur.execute("DELETE FROM public.inventories WHERE player_id = %s AND resource_key = 'pottery'", (str(p['id']),))
    cur.execute(
        "UPDATE public.buildings SET last_processed_at = now() - interval '120 seconds' WHERE id = %s",
        (str(bid),)
    )
    # 5 minutes elapsed — drains pottery buffer from 1.5 to 1.25 (still > 0).
    cur.execute(
        "UPDATE public.player_profiles SET last_food_tick_at = now() - interval '5 minutes' WHERE id = %s",
        (str(p['id']),)
    )

    cur.execute("SELECT public.process_production()")

    cur.execute("SELECT housing_tier FROM public.buildings WHERE id = %s", (str(bid),))
    tier = cur.fetchone()[0]
    cur.execute("SELECT quantity FROM public.building_resource_buffers WHERE building_id = %s AND resource_key = 'pottery'",
                (str(bid),))
    pottery = float(cur.fetchone()[0])
    assert tier == 2, f"5min drain should leave buffer at ~1.25 — house should NOT devolve. tier={tier}, pottery_qty={pottery:.3f}"
    assert pottery > 0, f"pottery buffer should still have stock: {pottery}"


def test_devolve_fires_when_own_buffer_empties(cur, make_player, place, clear_resources):
    """A house WITH an empty buffer (and no city stock to refill it) AND
    an aged last_processed_at SHOULD devolve."""
    p = make_player()
    house_ids = _place_houses(cur, place, clear_resources, p, 1)
    bid = house_ids[0]
    _set_house_tier(cur, bid, 2)

    # Force pantry empty + city empty + grace period elapsed.
    cur.execute(
        "UPDATE public.building_resource_buffers SET quantity = 0 WHERE building_id = %s AND resource_key='pottery'",
        (str(bid),)
    )
    cur.execute("DELETE FROM public.inventories WHERE player_id = %s AND resource_key = 'pottery'", (str(p['id']),))
    cur.execute(
        "UPDATE public.buildings SET last_processed_at = now() - interval '120 seconds' WHERE id = %s",
        (str(bid),)
    )
    cur.execute("UPDATE public.player_profiles SET last_food_tick_at = now() WHERE id = %s", (str(p['id']),))

    cur.execute("SELECT public.process_production()")
    cur.execute("SELECT housing_tier FROM public.buildings WHERE id = %s", (str(bid),))
    assert cur.fetchone()[0] == 1, "house with empty pantry + grace elapsed should devolve"


def test_buffer_cascades_on_building_delete(cur, make_player, place, clear_resources):
    """ON DELETE CASCADE: removing a building drops its buffer rows."""
    p = make_player()
    house_ids = _place_houses(cur, place, clear_resources, p, 1)
    bid = house_ids[0]
    _set_house_tier(cur, bid, 2)

    cur.execute("SELECT count(*) FROM public.building_resource_buffers WHERE building_id = %s", (str(bid),))
    assert cur.fetchone()[0] >= 1

    cur.execute("DELETE FROM public.buildings WHERE id = %s", (str(bid),))
    cur.execute("SELECT count(*) FROM public.building_resource_buffers WHERE building_id = %s", (str(bid),))
    assert cur.fetchone()[0] == 0, "buffer rows should cascade-delete with the building"
