"""Tests for the crime + police system.

Crime is a per-player numeric (0..100) recomputed each tick. The main
driver is the count of active houses NOT within the coverage_radius
of any active staffed police building. Higher tier police (Police
Station, Constabulary) have wider coverage. Crime feeds back into
happiness via a -FLOOR(crime/5) penalty, which means a crime-ridden
city slowly emigrates citizens.

Police buildings also charge upkeep_per_minute while active, deducted
in process_production and logged in cash_transactions.
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




def _stock_food(cur, player_id):
    """Stock berries + grain so happiness/devolve isn't food-gated."""
    for r, q in [('berries', 50), ('grain', 50)]:
        cur.execute("""
            INSERT INTO public.inventories (player_id, resource_key, quantity)
            VALUES (%s, %s, %s)
            ON CONFLICT (player_id, resource_key) DO UPDATE SET quantity = EXCLUDED.quantity
        """, (str(player_id), r, q))


def test_police_buildings_seeded(cur):
    """Three new building types in the police category."""
    cur.execute("""
        SELECT key, build_cost, worker_cost, coverage_radius, upkeep_per_minute
        FROM public.building_types
        WHERE category = 'police' AND is_active
        ORDER BY tier
    """)
    rows = cur.fetchall()
    assert [r[0] for r in rows] == ['watch_house', 'police_station', 'constabulary']
    # Watch house cheapest, smallest coverage, least upkeep.
    assert rows[0][3] < rows[1][3] < rows[2][3], 'coverage radius should grow by tier'
    assert rows[0][4] < rows[1][4] < rows[2][4], 'upkeep should grow by tier'


def test_crime_baseline_for_fresh_player(make_player, cur):
    """A player with no buildings has crime ≈ base (10) plus tiny population pressure."""
    p = make_player(industry='timber', population=5)
    cur.execute("SELECT public.compute_crime(%s)", (str(p['id']),))
    crime = float(cur.fetchone()[0])
    # base 10 + size pressure (population=5 → +0). Should be exactly 10.
    assert crime == 5, f'expected base crime 5, got {crime}'


def test_uncovered_house_raises_crime(make_player, place, cur, clear_resources):
    """Each uncovered house adds 4 crime."""
    p = make_player(population=5)
    clear_resources(p['id'])
    hx, hy = p['home_x'], p['home_y']
    cur.execute("SELECT public.compute_crime(%s)", (str(p['id']),))
    base = float(cur.fetchone()[0])
    place('house', hx + 1, hy + 1)
    cur.execute("SELECT public.compute_crime(%s)", (str(p['id']),))
    after = float(cur.fetchone()[0])
    assert after - base == 4, f'expected +4 crime per uncovered house; got {after - base}'


def _stamp_staffed(cur, player_id):
    """Mark every staffable building as staffed without running the
    full production loop (which has side effects on population, money,
    last_processed_at, etc.). Use when a test only wants to verify
    coverage logic, not the staffing loop itself."""
    cur.execute("""
        UPDATE public.buildings b
        SET is_staffed = true
        FROM public.building_types bt
        WHERE bt.key = b.building_type_key
          AND b.player_id = %s AND b.status = 'active'
          AND bt.category IN ('extractor','food_extractor','booster','processor','tax','service','police','civic')
    """, (str(player_id),))


def test_watch_house_covers_nearby_house(make_player, place, cur, clear_resources):
    """A house within Manhattan radius 4 of a (staffed) Watch House is covered."""
    p = make_player(population=5)
    clear_resources(p['id'])
    cur.execute("UPDATE public.player_profiles SET money = 5000 WHERE id = %s", (str(p['id']),))
    hx, hy = p['home_x'], p['home_y']
    place('house', hx + 1, hy + 1)
    place('watch_house', hx + 2, hy + 1)
    _stamp_staffed(cur, p['id'])
    cur.execute("SELECT public.compute_crime(%s)", (str(p['id']),))
    crime = float(cur.fetchone()[0])
    assert crime == 5, f'covered house should yield base crime; got {crime}'


def test_house_outside_watch_house_radius_uncovered(make_player, place, cur, clear_resources):
    """A house far from the only Watch House stays uncovered."""
    p = make_player(population=5)
    clear_resources(p['id'])
    cur.execute("UPDATE public.player_profiles SET money = 5000 WHERE id = %s", (str(p['id']),))
    hx, hy = p['home_x'], p['home_y']
    place('watch_house', hx + 1, hy + 1)
    place('house', hx + 6, hy + 1)
    _stamp_staffed(cur, p['id'])
    cur.execute("SELECT public.compute_crime(%s)", (str(p['id']),))
    crime = float(cur.fetchone()[0])
    assert crime == 9, f'expected base 5 + uncovered penalty 4; got {crime}'


def test_higher_tier_pd_covers_wider_area(make_player, place, cur, clear_resources):
    """Police Station (radius 6) covers a house Watch House (radius 4) wouldn't."""
    p = make_player(population=5)
    clear_resources(p['id'])
    cur.execute("""
        UPDATE public.player_profiles
        SET money = 10000, highest_housing_tier_ever = 8
        WHERE id = %s
    """, (str(p['id']),))
    hx, hy = p['home_x'], p['home_y']
    place('police_station', hx + 1, hy + 1)
    place('house', hx + 6, hy + 1)
    _stamp_staffed(cur, p['id'])
    cur.execute("SELECT public.compute_crime(%s)", (str(p['id']),))
    crime = float(cur.fetchone()[0])
    assert crime == 5, f'covered by Police Station; expected base 10, got {crime}'


def test_unstaffed_police_no_coverage(make_player, place, cur, clear_resources):
    """A Watch House with no road access doesn't get is_staffed → no coverage."""
    p = make_player(population=5)
    clear_resources(p['id'])
    cur.execute("UPDATE public.player_profiles SET money = 5000 WHERE id = %s", (str(p['id']),))
    hx, hy = p['home_x'], p['home_y']
    place('house', hx + 4, hy + 5)
    place('watch_house', hx + 5, hy + 5)  # off-road tile (clear_resources put roads at hx, hy crosses)
    _tick_and_upgrade_all(cur)  # refresh is_staffed
    cur.execute("SELECT public.compute_crime(%s)", (str(p['id']),))
    crime = float(cur.fetchone()[0])
    assert crime == 9, f"no-road WH shouldn't cover; got {crime}"


def test_unstaffed_police_no_coverage_due_to_worker_shortage(make_player, place, cur, clear_resources):
    """A road-connected Watch House that didn't get workers (worker
    shortage) should NOT count as covering nearby housing. Closes a
    free-coverage exploit where unstaffed PDs avoid upkeep but still
    drop crime."""
    p = make_player(population=5)
    clear_resources(p['id'])
    cur.execute("UPDATE public.player_profiles SET money = 5000 WHERE id = %s", (str(p['id']),))
    hx, hy = p['home_x'], p['home_y']

    # Place Watch House A first (FIFO staffing → A gets the 5 workers).
    place('watch_house', hx + 1, hy + 1)
    # Place Watch House B second; only 5 workers in the pool, so B is unstaffed.
    place('watch_house', hx - 1, hy + 1)
    # Place a house only in B's radius (>4 from A, ≤4 from B).
    place('house', hx - 4, hy + 1)
    cur.execute("""
        UPDATE public.buildings SET last_processed_at = now() - interval '60 seconds'
        WHERE player_id = %s
    """, (str(p['id']),))
    _tick_and_upgrade_all(cur)

    cur.execute("""
        SELECT COUNT(*) FILTER (WHERE is_staffed) FROM public.buildings
        WHERE player_id = %s AND building_type_key = 'watch_house'
    """, (str(p['id']),))
    staffed_count = cur.fetchone()[0]
    assert staffed_count == 1, f"expected exactly 1 watch_house staffed, got {staffed_count}"

    cur.execute("SELECT public.compute_crime(%s)", (str(p['id']),))
    crime = float(cur.fetchone()[0])
    # House is only in the UNSTAFFED B's radius → uncovered → +4 over base.
    assert crime == 9, f"unstaffed police shouldn't cover; got {crime}"


def test_crime_reduces_happiness(make_player, place, cur, clear_resources):
    """High crime subtracts FLOOR(crime/5) from happiness."""
    p = make_player(population=5)
    clear_resources(p['id'])
    _stock_food(cur, p['id'])
    hx, hy = p['home_x'], p['home_y']
    # 5 uncovered houses × 4 + base 5 = 25 crime. Penalty floor(25/5)=5.
    place('house', hx + 1, hy + 1)
    place('house', hx + 1, hy + 2)
    place('house', hx + 2, hy + 1)
    place('house', hx + 1, hy - 1)
    place('house', hx + 1, hy - 2)
    cur.execute("SELECT public.compute_happiness(%s)", (str(p['id']),))
    bk = cur.fetchone()[0]['breakdown']
    assert bk['crime'] >= 25, f'expected crime ≥ 25 with 5 uncovered houses; got {bk["crime"]}'
    assert bk['crime_penalty'] == int(bk['crime']) // 5, 'penalty = floor(crime/5)'


def test_pd_upkeep_deducts_money_and_logs_ledger_row(make_player, place, cur, clear_resources):
    """Active staffed Watch House deducts $5/min and logs an upkeep row."""
    p = make_player(population=5)
    clear_resources(p['id'])
    cur.execute("""
        UPDATE public.player_profiles
        SET money = 5000, population = 30, worker_capacity = 30
        WHERE id = %s
    """, (str(p['id']),))
    hx, hy = p['home_x'], p['home_y']
    place('watch_house', hx + 1, hy + 1)
    # Backdate the watch house and player tick so process_production sees ~60s elapsed.
    cur.execute("""
        UPDATE public.buildings SET last_processed_at = now() - interval '60 seconds'
        WHERE player_id = %s
    """, (str(p['id']),))
    cur.execute("""
        UPDATE public.player_profiles
        SET last_population_tick_at = now() - interval '60 seconds'
        WHERE id = %s
    """, (str(p['id']),))
    cur.execute("DELETE FROM public.cash_transactions WHERE player_id = %s AND source = 'upkeep'",
                (str(p['id']),))
    cur.execute("SELECT money FROM public.player_profiles WHERE id = %s", (str(p['id']),))
    money_before = cur.fetchone()[0]
    _tick_and_upgrade_all(cur)
    cur.execute("SELECT money FROM public.player_profiles WHERE id = %s", (str(p['id']),))
    money_after = cur.fetchone()[0]
    assert money_after < money_before, 'upkeep should have reduced money'

    cur.execute("""
        SELECT amount FROM public.cash_transactions
        WHERE player_id = %s AND source = 'upkeep'
    """, (str(p['id']),))
    rows = cur.fetchall()
    assert len(rows) == 1, 'upkeep should be logged once per tick'
    assert rows[0][0] < 0


# ── civic crime_emit + crime_reduction (2026-05-21) ──────────────

def test_staffed_marketplace_emits_crime(make_player, place, cur, clear_resources):
    """Marketplace has crime_emit > 0. While staffed, compute_crime
    should rise by exactly that amount per marketplace."""
    p = make_player(population=5)
    clear_resources(p['id'])
    cur.execute("UPDATE public.player_profiles SET money = 50000 WHERE id = %s", (str(p['id']),))
    hx, hy = p['home_x'], p['home_y']
    cur.execute("SELECT public.compute_crime(%s)", (str(p['id']),))
    base = float(cur.fetchone()[0])

    cur.execute("SELECT crime_emit FROM public.building_types WHERE key='marketplace'")
    emit = cur.fetchone()[0]
    assert emit and emit > 0, 'marketplace must declare crime_emit > 0'

    place('marketplace', hx + 1, hy + 1)
    _stamp_staffed(cur, p['id'])
    cur.execute("SELECT public.compute_crime(%s)", (str(p['id']),))
    after = float(cur.fetchone()[0])
    assert after - base == emit, (
        f'staffed marketplace should add exactly crime_emit ({emit}); '
        f'got Δ {after - base}'
    )


def test_unstaffed_marketplace_does_not_emit_crime(make_player, place, cur, clear_resources):
    """Same setup, but no staffing → no crime contribution."""
    p = make_player(population=5)
    clear_resources(p['id'])
    cur.execute("UPDATE public.player_profiles SET money = 50000 WHERE id = %s", (str(p['id']),))
    hx, hy = p['home_x'], p['home_y']
    cur.execute("SELECT public.compute_crime(%s)", (str(p['id']),))
    base = float(cur.fetchone()[0])

    place('marketplace', hx + 1, hy + 1)
    # NOT stamping staffed.
    cur.execute("SELECT public.compute_crime(%s)", (str(p['id']),))
    after = float(cur.fetchone()[0])
    assert after == base, (
        f'unstaffed marketplace must not emit crime; baseline={base}, after={after}'
    )


def test_staffed_hospital_reduces_crime(make_player, place, cur, clear_resources):
    """Hospital has crime_reduction > 0. Stack with an uncovered house
    that adds +4 crime; hospital should net that down by crime_reduction.

    Setup: 1 uncovered house = base + 4. With a staffed hospital,
    crime = base + 4 - crime_reduction.
    """
    p = make_player(population=5)
    clear_resources(p['id'])
    cur.execute("""UPDATE public.player_profiles SET money=50000,
                   highest_housing_tier_ever=4 WHERE id=%s""", (str(p['id']),))
    # Stock ale so hospital can operate (input gate). Won't be drained
    # because we don't run process_production — just _stamp_staffed.
    cur.execute("""INSERT INTO public.inventories (player_id, resource_key, quantity)
                   VALUES (%s, 'ale', 100)
                   ON CONFLICT (player_id, resource_key) DO UPDATE SET quantity = 100""",
                (str(p['id']),))
    hx, hy = p['home_x'], p['home_y']
    place('house', hx + 1, hy + 1)
    cur.execute("SELECT public.compute_crime(%s)", (str(p['id']),))
    pre = float(cur.fetchone()[0])  # base + 4 (house uncovered)

    cur.execute("SELECT crime_reduction FROM public.building_types WHERE key='hospital'")
    reduce = cur.fetchone()[0]
    assert reduce and reduce > 0, 'hospital must declare crime_reduction > 0'

    place('hospital', hx + 3, hy + 1)
    _stamp_staffed(cur, p['id'])
    cur.execute("SELECT public.compute_crime(%s)", (str(p['id']),))
    after = float(cur.fetchone()[0])
    # clamp guard: crime is GREATEST(0, …) so don't go negative.
    expected = max(0, pre - reduce)
    assert after == expected, (
        f'hospital should reduce crime by {reduce}; pre={pre}, after={after}, expected={expected}'
    )
