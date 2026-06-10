"""Test that _pp_evolve_housing populates last_devolve_reason +
last_devolve_at + last_devolve_from_tier when a house devolves.

Atlas (2026-05-10): "for the inspector for the house, it should
tell you the reason the house downgraded the last time it
downgraded."
"""


def _set_house_tier(cur, building_id, tier):
    cur.execute(
        "UPDATE public.buildings SET housing_tier = %s, last_processed_at = now() WHERE id = %s",
        (tier, str(building_id))
    )


def _place_with_well(cur, place, clear_resources, p):
    clear_resources(p['id'])
    hx, hy = p['home_x'], p['home_y']
    place('well', hx + 1, hy + 1)
    return place('house', hx + 1, hy + 2)['building_id']


def test_lifestyle_devolve_records_resource_specific_reason(
    make_player, place, cur, clear_resources
):
    """Drain a tier-2 cottage's pottery buffer + age it past devolve_secs.
    The devolve should fire and stamp `lifestyle:pottery` as the
    reason."""
    p = make_player()
    bid = _place_with_well(cur, place, clear_resources, p)
    _set_house_tier(cur, bid, 2)
    # Force the pantry empty + grace period elapsed.
    cur.execute(
        "UPDATE public.building_resource_buffers SET quantity = 0 "
        "WHERE building_id = %s AND resource_key = 'pottery'",
        (str(bid),)
    )
    cur.execute(
        "DELETE FROM public.inventories WHERE player_id = %s AND resource_key = 'pottery'",
        (str(p['id']),)
    )
    cur.execute(
        "UPDATE public.buildings SET last_processed_at = now() - interval '120 seconds' WHERE id = %s",
        (str(bid),)
    )
    cur.execute(
        "UPDATE public.player_profiles SET last_food_tick_at = now() WHERE id = %s",
        (str(p['id']),)
    )

    cur.execute("SELECT public.process_production()")

    cur.execute(
        "SELECT housing_tier, last_devolve_reason, last_devolve_from_tier, "
        "       last_devolve_at IS NOT NULL "
        "FROM public.buildings WHERE id = %s",
        (str(bid),)
    )
    tier, reason, from_tier, has_ts = cur.fetchone()
    assert tier == 1, f"expected devolve to tier 1, got {tier}"
    assert reason == 'lifestyle:pottery', f"expected lifestyle:pottery, got {reason}"
    assert from_tier == 2, f"expected from_tier=2, got {from_tier}"
    assert has_ts, "last_devolve_at should be set"


def test_food_devolve_records_food_reason(
    make_player, place, cur, clear_resources
):
    """A tier-2 cottage with empty food buffer + empty city food
    devolves and stamps 'food' as the reason."""
    p = make_player()
    bid = _place_with_well(cur, place, clear_resources, p)
    _set_house_tier(cur, bid, 2)
    cur.execute(
        "UPDATE public.building_resource_buffers SET quantity = 0 "
        "WHERE building_id = %s AND resource_key = 'food'",
        (str(bid),)
    )
    # Wipe all food from inventory so refill can't help.
    cur.execute(
        "DELETE FROM public.inventories WHERE player_id = %s AND resource_key IN ("
        "  SELECT key FROM public.resources WHERE is_food)",
        (str(p['id']),)
    )
    # Keep pottery (lifestyle) stocked so food is the failing gate.
    cur.execute(
        "INSERT INTO public.inventories (player_id, resource_key, quantity) "
        "VALUES (%s, 'pottery', 100) "
        "ON CONFLICT (player_id, resource_key) DO UPDATE SET quantity = 100",
        (str(p['id']),)
    )
    cur.execute(
        "UPDATE public.buildings SET last_processed_at = now() - interval '120 seconds' WHERE id = %s",
        (str(bid),)
    )
    cur.execute(
        "UPDATE public.player_profiles SET last_food_tick_at = now() WHERE id = %s",
        (str(p['id']),)
    )

    cur.execute("SELECT public.process_production()")

    cur.execute(
        "SELECT housing_tier, last_devolve_reason FROM public.buildings WHERE id = %s",
        (str(bid),)
    )
    tier, reason = cur.fetchone()
    assert tier == 1, f"expected devolve to tier 1, got {tier}"
    assert reason == 'food', f"expected reason='food', got {reason}"


def test_no_devolve_leaves_columns_null(
    make_player, place, cur, clear_resources
):
    """A house that hasn't devolved keeps NULL on all three columns —
    the inspector hides the section based on these being null."""
    p = make_player()
    bid = _place_with_well(cur, place, clear_resources, p)
    cur.execute(
        "SELECT last_devolve_reason, last_devolve_at, last_devolve_from_tier "
        "FROM public.buildings WHERE id = %s",
        (str(bid),)
    )
    reason, ts, from_tier = cur.fetchone()
    assert reason is None and ts is None and from_tier is None, (
        f"new house should have NULL devolve fields, got {reason} / {ts} / {from_tier}"
    )
