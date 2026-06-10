"""Tests for the four citizen-service buildings (tavern, bathhouse, school, temple).

Each consumes a unique pair of resources while staffed, and each provides a
different effect when "operating" (staffed AND both inputs available).
"""
import pytest

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




def _stock(cur, player_id, resource_key, qty):
    """Set a player's inventory for one resource."""
    cur.execute("""
        INSERT INTO public.inventories (player_id, resource_key, quantity)
        VALUES (%s, %s, %s)
        ON CONFLICT (player_id, resource_key) DO UPDATE SET quantity = EXCLUDED.quantity
    """, (str(player_id), resource_key, qty))


def _backdate(cur, player_id, secs):
    cur.execute("""
        UPDATE public.buildings SET last_processed_at = now() - make_interval(secs => %s)
        WHERE player_id = %s
    """, (secs, str(player_id)))


def _give_lots_of_workers(cur, player_id):
    """Bypass housing-driven worker supply for tests that just want enough workers.
    process_production reads population (not worker_capacity) for staffing decisions,
    so set both. process_production will clamp population down to actual target each
    tick — by that time staffing has already been decided for the current tick."""
    cur.execute("""UPDATE public.player_profiles
                   SET worker_capacity = 100, population = 100
                   WHERE id = %s""",
                (str(player_id),))


def _give_money(cur, player_id, amount=5000):
    cur.execute("UPDATE public.player_profiles SET money = %s WHERE id = %s",
                (amount, str(player_id)))


# ── multi-input charging ────────────────────────────────────────

def test_tavern_consumes_both_inputs(make_player, place, cur, clear_resources):
    p = make_player()
    clear_resources(p['id'])
    hx, hy = p['home_x'], p['home_y']
    place('road', hx + 1, hy + 1)
    place('tavern', hx + 1, hy + 2)
    _give_lots_of_workers(cur, p['id'])
    _stock(cur, p['id'], 'bread', 5.0)
    _stock(cur, p['id'], 'pottery', 5.0)
    _backdate(cur, p['id'], 60)

    _tick_and_upgrade_all(cur)

    cur.execute("SELECT quantity FROM public.inventories WHERE player_id = %s AND resource_key = 'bread'",
                (str(p['id']),))
    bread_after = float(cur.fetchone()[0])
    cur.execute("SELECT quantity FROM public.inventories WHERE player_id = %s AND resource_key = 'pottery'",
                (str(p['id']),))
    pottery_after = float(cur.fetchone()[0])
    # input_rate = 0.5/min, elapsed = 60s, so charge ≈ 0.5
    assert 4.4 < bread_after < 4.6, f"bread should drop ~0.5, got {bread_after}"
    assert 4.4 < pottery_after < 4.6, f"pottery should drop ~0.5, got {pottery_after}"


def test_tavern_consumes_nothing_when_one_input_missing(make_player, place, cur, clear_resources):
    """If only one of the two inputs is available, the tavern stays idle and
    consumes neither — preventing waste of the partial input."""
    p = make_player()
    clear_resources(p['id'])
    hx, hy = p['home_x'], p['home_y']
    place('road', hx + 1, hy + 1)
    place('tavern', hx + 1, hy + 2)
    _give_lots_of_workers(cur, p['id'])
    _stock(cur, p['id'], 'bread', 5.0)
    _stock(cur, p['id'], 'pottery', 0)
    _backdate(cur, p['id'], 60)

    _tick_and_upgrade_all(cur)

    cur.execute("SELECT quantity FROM public.inventories WHERE player_id = %s AND resource_key = 'bread'",
                (str(p['id']),))
    bread_after = float(cur.fetchone()[0])
    assert bread_after == 5.0, f"bread should not drop when pottery is missing, got {bread_after}"


# ── tavern worker bonus ─────────────────────────────────────────
# Removed 2026-05-08: the +10-workers-from-a-fed-tavern mechanic was
# pulled because it confused players (fed tavern adds workers you
# don't have housing for → math doesn't reconcile). The Tavern still
# provides a +5% productivity bonus and a small crime hit; tests for
# those live in test_productivity / test_crime, not here.


# ── school gates townhouse (tier 3) ─────────────────────────────

def test_school_required_for_tier_4_evolution(make_player, place, cur, clear_resources):
    """A townhouse (tier 3) cannot upgrade to villa (tier 4) without an
    operating school within 5 tiles. With a fed school, it can. (School
    moved from the tier-3 gate to the tier-4 gate as part of the slow-
    steady upgrade ladder: T3 adds road, T4 adds school.)
    """
    p = make_player()
    clear_resources(p['id'])
    _give_money(cur, p['id'])
    hx, hy = p['home_x'], p['home_y']
    place('well', hx + 2, hy + 1)
    house_id = place('house', hx + 1, hy + 2)['building_id']
    cur.execute("UPDATE public.buildings SET housing_tier = 3 WHERE id = %s", (house_id,))
    _give_lots_of_workers(cur, p['id'])
    _stock(cur, p['id'], 'grain', 10.0)
    # Cumulative lifestyle demands: T3 needs pottery+bread, T4 adds
    # furniture. Stock all three up front so the only thing being tested
    # here is the school gate.
    _stock(cur, p['id'], 'pottery', 10.0)
    _stock(cur, p['id'], 'bread', 10.0)
    _stock(cur, p['id'], 'furniture', 10.0)
    _backdate(cur, p['id'], 240)

    # No school yet → should stay at tier 3.
    _tick_and_upgrade_all(cur)
    cur.execute("SELECT housing_tier FROM public.buildings WHERE id = %s", (house_id,))
    assert cur.fetchone()[0] == 3, "townhouse upgraded past tier 3 without a school"

    # Place + feed a school in range.
    place('school', hx + 1, hy + 3)
    _give_lots_of_workers(cur, p['id'])
    _stock(cur, p['id'], 'lumber', 5.0)
    _stock(cur, p['id'], 'flour', 5.0)
    _stock(cur, p['id'], 'grain', 10.0)
    _stock(cur, p['id'], 'pottery', 10.0)
    _stock(cur, p['id'], 'bread', 10.0)
    _stock(cur, p['id'], 'furniture', 10.0)
    _backdate(cur, p['id'], 240)
    _tick_and_upgrade_all(cur)
    cur.execute("SELECT housing_tier FROM public.buildings WHERE id = %s", (house_id,))
    assert cur.fetchone()[0] == 4, "townhouse failed to upgrade with school in range"


def test_unfed_school_does_not_unlock_tier_4(make_player, place, cur, clear_resources):
    """A school that's been built but has no inputs in stock should NOT
    qualify housing for the tier-4 gate (even though it's staffed and on
    a road). School moved from T3 → T4."""
    p = make_player()
    clear_resources(p['id'])
    _give_money(cur, p['id'])
    hx, hy = p['home_x'], p['home_y']
    place('well', hx + 2, hy + 1)
    house_id = place('house', hx + 1, hy + 2)['building_id']
    cur.execute("UPDATE public.buildings SET housing_tier = 3 WHERE id = %s", (house_id,))
    place('school', hx + 1, hy + 3)
    _give_lots_of_workers(cur, p['id'])
    _stock(cur, p['id'], 'lumber', 0)
    _stock(cur, p['id'], 'flour', 0)
    # Stock food + cumulative T3 lifestyle (pottery+bread) so the only
    # thing being tested is the school feed. We deliberately leave
    # furniture OUT — even if some other gate magically passed, T4 still
    # needs it.
    _stock(cur, p['id'], 'grain', 10.0)
    _stock(cur, p['id'], 'pottery', 10.0)
    _stock(cur, p['id'], 'bread', 10.0)
    _backdate(cur, p['id'], 240)

    _tick_and_upgrade_all(cur)
    cur.execute("SELECT housing_tier FROM public.buildings WHERE id = %s", (house_id,))
    assert cur.fetchone()[0] == 3, "unfed school should not unlock tier 4"


# ── bathhouse blocks devolve ────────────────────────────────────

def _bathhouse_layout(make_player, place, cur, clear_resources):
    """Shared setup for the bathhouse devolve-blocking tests.

    Layout (highway runs through (hx, *) and (*, hy)):
      provider  (hx-1, hy-1) tier-2 cottage; via highway, well within 4 → stays
                              staffed regardless of pauses, supplies 10 workers
      well      (hx-1, hy+2) via highway, gates both houses at tier 1+
      bathhouse (hx+1, hy+3) via highway, distance 2 from test house
      road1     (hx+2, hy+1) the only road giving the test house access
      house     (hx+2, hy+2) tier-1; off-highway; loses road when road1 is paused
    """
    p = make_player()
    clear_resources(p['id'])
    _give_money(cur, p['id'])
    hx, hy = p['home_x'], p['home_y']
    provider_id = place('house', hx - 1, hy - 1)['building_id']
    cur.execute("UPDATE public.buildings SET housing_tier = 2 WHERE id = %s", (provider_id,))
    place('road', hx + 2, hy + 1)
    place('well', hx - 1, hy + 2)
    place('bathhouse', hx + 1, hy + 3)
    house_id = place('house', hx + 2, hy + 2)['building_id']
    # Use tier 3 (Townhouse) since that's the lowest tier that requires
    # road access — pausing road1 then triggers a road-loss devolve.
    cur.execute("UPDATE public.buildings SET housing_tier = 3 WHERE id = %s", (house_id,))
    # Force pop high so well + bathhouse stay staffed (the symmetric
    # population model fills gradually, but tests want immediate
    # staffing — process_production will clamp to actual target).
    cur.execute("UPDATE public.player_profiles SET population = 100 WHERE id = %s", (str(p['id']),))
    return p, hx, hy, house_id


def test_bathhouse_blocks_devolve(make_player, place, cur, clear_resources):
    """A house that loses its road access would normally devolve. With a
    fed bathhouse in range, the devolve is blocked."""
    p, hx, hy, house_id = _bathhouse_layout(make_player, place, cur, clear_resources)
    _stock(cur, p['id'], 'brick', 5.0)
    _stock(cur, p['id'], 'clay', 5.0)
    cur.execute("""
        UPDATE public.buildings SET status = 'paused'
        WHERE player_id = %s AND building_type_key = 'road' AND x = %s AND y = %s
    """, (str(p['id']), hx + 2, hy + 1))
    _backdate(cur, p['id'], 120)

    _tick_and_upgrade_all(cur)
    cur.execute("SELECT housing_tier FROM public.buildings WHERE id = %s", (house_id,))
    assert cur.fetchone()[0] == 3, "bathhouse should have prevented devolve"


def test_unfed_bathhouse_does_not_block_devolve(make_player, place, cur, clear_resources):
    """Same layout as above, but no inputs in stock → bathhouse not operating
    → house should devolve normally."""
    p, hx, hy, house_id = _bathhouse_layout(make_player, place, cur, clear_resources)
    _stock(cur, p['id'], 'brick', 0)
    _stock(cur, p['id'], 'clay', 0)
    cur.execute("""
        UPDATE public.buildings SET status = 'paused'
        WHERE player_id = %s AND building_type_key = 'road' AND x = %s AND y = %s
    """, (str(p['id']), hx + 2, hy + 1))
    _backdate(cur, p['id'], 120)

    _tick_and_upgrade_all(cur)
    cur.execute("SELECT housing_tier FROM public.buildings WHERE id = %s", (house_id,))
    assert cur.fetchone()[0] == 2, "unfed bathhouse should not have prevented devolve from 3 to 2"


# ── Chebyshev proximity (2026-05-20) ────────────────────────────
# A school 2 right + 4 up from a townhouse is at Manhattan 6, Chebyshev
# 4. Under the old Manhattan gate the upgrade was silently refused (Jill
# bug 7df760b0). Under Chebyshev (king's-move) the school covers an
# 11×11 square, and the townhouse upgrades.

def test_school_uses_chebyshev_distance(make_player, place, cur, clear_resources):
    """Townhouse at +2,+4 from a school: Manhattan=6, Chebyshev=4. Was
    blocked; should now upgrade since the gate is Chebyshev <= 5."""
    p = make_player()
    clear_resources(p['id'])
    _give_money(cur, p['id'])
    hx, hy = p['home_x'], p['home_y']
    place('well', hx + 2, hy + 1)
    house_id = place('house', hx + 1, hy + 2)['building_id']
    cur.execute("UPDATE public.buildings SET housing_tier = 3 WHERE id = %s", (house_id,))
    # School 2 right + 4 up from the house → Manhattan 6 (out), Chebyshev 4 (in).
    # School needs road access to be staffed; conftest stamps a cross at
    # (hx, *) and (*, hy) — neither touches (hx+3, hy+6), so extend a
    # branch east from the vertical cross to give the school a perimeter road.
    place('road', hx + 1, hy + 5)
    place('road', hx + 2, hy + 5)
    place('road', hx + 3, hy + 5)
    place('school', hx + 3, hy + 6)
    _give_lots_of_workers(cur, p['id'])
    _stock(cur, p['id'], 'grain', 10.0)
    _stock(cur, p['id'], 'pottery', 10.0)
    _stock(cur, p['id'], 'bread', 10.0)
    _stock(cur, p['id'], 'furniture', 10.0)
    _stock(cur, p['id'], 'lumber', 5.0)
    _stock(cur, p['id'], 'flour', 5.0)
    _backdate(cur, p['id'], 240)

    _tick_and_upgrade_all(cur)
    cur.execute("SELECT housing_tier FROM public.buildings WHERE id = %s", (house_id,))
    assert cur.fetchone()[0] == 4, (
        "townhouse at Chebyshev=4 from a fed school failed to upgrade — "
        "the proximity check should be Chebyshev, not Manhattan"
    )


def test_school_footprint_perimeter_covers_house(make_player, place, cur, clear_resources):
    """School anchor 6 tiles from a house, but the school's 2×2 footprint
    nearest cell is only 5 tiles away → the house should upgrade.
    This is Jill's 2026-06-02 bug: school at (-9,25), anchor Chebyshev=6
    from houses at (-3,26)/(-3,25), but footprint Chebyshev=5."""
    p = make_player()
    clear_resources(p['id'])
    _give_money(cur, p['id'])
    hx, hy = p['home_x'], p['home_y']
    place('well', hx + 2, hy + 6)
    house_id = place('house', hx + 1, hy + 7)['building_id']
    cur.execute("UPDATE public.buildings SET housing_tier = 3 WHERE id = %s", (house_id,))
    # School at (hx-3, hy+1): anchor→house = (dx=4, dy=6) → anchor Chebyshev=6.
    # Footprint (hx-3..hx-2, hy+1..hy+2): nearest cell (hx-2, hy+2) →
    # footprint Chebyshev = max(3, 5) = 5 ≤ 5 → must cover.
    # Road access: footprint top row at hy+1 is adjacent to horizontal cross at hy.
    place('school', hx - 3, hy + 1)
    _give_lots_of_workers(cur, p['id'])
    _stock(cur, p['id'], 'grain', 10.0)
    _stock(cur, p['id'], 'pottery', 10.0)
    _stock(cur, p['id'], 'bread', 10.0)
    _stock(cur, p['id'], 'furniture', 10.0)
    _stock(cur, p['id'], 'lumber', 5.0)
    _stock(cur, p['id'], 'flour', 5.0)
    _backdate(cur, p['id'], 240)

    _tick_and_upgrade_all(cur)
    cur.execute("SELECT housing_tier FROM public.buildings WHERE id = %s", (house_id,))
    assert cur.fetchone()[0] == 4, (
        "townhouse at footprint-perimeter Chebyshev=5 from a fed school "
        "failed to upgrade — anchor Chebyshev=6 must not override the "
        "footprint-based check"
    )


def test_school_chebyshev_corner_still_excluded(make_player, place, cur, clear_resources):
    """Footprint-perimeter cap is still 5: a school whose nearest footprint
    cell is 6 tiles from the house must NOT cover it."""
    p = make_player()
    clear_resources(p['id'])
    _give_money(cur, p['id'])
    hx, hy = p['home_x'], p['home_y']
    # House at (hx+4, hy-1), adjacent to horizontal road at y=hy → road access.
    place('well', hx + 4, hy - 2)
    house_id = place('house', hx + 4, hy - 1)['building_id']
    cur.execute("UPDATE public.buildings SET housing_tier = 3 WHERE id = %s", (house_id,))
    # School at (hx-3, hy+1): footprint (hx-3..hx-2, hy+1..hy+2).
    # Nearest cell to house (hx+4, hy-1): (hx-2, hy+1).
    # dx=6, dy=2 → footprint Chebyshev = max(6, 2) = 6 > 5 → must NOT cover.
    # Road access via adjacency to horizontal cross at y=hy.
    place('school', hx - 3, hy + 1)
    _give_lots_of_workers(cur, p['id'])
    _stock(cur, p['id'], 'grain', 10.0)
    _stock(cur, p['id'], 'pottery', 10.0)
    _stock(cur, p['id'], 'bread', 10.0)
    _stock(cur, p['id'], 'furniture', 10.0)
    _stock(cur, p['id'], 'lumber', 5.0)
    _stock(cur, p['id'], 'flour', 5.0)
    _backdate(cur, p['id'], 240)

    _tick_and_upgrade_all(cur)
    cur.execute("SELECT housing_tier FROM public.buildings WHERE id = %s", (house_id,))
    assert cur.fetchone()[0] == 3, (
        "school at footprint Chebyshev=6 should NOT cover the townhouse — "
        "gate must still be bounded to <= 5"
    )
