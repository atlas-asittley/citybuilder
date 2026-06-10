"""Tests for the well precondition + tax revenue building."""
import pytest
import psycopg2

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




def test_well_required_for_tier_1_evolution(make_player, place, cur, clear_resources):
    """Without a well in range, a shanty should NOT upgrade to mud hut even
    if it has road access and elapsed time. With a well, it should."""
    p = make_player()
    clear_resources(p['id'])
    hx, hy = p['home_x'], p['home_y']
    place('road', hx + 1, hy + 1)
    house_id = place('house', hx + 1, hy + 2)['building_id']
    cur.execute("""INSERT INTO public.inventories (player_id, resource_key, quantity)
                   VALUES (%s, 'grain', 5.0)
                   ON CONFLICT (player_id, resource_key) DO UPDATE SET quantity = 5.0""",
                (str(p['id']),))
    cur.execute(
        "UPDATE public.buildings SET last_processed_at = now() - interval '120 seconds' WHERE id = %s",
        (house_id,),
    )
    _tick_and_upgrade_all(cur)
    cur.execute("SELECT housing_tier FROM public.buildings WHERE id = %s", (house_id,))
    assert cur.fetchone()[0] == 0, "house upgraded to tier 1 without a well in range"

    # Now drop a well within range and re-run.
    place('well', hx + 2, hy + 2)
    cur.execute(
        "UPDATE public.buildings SET last_processed_at = now() - interval '120 seconds' WHERE id = %s",
        (house_id,),
    )
    _tick_and_upgrade_all(cur)
    cur.execute("SELECT housing_tier FROM public.buildings WHERE id = %s", (house_id,))
    assert cur.fetchone()[0] == 1, "house failed to upgrade with a well in range"


def test_well_too_far_for_tier_2_evolution(make_player, place, cur, clear_resources):
    """Tier 2+ evolution still requires positional well coverage (within
    4 manhattan) per the post-2026-05-07 balance change. Tier 1 only
    needs ANY well in district — that case is tested elsewhere."""
    p = make_player()
    clear_resources(p['id'])
    # Stock food so the tier 1 → 2 gate's needs_food is satisfied.
    cur.execute(
        "INSERT INTO public.inventories (player_id, resource_key, quantity) "
        "VALUES (%s, 'berries', 50) "
        "ON CONFLICT (player_id, resource_key) DO UPDATE SET quantity = 50",
        (str(p['id']),),
    )
    hx, hy = p['home_x'], p['home_y']
    place('road', hx + 1, hy + 1)
    place('well', hx + 6, hy + 6)  # Manhattan distance 10 from house
    house_id = place('house', hx + 1, hy + 2)['building_id']
    # Start at tier 1 so the gate we're testing is tier 1 → 2.
    cur.execute("UPDATE public.buildings SET housing_tier = 1 WHERE id = %s",
                (house_id,))
    cur.execute(
        "UPDATE public.buildings SET last_processed_at = now() - interval '180 seconds' WHERE id = %s",
        (house_id,),
    )
    _tick_and_upgrade_all(cur)
    cur.execute("SELECT housing_tier FROM public.buildings WHERE id = %s", (house_id,))
    assert cur.fetchone()[0] == 1, "tier-2 evolution should require positional well coverage"


def test_tax_man_credits_money_when_staffed(make_player, place, cur, clear_resources):
    """Staffed tax_man should add money to the player's profile after a tick.
    We need ≥10 workers to staff it; a tier-2 cottage covers that on its own."""
    p = make_player()
    clear_resources(p['id'])
    hx, hy = p['home_x'], p['home_y']
    place('road', hx + 1, hy + 1)
    place('well', hx + 2, hy + 2)
    house_id = place('house', hx + 1, hy + 2)['building_id']
    # Force the house to tier 2 (cottage = 10 workers) so the tax_man can be staffed.
    cur.execute("UPDATE public.buildings SET housing_tier = 2 WHERE id = %s", (house_id,))
    cur.execute(
        "UPDATE public.player_profiles SET money = 1000, population = 200 WHERE id = %s",
        (str(p['id']),),
    )
    place('tax_man', hx + 1, hy + 3)
    # Backdate so process_production sees ~60 seconds of elapsed tax-collection.
    cur.execute("""
        UPDATE public.buildings SET last_processed_at = now() - interval '60 seconds'
        WHERE player_id = %s
    """, (str(p['id']),))
    cur.execute("SELECT money FROM public.player_profiles WHERE id = %s", (str(p['id']),))
    money_before = cur.fetchone()[0]
    _tick_and_upgrade_all(cur)
    cur.execute("SELECT money FROM public.player_profiles WHERE id = %s", (str(p['id']),))
    money_after = cur.fetchone()[0]
    assert money_after > money_before, \
        f"tax_man did not credit money (before={money_before}, after={money_after})"


def test_tax_man_credits_nothing_when_unstaffed(make_player, place, cur, clear_resources):
    """If worker supply isn't enough to staff the tax_man, no money is credited."""
    # population=0 so the staffing pass has nothing to work with. The
    # default 100-pop conftest seed would auto-staff the tax_man.
    p = make_player(population=0)
    clear_resources(p['id'])
    hx, hy = p['home_x'], p['home_y']
    place('road', hx + 1, hy + 1)
    # Force worker_capacity well below the tax_man's worker_cost (10).
    cur.execute(
        "UPDATE public.player_profiles SET worker_capacity = 0, population = 0, money = 1000 WHERE id = %s",
        (str(p['id']),),
    )
    place('tax_man', hx + 1, hy + 2)
    cur.execute("""
        UPDATE public.buildings SET last_processed_at = now() - interval '60 seconds'
        WHERE player_id = %s
    """, (str(p['id']),))
    cur.execute("SELECT money FROM public.player_profiles WHERE id = %s", (str(p['id']),))
    money_before = cur.fetchone()[0]
    _tick_and_upgrade_all(cur)
    cur.execute("SELECT money FROM public.player_profiles WHERE id = %s", (str(p['id']),))
    money_after = cur.fetchone()[0]
    assert money_after == money_before, \
        "unstaffed tax_man should not generate money"
