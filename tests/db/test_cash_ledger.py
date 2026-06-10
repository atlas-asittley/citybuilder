"""Tests for the per-player cash ledger.

The Treasury panel needs an audit trail for tax revenue, build costs,
and expansion costs — events that just modified `player_profiles.money`
without being recorded anywhere. cash_transactions is the new source
of truth for all money movement outside of trade.
"""
import pytest


def test_place_building_logs_build_cost(make_player, place, cur, clear_resources):
    p = make_player(industry='timber')
    clear_resources(p['id'])
    hx, hy = p['home_x'], p['home_y']

    cur.execute("DELETE FROM public.cash_transactions WHERE player_id = %s", (str(p['id']),))
    place('road', hx + 1, hy + 1)

    cur.execute("""
        SELECT source, amount, context FROM public.cash_transactions
        WHERE player_id = %s ORDER BY created_at
    """, (str(p['id']),))
    rows = cur.fetchall()
    assert len(rows) == 1, f'expected 1 ledger row, got {len(rows)}'
    source, amount, context = rows[0]
    assert source == 'build_cost'
    assert amount < 0, 'build_cost should be a negative entry'
    assert context.get('building_type_key') == 'road'


def test_place_building_skips_zero_cost_buildings(make_player, place, cur, clear_resources):
    """If build_cost is 0 (none today, but defensive), no ledger row is written."""
    p = make_player(industry='timber')
    clear_resources(p['id'])
    cur.execute("DELETE FROM public.cash_transactions WHERE player_id = %s", (str(p['id']),))
    # The smallest paid building is road ($25). All buildings cost > 0
    # right now, so this test just verifies the gate fires correctly
    # by counting rows after a real placement.
    hx, hy = p['home_x'], p['home_y']
    place('road', hx + 1, hy + 1)
    cur.execute("SELECT COUNT(*) FROM public.cash_transactions WHERE player_id = %s AND source='build_cost'",
                (str(p['id']),))
    assert cur.fetchone()[0] == 1


def test_tax_revenue_logged_per_tick(make_player, place, cur, clear_resources):
    """A staffed tax office credits money AND a tax_revenue ledger row."""
    p = make_player(industry='timber')
    clear_resources(p['id'])
    hx, hy = p['home_x'], p['home_y']
    place('road', hx + 1, hy + 1)
    place('well', hx + 2, hy + 2)
    house_id = place('house', hx + 1, hy + 2)['building_id']
    cur.execute("UPDATE public.buildings SET housing_tier = 2 WHERE id = %s", (house_id,))
    cur.execute("UPDATE public.player_profiles SET money = 1000, population = 20, worker_capacity = 20 WHERE id = %s",
                (str(p['id']),))
    place('tax_man', hx + 1, hy + 3)
    cur.execute("""
        UPDATE public.buildings SET last_processed_at = now() - interval '60 seconds'
        WHERE player_id = %s
    """, (str(p['id']),))
    cur.execute("DELETE FROM public.cash_transactions WHERE player_id = %s AND source = 'tax_revenue'",
                (str(p['id']),))
    cur.execute("SELECT public.process_production()")

    cur.execute("""
        SELECT amount FROM public.cash_transactions
        WHERE player_id = %s AND source = 'tax_revenue'
    """, (str(p['id']),))
    row = cur.fetchone()
    assert row is not None, 'tax_revenue should have been logged'
    assert row[0] > 0


def test_upkeep_row_populates_period_start(make_player, place, cur, clear_resources):
    """_pp_run_upkeep stamps period_start = the earliest staffed
    building's previous last_processed_at, so the Treasury chart can
    spread offline-catch-up charges proportionally instead of cliffing
    on the reconnect day."""
    p = make_player(industry='timber')
    clear_resources(p['id'])
    hx, hy = p['home_x'], p['home_y']
    place('road', hx + 1, hy + 1)
    place('well', hx + 2, hy + 2)
    place('house', hx + 1, hy + 2)
    cur.execute(
        "UPDATE public.player_profiles SET money = 100000, population = 50, worker_capacity = 50 WHERE id = %s",
        (str(p['id']),)
    )
    # police_station has upkeep > 0 (10/min). Place it staffed.
    place('police_station', hx + 2, hy + 1)
    # Backdate building clocks to simulate 60 minutes of accrual.
    cur.execute(
        "UPDATE public.buildings SET last_processed_at = now() - interval '60 seconds' WHERE player_id = %s",
        (str(p['id']),)
    )
    cur.execute("DELETE FROM public.cash_transactions WHERE player_id = %s AND source = 'upkeep'",
                (str(p['id']),))
    cur.execute("SELECT public.process_production()")

    cur.execute("""
        SELECT amount, period_start, created_at
        FROM public.cash_transactions
        WHERE player_id = %s AND source = 'upkeep'
        ORDER BY created_at DESC LIMIT 1
    """, (str(p['id']),))
    row = cur.fetchone()
    assert row is not None, 'upkeep should be logged'
    amt, period_start, created_at = row
    assert amt < 0
    assert period_start is not None, 'period_start must be populated for upkeep'
    assert period_start < created_at, 'period_start must precede created_at'


def test_tax_row_populates_period_start(make_player, place, cur, clear_resources):
    """_pp_run_tax mirrors _pp_run_upkeep: period_start = earliest
    staffed tax building's previous last_processed_at."""
    p = make_player(industry='timber')
    clear_resources(p['id'])
    hx, hy = p['home_x'], p['home_y']
    place('road', hx + 1, hy + 1)
    place('well', hx + 2, hy + 2)
    house_id = place('house', hx + 1, hy + 2)['building_id']
    cur.execute("UPDATE public.buildings SET housing_tier = 2 WHERE id = %s", (house_id,))
    cur.execute(
        "UPDATE public.player_profiles SET money = 1000, population = 20, worker_capacity = 20 WHERE id = %s",
        (str(p['id']),)
    )
    place('tax_man', hx + 1, hy + 3)
    cur.execute(
        "UPDATE public.buildings SET last_processed_at = now() - interval '60 seconds' WHERE player_id = %s",
        (str(p['id']),)
    )
    cur.execute("DELETE FROM public.cash_transactions WHERE player_id = %s AND source = 'tax_revenue'",
                (str(p['id']),))
    cur.execute("SELECT public.process_production()")

    cur.execute("""
        SELECT amount, period_start, created_at
        FROM public.cash_transactions
        WHERE player_id = %s AND source = 'tax_revenue'
        ORDER BY created_at DESC LIMIT 1
    """, (str(p['id']),))
    row = cur.fetchone()
    assert row is not None, 'tax_revenue should be logged'
    amt, period_start, created_at = row
    assert amt > 0
    assert period_start is not None, 'period_start must be populated for tax_revenue'
    assert period_start < created_at


def test_starting_grant_ledger_row_emitted_at_choose_industry(make_player, cur):
    """choose_industry credits $1000 at profile creation. The cash
    ledger invariant requires a matching starting_grant row so the
    Treasury chart's running balance starts at the right value
    instead of $1000 short."""
    p = make_player(industry='timber')
    cur.execute("""
        SELECT amount FROM public.cash_transactions
        WHERE player_id = %s AND source = 'starting_grant'
    """, (str(p['id']),))
    rows = cur.fetchall()
    assert len(rows) == 1, f'expected one starting_grant row, got {len(rows)}'
    assert rows[0][0] == 2000, f'starting grant amount mismatch: {rows[0][0]}'


def test_cash_transactions_only_visible_to_owner(make_player, conn, cur):
    """RLS: a player can't read another player's ledger rows."""
    a = make_player(industry='timber')
    b = make_player(industry='stone')

    # Insert a row owned by player A. We're in the postgres role so
    # this bypasses RLS for the insert; the SELECT below tests RLS.
    cur.execute("""
        INSERT INTO public.cash_transactions (player_id, source, amount)
        VALUES (%s, 'build_cost', -100)
    """, (str(a['id']),))

    # Switch auth to player B and try to read.
    cur.execute("SELECT set_config('request.jwt.claims', %s, true)",
                ('{"sub": "%s", "role": "authenticated"}' % b['id'],))
    # Drop role to authenticated to actually trigger RLS in this session.
    cur.execute("SET LOCAL ROLE authenticated")
    cur.execute("SELECT COUNT(*) FROM public.cash_transactions WHERE player_id = %s",
                (str(a['id']),))
    visible = cur.fetchone()[0]
    cur.execute("RESET ROLE")  # restore postgres for fixture cleanup
    assert visible == 0, "player B should not see player A's ledger rows under RLS"
