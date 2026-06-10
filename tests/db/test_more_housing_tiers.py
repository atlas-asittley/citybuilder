
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


"""Tests for housing tiers 6-8: Mansion, Estate, Palace.

Each tier adds an escalating luxury prereq on top of the existing
road+well+food+school+temple gates:

  Tier 6 Mansion  — needs any luxury food (spirits/caviar/spices/ale)
  Tier 7 Estate   — needs any industrial luxury (cabinets/monuments/mosaics/machinery)
  Tier 8 Palace   — needs ALL FOUR industrial luxuries simultaneously in stock

The "all 4" gate is computed by counting distinct is_industrial_luxury
resources in stock vs the total defined; that way it generalizes
without hardcoding keys.
"""


# Baseline stocks every test gets unless overridden via kwargs:
#   lumber/flour: school inputs (so school qualifies as 'operating')
#   statuary/brick: temple inputs (same reason)
#   pottery/bread/furniture/statuary: cumulative housing lifestyle goods.
#     With cumulative demands, every house at T2..T8 needs all four of
#     these, so pre-stocking enough that the test runs (≈ 25 min of
#     drain at the highest rates) avoids tier-maintenance noise tripping
#     these tier-progression tests.
_SERVICE_INPUTS = {
    'lumber': 5.0, 'flour': 5.0,
    'statuary': 50.0, 'brick': 50.0,
    'pottery': 50.0, 'bread': 50.0, 'furniture': 50.0,
}


def _set_inventory(cur, player_id, **stocks):
    """Replace the player's inventory with the given stocks plus baseline
    school/temple inputs (lumber, flour, statuary, brick) so the services
    qualify as 'operating' during the housing eval. Inputs given via
    kwargs override the baseline."""
    cur.execute("DELETE FROM public.inventories WHERE player_id = %s", (str(player_id),))
    merged = dict(_SERVICE_INPUTS)
    merged.update(stocks)
    for resource_key, qty in merged.items():
        cur.execute("""
            INSERT INTO public.inventories (player_id, resource_key, quantity)
            VALUES (%s, %s, %s)
        """, (str(player_id), resource_key, qty))


def _backdate_house(cur, player_id, house_id, secs):
    """Backdate ONLY the house's last_processed_at. Services stay 'recent'
    so their tiny consumption needs are trivially satisfied and they
    qualify as operating without huge input stockpiles."""
    cur.execute("""
        UPDATE public.buildings SET last_processed_at = now() - make_interval(secs => %s)
        WHERE id = %s
    """, (secs, house_id))
    # Reset food-tick timestamp so housing food drain doesn't wipe everything in one tick.
    cur.execute("""
        UPDATE public.player_profiles SET last_food_tick_at = now() - make_interval(secs => 5)
        WHERE id = %s
    """, (str(player_id),))


def _setup_tier5_ready_house(cur, make_player, place, clear_resources, starting_tier=5):
    """Build a fully-supported house at the given starting tier with all
    standard prereqs (road, well, school, temple, food) satisfied.
    Returns (player, house_id)."""
    p = make_player()
    clear_resources(p['id'])
    cur.execute("UPDATE public.player_profiles SET money = 50000 WHERE id = %s", (str(p['id']),))
    hx, hy = p['home_x'], p['home_y']
    place('well', hx + 2, hy + 1)
    # School (2x2) and temple (2x2) — anchors chosen so each footprint
    # stays off the highway cross (y=hy, x=hx), the anchor has a road
    # neighbor for service staffing, and Manhattan distance from the
    # house at (hx+1, hy+2) is within range (school ≤5, temple ≤6).
    place('school', hx - 2, hy + 1)   # covers (hx-2..hx-1, hy+1..hy+2)
    place('temple', hx + 3, hy + 1)   # covers (hx+3..hx+4, hy+1..hy+2)
    house_id = place('house', hx + 1, hy + 2)['building_id']
    cur.execute("UPDATE public.buildings SET housing_tier = %s WHERE id = %s",
                (starting_tier, house_id))
    # The new symmetric population model fills gradually. These tests
    # assume the school/temple/well are all staffed so the housing
    # prereqs are met. Force pop high enough to staff everything; the
    # next process_production tick will clamp it down to actual target.
    cur.execute("UPDATE public.player_profiles SET population = 200 WHERE id = %s",
                (str(p['id']),))
    return p, house_id


# ── Schema sanity ──

def test_luxury_food_flags_set(cur):
    cur.execute("SELECT key FROM public.resources WHERE is_luxury_food ORDER BY key")
    keys = [r[0] for r in cur.fetchall()]
    assert keys == ['ale', 'caviar', 'spices', 'spirits']


def test_industrial_luxury_flags_set(cur):
    cur.execute("SELECT key FROM public.resources WHERE is_industrial_luxury ORDER BY key")
    keys = [r[0] for r in cur.fetchall()]
    assert keys == ['cabinets', 'machinery', 'monuments', 'mosaics']


def test_new_tier_rows_present(cur):
    cur.execute("""SELECT tier, name, workers, needs_luxury_food,
                          needs_industrial_luxury, needs_all_industrial_luxuries
                   FROM public.housing_tier_config
                   WHERE tier IN (6, 7, 8) ORDER BY tier""")
    rows = cur.fetchall()
    assert rows[0] == (6, 'Mansion', 50, True, False, False)
    assert rows[1] == (7, 'Estate',  70, True, True,  False)
    assert rows[2] == (8, 'Palace',  100, True, True, True)


# ── Tier 5 → 6 (luxury food) ──

def test_tier5_to_6_blocked_without_luxury_food(make_player, place, cur, clear_resources):
    """A tier-5 manor with food but no luxury food cannot upgrade to mansion."""
    p, house_id = _setup_tier5_ready_house(cur, make_player, place, clear_resources, 5)
    _set_inventory(cur, p['id'], bread=20.0)  # plain food only
    _backdate_house(cur, p['id'], house_id, 600)
    _tick_and_upgrade_all(cur)
    cur.execute("SELECT housing_tier FROM public.buildings WHERE id = %s", (house_id,))
    assert cur.fetchone()[0] == 5, "manor upgraded to mansion without luxury food"


def test_tier5_to_6_succeeds_with_spirits(make_player, place, cur, clear_resources):
    p, house_id = _setup_tier5_ready_house(cur, make_player, place, clear_resources, 5)
    _set_inventory(cur, p['id'], bread=20.0, spirits=5.0)
    _backdate_house(cur, p['id'], house_id, 600)
    _tick_and_upgrade_all(cur)
    cur.execute("SELECT housing_tier FROM public.buildings WHERE id = %s", (house_id,))
    assert cur.fetchone()[0] == 6, "manor failed to upgrade to mansion with spirits in stock"


def test_tier5_to_6_succeeds_with_any_luxury_food(make_player, place, cur, clear_resources):
    """Caviar (or any luxury food) should also work — gate is presence-only."""
    p, house_id = _setup_tier5_ready_house(cur, make_player, place, clear_resources, 5)
    _set_inventory(cur, p['id'], bread=20.0, caviar=3.0)
    _backdate_house(cur, p['id'], house_id, 600)
    _tick_and_upgrade_all(cur)
    cur.execute("SELECT housing_tier FROM public.buildings WHERE id = %s", (house_id,))
    assert cur.fetchone()[0] == 6


# ── Tier 6 → 7 (any industrial luxury) ──

def test_tier6_to_7_blocked_without_industrial_luxury(make_player, place, cur, clear_resources):
    """A tier-6 mansion with luxury food but no industrial luxury can't upgrade."""
    p, house_id = _setup_tier5_ready_house(cur, make_player, place, clear_resources, 6)
    _set_inventory(cur, p['id'], bread=20.0, spirits=5.0)
    _backdate_house(cur, p['id'], house_id, 900)
    _tick_and_upgrade_all(cur)
    cur.execute("SELECT housing_tier FROM public.buildings WHERE id = %s", (house_id,))
    assert cur.fetchone()[0] == 6, "mansion upgraded to estate without an industrial luxury"


def test_tier6_to_7_succeeds_with_cabinets(make_player, place, cur, clear_resources):
    p, house_id = _setup_tier5_ready_house(cur, make_player, place, clear_resources, 6)
    _set_inventory(cur, p['id'], bread=20.0, spirits=5.0, cabinets=2.0)
    _backdate_house(cur, p['id'], house_id, 900)
    _tick_and_upgrade_all(cur)
    cur.execute("SELECT housing_tier FROM public.buildings WHERE id = %s", (house_id,))
    assert cur.fetchone()[0] == 7


# ── Tier 7 → 8 (ALL FOUR industrial luxuries) ──

def test_tier7_to_8_blocked_without_all_four(make_player, place, cur, clear_resources):
    """Any single industrial luxury alone is not enough — need all 4."""
    p, house_id = _setup_tier5_ready_house(cur, make_player, place, clear_resources, 7)
    _set_inventory(cur, p['id'], bread=20.0, spirits=5.0, cabinets=2.0)
    _backdate_house(cur, p['id'], house_id, 1500)
    _tick_and_upgrade_all(cur)
    cur.execute("SELECT housing_tier FROM public.buildings WHERE id = %s", (house_id,))
    assert cur.fetchone()[0] == 7, "estate upgraded to palace with only one industrial luxury"


def test_tier7_to_8_blocked_with_three_of_four(make_player, place, cur, clear_resources):
    """3 of 4 is still not enough."""
    p, house_id = _setup_tier5_ready_house(cur, make_player, place, clear_resources, 7)
    _set_inventory(cur, p['id'], bread=20.0, spirits=5.0,
                   cabinets=2.0, monuments=1.0, mosaics=1.0)
    _backdate_house(cur, p['id'], house_id, 1500)
    _tick_and_upgrade_all(cur)
    cur.execute("SELECT housing_tier FROM public.buildings WHERE id = %s", (house_id,))
    assert cur.fetchone()[0] == 7, "estate upgraded to palace with only 3 of 4 industrial luxuries"


def test_tier7_to_8_succeeds_with_all_four(make_player, place, cur, clear_resources):
    p, house_id = _setup_tier5_ready_house(cur, make_player, place, clear_resources, 7)
    _set_inventory(cur, p['id'], bread=20.0, spirits=5.0,
                   cabinets=2.0, monuments=1.0, mosaics=1.0, machinery=1.0)
    _backdate_house(cur, p['id'], house_id, 1500)
    _tick_and_upgrade_all(cur)
    cur.execute("SELECT housing_tier FROM public.buildings WHERE id = %s", (house_id,))
    assert cur.fetchone()[0] == 8


# ── Devolution when prereqs lapse ──

def test_mansion_devolves_when_luxury_food_runs_out(make_player, place, cur, clear_resources):
    """A tier-6 mansion with food but no luxury food in stock devolves."""
    p, house_id = _setup_tier5_ready_house(cur, make_player, place, clear_resources, 6)
    _set_inventory(cur, p['id'], bread=20.0)  # plain food, no luxury food
    _backdate_house(cur, p['id'], house_id, 600)
    _tick_and_upgrade_all(cur)
    cur.execute("SELECT housing_tier FROM public.buildings WHERE id = %s", (house_id,))
    assert cur.fetchone()[0] == 5, "mansion failed to devolve when luxury food ran out"


def test_palace_devolves_when_one_industrial_luxury_runs_out(make_player, place, cur, clear_resources):
    """A tier-8 palace devolves to estate when the 'all 4' gate breaks."""
    p, house_id = _setup_tier5_ready_house(cur, make_player, place, clear_resources, 8)
    _set_inventory(cur, p['id'], bread=20.0, spirits=5.0,
                   cabinets=2.0, monuments=1.0, mosaics=1.0)  # missing machinery
    _backdate_house(cur, p['id'], house_id, 1500)
    _tick_and_upgrade_all(cur)
    cur.execute("SELECT housing_tier FROM public.buildings WHERE id = %s", (house_id,))
    assert cur.fetchone()[0] == 7, "palace should devolve when 1 of 4 industrial luxuries is missing"
