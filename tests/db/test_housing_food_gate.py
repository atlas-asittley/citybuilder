
def _tick_and_upgrade_all(cur):
    """process_production + auto-step every now-eligible house. Mirrors
    what the player does in the UI (the click on the Upgrade button)
    so tests written against the pre-2026-05-08 auto-upgrade flow stay
    truthful. Safe to call even when nothing is eligible."""
    cur.execute("SELECT public.process_production()")
    cur.execute("SELECT id FROM public.buildings WHERE evolution_eligible_at IS NOT NULL")
    for (bid,) in cur.fetchall():
        cur.execute("SAVEPOINT __tu")
        try:
            cur.execute("SELECT public.upgrade_house(%s)", (str(bid),))
            cur.execute("RELEASE SAVEPOINT __tu")
        except Exception:
            cur.execute("ROLLBACK TO SAVEPOINT __tu")


"""Tests for the housing food gate.

Tier 2+ housing requires "any food" in inventory (resources.is_food = true).
Today that's grain, flour, bread, etc. The check is presence-only — at least
one food resource must be > 0. Without food, tier 2+ housing won't evolve
and existing tier 2+ housing devolves. Tier 1 (Mud Hut) only needs water
(a well within range); food enters the picture at tier 2.
"""


def _set_inventory(cur, player_id, **stocks):
    """Replace the player's inventory with the given stocks. Wipes everything else."""
    cur.execute("DELETE FROM public.inventories WHERE player_id = %s", (str(player_id),))
    for resource_key, qty in stocks.items():
        cur.execute("""
            INSERT INTO public.inventories (player_id, resource_key, quantity)
            VALUES (%s, %s, %s)
        """, (str(player_id), resource_key, qty))


def _backdate(cur, player_id, secs):
    cur.execute("""
        UPDATE public.buildings SET last_processed_at = now() - make_interval(secs => %s)
        WHERE player_id = %s
    """, (secs, str(player_id)))


def test_shanty_to_mud_hut_only_needs_water(make_player, place, cur, clear_resources):
    """Tier 0 → tier 1 only requires a well within range. Food is not
    needed at this step — tier 1 is the "water-only" rung."""
    p = make_player()
    clear_resources(p['id'])
    hx, hy = p['home_x'], p['home_y']
    place('well', hx + 2, hy + 1)
    house_id = place('house', hx + 1, hy + 2)['building_id']  # tier 0 by default
    _set_inventory(cur, p['id'])  # explicitly empty — no food
    _backdate(cur, p['id'], 60)

    _tick_and_upgrade_all(cur)
    cur.execute("SELECT housing_tier FROM public.buildings WHERE id = %s", (house_id,))
    assert cur.fetchone()[0] == 1, "shanty should upgrade to mud hut on water alone"


def test_mud_hut_to_cottage_blocked_without_food(make_player, place, cur, clear_resources):
    """Tier 1 → 2 needs food (the gate that previously sat at tier 1)."""
    p = make_player()
    clear_resources(p['id'])
    hx, hy = p['home_x'], p['home_y']
    place('well', hx + 2, hy + 1)
    house_id = place('house', hx + 1, hy + 2)['building_id']
    cur.execute("UPDATE public.buildings SET housing_tier = 1 WHERE id = %s", (house_id,))
    _set_inventory(cur, p['id'])
    _backdate(cur, p['id'], 120)
    _tick_and_upgrade_all(cur)
    cur.execute("SELECT housing_tier FROM public.buildings WHERE id = %s", (house_id,))
    assert cur.fetchone()[0] == 1, "mud hut should not upgrade to cottage without food"


def test_shanty_to_mud_hut_succeeds_with_grain_only(make_player, place, cur, clear_resources):
    """Raw grain alone (no flour, no bread) is sufficient — any food works."""
    p = make_player()
    clear_resources(p['id'])
    hx, hy = p['home_x'], p['home_y']
    place('well', hx + 2, hy + 1)
    house_id = place('house', hx + 1, hy + 2)['building_id']
    _set_inventory(cur, p['id'], grain=5.0)
    _backdate(cur, p['id'], 60)

    _tick_and_upgrade_all(cur)
    cur.execute("SELECT housing_tier FROM public.buildings WHERE id = %s", (house_id,))
    assert cur.fetchone()[0] == 1, "shanty failed to upgrade with grain in stock"


def test_shanty_to_mud_hut_succeeds_with_bread_only(make_player, place, cur, clear_resources):
    p = make_player()
    clear_resources(p['id'])
    hx, hy = p['home_x'], p['home_y']
    place('well', hx + 2, hy + 1)
    house_id = place('house', hx + 1, hy + 2)['building_id']
    _set_inventory(cur, p['id'], bread=3.0)
    _backdate(cur, p['id'], 60)

    _tick_and_upgrade_all(cur)
    cur.execute("SELECT housing_tier FROM public.buildings WHERE id = %s", (house_id,))
    assert cur.fetchone()[0] == 1, "shanty failed to upgrade with bread in stock"


def test_non_food_resource_does_not_satisfy_food_gate(make_player, place, cur, clear_resources):
    """Stockpiles of non-food resources (lumber, brick, etc.) shouldn't count.
    Tier 1 (Mud Hut) doesn't need food, but tier 2 (Cottage) does — so a
    tier-1 mud hut with only non-food items stays at tier 1, not upgrading
    to cottage."""
    p = make_player()
    clear_resources(p['id'])
    hx, hy = p['home_x'], p['home_y']
    place('well', hx + 2, hy + 1)
    house_id = place('house', hx + 1, hy + 2)['building_id']
    cur.execute("UPDATE public.buildings SET housing_tier = 1 WHERE id = %s", (house_id,))
    _set_inventory(cur, p['id'], lumber=100.0, brick=100.0, statuary=50.0)
    _backdate(cur, p['id'], 120)

    _tick_and_upgrade_all(cur)
    cur.execute("SELECT housing_tier FROM public.buildings WHERE id = %s", (house_id,))
    assert cur.fetchone()[0] == 1, "non-food resources should not satisfy tier-2 food gate"


def test_cottage_devolves_when_food_runs_out(make_player, place, cur, clear_resources):
    """A tier-2 cottage with no food in stock AND an empty pantry should
    devolve to tier 1 mud hut. The pantry is drained explicitly because
    after the per-house buffer rework (2026-05-09), city food = 0 alone
    no longer triggers an immediate devolve — the pantry has to deplete
    first. This test still verifies the end-state: when both city stock
    AND the per-house buffer are empty, the devolve gate fires."""
    p = make_player()
    clear_resources(p['id'])
    hx, hy = p['home_x'], p['home_y']
    place('well', hx + 2, hy + 1)
    house_id = place('house', hx + 1, hy + 2)['building_id']
    cur.execute("UPDATE public.buildings SET housing_tier = 2 WHERE id = %s", (house_id,))
    _set_inventory(cur, p['id'])  # no food in city
    # Drain the per-house food pantry too, so the devolve gate has nothing
    # to fall back on.
    cur.execute(
        "UPDATE public.building_resource_buffers SET quantity = 0 "
        "WHERE building_id = %s AND resource_key = 'food'",
        (house_id,)
    )
    _backdate(cur, p['id'], 240)
    _tick_and_upgrade_all(cur)
    cur.execute("SELECT housing_tier FROM public.buildings WHERE id = %s", (house_id,))
    assert cur.fetchone()[0] == 1, "cottage should devolve to mud hut when food runs out"


def test_shanty_does_not_need_food(make_player, place, cur, clear_resources):
    """Tier 0 shanty should NOT need food — it's the subsistence floor.
    A house already at tier 0 should not be flagged for any change just
    because food is absent.
    """
    p = make_player()
    clear_resources(p['id'])
    hx, hy = p['home_x'], p['home_y']
    house_id = place('house', hx + 1, hy + 2)['building_id']
    # Tier 0 with no road, no well, no food — should stay at 0 (no devolve, no upgrade)
    _set_inventory(cur, p['id'])
    _backdate(cur, p['id'], 120)

    _tick_and_upgrade_all(cur)
    cur.execute("SELECT housing_tier FROM public.buildings WHERE id = %s", (house_id,))
    assert cur.fetchone()[0] == 0, "shanty should remain at tier 0 with no food"
