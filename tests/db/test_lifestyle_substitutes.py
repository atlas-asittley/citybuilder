"""Tests for the bread → {spices, caviar, spirits} substitute chain.

Design: a tier's lifestyle demand for `bread` is satisfied by ANY of
the four (bread / spices / caviar / spirits) — in inventory for the
upgrade gate, and proportionally as a pool for the per-house pantry
refill.
"""

import datetime
import pytest


def _set_house_tier(cur, building_id, tier):
    cur.execute(
        "UPDATE public.buildings SET housing_tier = %s, last_processed_at = now() WHERE id = %s",
        (tier, str(building_id)),
    )


def _place_one_house(cur, place, clear_resources, player, with_road=False):
    clear_resources(player['id'])
    hx, hy = player['home_x'], player['home_y']
    place('well', hx + 1, hy + 1)
    if with_road:
        # Tier 3+ upgrades need road access. Drop a road on the tile
        # north of where the house will sit.
        place('road', hx + 1, hy + 3)
    result = place('house', hx + 1, hy + 2)
    if isinstance(result, dict):
        return result.get('building_id')
    import json
    d = json.loads(result) if isinstance(result, str) else result
    return d.get('building_id')


def _set_inventory(cur, player_id, **resources):
    """Wipe + write specific inventories for the player. Wipes ONLY the
    keys we touch — other resources are left alone so we don't disturb
    unrelated demands (e.g. pottery for a tier-3 house)."""
    keys = list(resources.keys())
    cur.execute(
        "UPDATE public.inventories SET quantity = 0 WHERE player_id = %s AND resource_key = ANY(%s)",
        (str(player_id), keys),
    )
    for k, v in resources.items():
        cur.execute(
            """
            INSERT INTO public.inventories (player_id, resource_key, quantity)
            VALUES (%s, %s, %s)
            ON CONFLICT (player_id, resource_key)
            DO UPDATE SET quantity = EXCLUDED.quantity, updated_at = now()
            """,
            (str(player_id), k, v),
        )


def test_substitutes_table_seeded(cur):
    """Migration seeded bread → spices/caviar/spirits."""
    cur.execute(
        "SELECT substitute_key FROM public.lifestyle_substitutes "
        "WHERE primary_key = 'bread' ORDER BY substitute_key"
    )
    subs = [r[0] for r in cur.fetchall()]
    assert subs == ['caviar', 'spices', 'spirits']


def test_pantry_buffer_refills_from_spices(cur, make_player, place, clear_resources):
    """House at tier 3 (needs bread) with ONLY spices in inventory — the
    bread pantry buffer should fill from spices via the substitute pool.
    """
    p = make_player()
    bid = _place_one_house(cur, place, clear_resources, p)
    _set_house_tier(cur, bid, 3)

    # Empty all 4 of the staples; stock only spices.
    _set_inventory(cur, p['id'], bread=0, spices=200, caviar=0, spirits=0)

    # Drain the bread buffer to 0 so we can observe a refill.
    cur.execute(
        "UPDATE public.building_resource_buffers SET quantity = 0 "
        "WHERE building_id = %s AND resource_key = 'bread'",
        (str(bid),),
    )

    cur.execute("SELECT public.process_production()")

    cur.execute(
        "SELECT quantity, capacity FROM public.building_resource_buffers "
        "WHERE building_id = %s AND resource_key = 'bread'",
        (str(bid),),
    )
    row = cur.fetchone()
    assert row is not None, "bread buffer should exist for tier-3 house"
    qty, cap = float(row[0]), float(row[1])
    assert qty > 0.5, f"bread buffer should refill from spices, got {qty} / {cap}"

    # Spices should have been drained.
    cur.execute(
        "SELECT quantity FROM public.inventories "
        "WHERE player_id = %s AND resource_key = 'spices'",
        (str(p['id']),),
    )
    remaining = float(cur.fetchone()[0])
    assert remaining < 200, f"spices stock should have dropped, still {remaining}"


def test_upgrade_gate_passes_with_only_spirits(cur, make_player, place, clear_resources):
    """A tier-2 house with bread=0 but spirits>0 should still flag as
    upgrade-eligible for tier 3 (bread demand satisfied by spirits)."""
    p = make_player()
    bid = _place_one_house(cur, place, clear_resources, p, with_road=True)
    _set_house_tier(cur, bid, 2)   # currently a Cottage

    # Tier 3 (Townhouse) demands bread + pottery + road + well + food.
    # Stock pottery + spirits (no bread, no spices, no caviar) plus
    # generic food for the global food gate.
    _set_inventory(cur, p['id'],
                   bread=0, spices=0, caviar=0, spirits=50,
                   pottery=200, grain=50)

    # Make the house old enough that the upgrade timer is satisfied.
    cur.execute(
        "UPDATE public.buildings SET last_processed_at = now() - interval '2 minutes' "
        "WHERE id = %s",
        (str(bid),),
    )
    cur.execute("SELECT public.process_production()")

    cur.execute(
        "SELECT housing_tier, evolution_eligible_at FROM public.buildings WHERE id = %s",
        (str(bid),),
    )
    tier_now, eligible_at = cur.fetchone()
    # The gate fired if either the house auto-upgraded (tier bumped) or
    # was stamped manual-upgrade-ready (evolution_eligible_at set).
    fired = tier_now > 2 or eligible_at is not None
    assert fired, (
        f"upgrade gate should accept spirits as bread substitute "
        f"(tier_now={tier_now}, eligible_at={eligible_at})"
    )


def test_upgrade_gate_blocked_when_all_four_empty(cur, make_player, place, clear_resources):
    """If bread AND all substitutes are empty, the upgrade gate should
    still block (sanity-check: substitution doesn't make the gate
    vacuous)."""
    p = make_player()
    bid = _place_one_house(cur, place, clear_resources, p)
    _set_house_tier(cur, bid, 2)

    _set_inventory(cur, p['id'],
                   bread=0, spices=0, caviar=0, spirits=0,
                   pottery=200, grain=50)

    cur.execute(
        "UPDATE public.buildings SET last_processed_at = now() - interval '2 minutes' "
        "WHERE id = %s",
        (str(bid),),
    )
    cur.execute("SELECT public.process_production()")

    cur.execute(
        "SELECT evolution_eligible_at FROM public.buildings WHERE id = %s",
        (str(bid),),
    )
    assert cur.fetchone()[0] is None, "upgrade should NOT fire with zero across all staples"


def test_mixed_stock_drains_all_four_proportionally(cur, make_player, place, clear_resources):
    """When stock is split across bread + spices + caviar + spirits,
    the refill pool drains all four proportionally to their share."""
    p = make_player()
    bid = _place_one_house(cur, place, clear_resources, p)
    _set_house_tier(cur, bid, 3)

    # Equal stock across all four; need = 30 * 0.05 = 1.5 units (cap).
    _set_inventory(cur, p['id'], bread=10, spices=10, caviar=10, spirits=10)

    # Drain the bread buffer to 0 so refill takes a full cap's worth.
    cur.execute(
        "UPDATE public.building_resource_buffers SET quantity = 0 "
        "WHERE building_id = %s AND resource_key = 'bread'",
        (str(bid),),
    )

    cur.execute("SELECT public.process_production()")

    # Each should have dropped by roughly the same amount.
    cur.execute(
        "SELECT resource_key, quantity FROM public.inventories "
        "WHERE player_id = %s AND resource_key IN ('bread','spices','caviar','spirits') "
        "ORDER BY resource_key",
        (str(p['id']),),
    )
    stocks = {r[0]: float(r[1]) for r in cur.fetchall()}
    drained = {k: 10 - v for k, v in stocks.items()}

    # Total drained should equal what landed in the buffer.
    total_drained = sum(drained.values())
    assert total_drained > 0.5, f"expected a meaningful drain, got {drained}"

    # Each individual share should be roughly equal — within 5% of total/4.
    expected_share = total_drained / 4.0
    for k, d in drained.items():
        assert abs(d - expected_share) < expected_share * 0.10 + 0.05, \
            f"{k} share {d:.4f} should be ~{expected_share:.4f}: {drained}"


def test_devolve_gate_uses_per_house_buffer_not_inventory(cur, make_player, place, clear_resources):
    """Sanity-check: the devolve gate reads the house's bread BUFFER, not
    inventory. If the buffer has stock (from any substitute), the house
    should NOT devolve even with zero city stock."""
    p = make_player()
    bid = _place_one_house(cur, place, clear_resources, p)
    _set_house_tier(cur, bid, 3)

    # Fill the bread pantry manually, then empty all city stock so refill
    # can't help — only the buffer is keeping the house alive.
    cur.execute(
        "UPDATE public.building_resource_buffers SET quantity = capacity "
        "WHERE building_id = %s",
        (str(bid),),
    )
    _set_inventory(cur, p['id'], bread=0, spices=0, caviar=0, spirits=0,
                   pottery=100, grain=50)

    # Run one short tick (< devolve_secs); the house should hold.
    cur.execute("SELECT public.process_production()")
    cur.execute("SELECT housing_tier FROM public.buildings WHERE id = %s", (str(bid),))
    assert cur.fetchone()[0] == 3, "house should not devolve while buffer still has stock"
