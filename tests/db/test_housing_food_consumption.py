
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


"""Tests for per-tick housing food consumption.

Active tier-1+ houses drain food from inventory at htc.food_per_minute per
house per minute. Drain is proportional across all is_food resources
(single multiplier on every food row). When food runs out, v_has_food
flips false and the existing devolve gate fires.
"""


def _stock(cur, player_id, **kv):
    for resource_key, qty in kv.items():
        cur.execute("""INSERT INTO public.inventories (player_id, resource_key, quantity)
                       VALUES (%s, %s, %s)
                       ON CONFLICT (player_id, resource_key) DO UPDATE SET quantity = EXCLUDED.quantity""",
                    (str(player_id), resource_key, qty))


def _backdate_food_tick(cur, player_id, secs):
    cur.execute("""UPDATE public.player_profiles
                   SET last_food_tick_at = now() - make_interval(secs => %s)
                   WHERE id = %s""", (secs, str(player_id)))


def _make_tier_1_house(cur, place, p, hx, hy):
    """Place a house, set it to tier 1. Stocks food first so the
    process_production tick doesn't immediately devolve it."""
    place('well', hx + 2, hy + 1)
    house_id = place('house', hx + 1, hy + 2)['building_id']
    cur.execute("UPDATE public.buildings SET housing_tier = 1 WHERE id = %s", (house_id,))
    return house_id


# ── consumption per tier ─────────────────────────────────────

def test_tier_0_house_drains_no_food(make_player, place, cur, clear_resources):
    """Shanty (tier 0) shouldn't drain food."""
    p = make_player()
    clear_resources(p['id'])
    hx, hy = p['home_x'], p['home_y']
    place('house', hx + 1, hy + 2)  # default tier 0
    _stock(cur, p['id'], grain=10.0)
    _backdate_food_tick(cur, p['id'], 60)

    _tick_and_upgrade_all(cur)
    cur.execute("SELECT quantity FROM public.inventories WHERE player_id = %s AND resource_key = 'grain'",
                (str(p['id']),))
    assert float(cur.fetchone()[0]) == 10.0, "shanty should not drain food"


def test_tier_1_house_does_not_drain_food(make_player, place, cur, clear_resources):
    """Mud hut is now water-only — no food consumption (food_per_minute = 0).
    Food drain begins at tier 2 (Cottage)."""
    p = make_player()
    clear_resources(p['id'])
    hx, hy = p['home_x'], p['home_y']
    _make_tier_1_house(cur, place, p, hx, hy)
    _stock(cur, p['id'], grain=10.0)
    _backdate_food_tick(cur, p['id'], 60)

    _tick_and_upgrade_all(cur)
    cur.execute("SELECT quantity FROM public.inventories WHERE player_id = %s AND resource_key = 'grain'",
                (str(p['id']),))
    grain = float(cur.fetchone()[0])
    assert grain == 10.0, f"mud hut should not drain food, got {grain}"


def test_tier_2_house_drains_food(make_player, place, cur, clear_resources):
    """Cottage at 0.24/min should drain ~0.24 food over 60s."""
    p = make_player()
    clear_resources(p['id'])
    hx, hy = p['home_x'], p['home_y']
    house_id = _make_tier_1_house(cur, place, p, hx, hy)
    cur.execute("UPDATE public.buildings SET housing_tier = 2 WHERE id = %s", (house_id,))
    _stock(cur, p['id'], grain=10.0)
    _backdate_food_tick(cur, p['id'], 60)

    _tick_and_upgrade_all(cur)
    cur.execute("SELECT quantity FROM public.inventories WHERE player_id = %s AND resource_key = 'grain'",
                (str(p['id']),))
    grain = float(cur.fetchone()[0])
    # 0.24/min × 1 min = 0.24 drained
    assert 9.74 < grain < 9.78, f"expected ~9.76 grain after 0.24 drain, got {grain}"


# ── multi-food drain ─────────────────────────────────────────

def test_drain_proportional_across_food_resources(make_player, place, cur, clear_resources):
    """Drain should be proportional. With 60 grain + 30 flour + 10 bread
    (total 100) and a need of 1.0, drain ~0.6 grain, ~0.3 flour, ~0.1 bread."""
    p = make_player()
    clear_resources(p['id'])
    hx, hy = p['home_x'], p['home_y']
    house_id = _make_tier_1_house(cur, place, p, hx, hy)
    cur.execute("UPDATE public.buildings SET housing_tier = 5 WHERE id = %s", (house_id,))
    # tier 5 = 1.0/min, over 60s = 1.0 food needed
    _stock(cur, p['id'], grain=60.0, flour=30.0, bread=10.0)
    _backdate_food_tick(cur, p['id'], 60)

    _tick_and_upgrade_all(cur)
    cur.execute("""SELECT resource_key, quantity FROM public.inventories
                   WHERE player_id = %s AND resource_key IN ('grain', 'flour', 'bread')
                   ORDER BY resource_key""", (str(p['id']),))
    rows = {r[0]: float(r[1]) for r in cur.fetchall()}
    # Phase 1 — proportional food drain: total need 1.0, drain proportions
    # 0.6 grain + 0.3 flour + 0.1 bread. After this: grain 59.4, flour
    # 29.7, bread 9.9.
    # Phase 2 — cumulative lifestyle drain at tier 5: bread is a T3-
    # onward lifestyle good. T5 rate was 0.10/min, halved to 0.05/min
    # by the 2026-05-21 bread-demand halving (Drew's bug 20203301).
    # 0.05/min × 1 min = 0.05 drain. After both phases: bread 9.85.
    # Pottery/furniture/statuary aren't stocked so those lifestyle rows
    # skip with no effect on this test.
    assert 59.3 < rows['grain'] < 59.5, f"grain expected ~59.4, got {rows['grain']}"
    assert 29.6 < rows['flour'] < 29.8, f"flour expected ~29.7, got {rows['flour']}"
    assert 9.80 < rows['bread'] < 9.90, f"bread expected ~9.85 (food+halved lifestyle), got {rows['bread']}"


# ── starvation devolve ───────────────────────────────────────

def test_house_devolves_when_drain_empties_food(make_player, place, cur, clear_resources):
    """A tier-2 cottage whose food pantry is empty AND has no city stock
    to refill from devolves on the next eligibility tick.

    Updated 2026-05-09: per-house buffers absorb a brief city-stock
    shortage. To reach the devolve state the test now explicitly empties
    the house's food buffer in addition to the city pool. (Old test
    relied on city-stock=0 alone forcing immediate devolve; that's no
    longer the model.)"""
    p = make_player()
    clear_resources(p['id'])
    hx, hy = p['home_x'], p['home_y']
    house_id = _make_tier_1_house(cur, place, p, hx, hy)
    cur.execute("UPDATE public.buildings SET housing_tier = 2 WHERE id = %s", (house_id,))
    _stock(cur, p['id'], grain=0.0)
    cur.execute(
        "UPDATE public.building_resource_buffers SET quantity = 0 "
        "WHERE building_id = %s AND resource_key = 'food'",
        (house_id,)
    )
    _backdate_food_tick(cur, p['id'], 60)
    cur.execute("""UPDATE public.buildings
                   SET last_processed_at = now() - interval '120 seconds'
                   WHERE id = %s""", (house_id,))

    _tick_and_upgrade_all(cur)
    cur.execute("SELECT housing_tier FROM public.buildings WHERE id = %s", (house_id,))
    tier = cur.fetchone()[0]
    assert tier == 1, f"cottage should have devolved from 2 to 1, got tier {tier}"


# ── rate scales with house count ─────────────────────────────

def test_drain_scales_with_house_count(make_player, place, cur, clear_resources):
    """Two tier-2 cottages should drain twice as much as one."""
    p = make_player()
    clear_resources(p['id'])
    hx, hy = p['home_x'], p['home_y']
    place('well', hx + 2, hy + 1)
    h1 = place('house', hx + 1, hy + 2)['building_id']
    h2 = place('house', hx + 3, hy + 2)['building_id']
    cur.execute("UPDATE public.buildings SET housing_tier = 2 WHERE id IN (%s, %s)", (h1, h2))
    _stock(cur, p['id'], grain=10.0)
    _backdate_food_tick(cur, p['id'], 60)

    _tick_and_upgrade_all(cur)
    cur.execute("SELECT quantity FROM public.inventories WHERE player_id = %s AND resource_key = 'grain'",
                (str(p['id']),))
    grain = float(cur.fetchone()[0])
    # 2 houses × 0.24 = 0.48 drained
    assert 9.49 < grain < 9.55, f"expected ~9.52 grain after 2-house drain, got {grain}"


# ── last_food_tick_at updates ────────────────────────────────

def test_last_food_tick_advances(make_player, place, cur, clear_resources):
    """last_food_tick_at should be set to v_now after each process_production."""
    p = make_player()
    clear_resources(p['id'])
    _backdate_food_tick(cur, p['id'], 60)
    _tick_and_upgrade_all(cur)
    cur.execute("""SELECT EXTRACT(EPOCH FROM (now() - last_food_tick_at))
                   FROM public.player_profiles WHERE id = %s""", (str(p['id']),))
    secs = float(cur.fetchone()[0])
    assert secs < 1, f"last_food_tick_at should have just been updated, but it's {secs}s ago"


# ── paused house doesn't drain ───────────────────────────────

def test_paused_house_drains_no_food(make_player, place, cur, clear_resources):
    """Paused buildings drop out of every loop, including the food drain."""
    p = make_player()
    clear_resources(p['id'])
    hx, hy = p['home_x'], p['home_y']
    house_id = _make_tier_1_house(cur, place, p, hx, hy)
    cur.execute("UPDATE public.buildings SET status = 'paused' WHERE id = %s", (house_id,))
    _stock(cur, p['id'], grain=10.0)
    _backdate_food_tick(cur, p['id'], 60)

    _tick_and_upgrade_all(cur)
    cur.execute("SELECT quantity FROM public.inventories WHERE player_id = %s AND resource_key = 'grain'",
                (str(p['id']),))
    grain = float(cur.fetchone()[0])
    assert grain == 10.0, f"paused house should not drain food, got {grain}"
