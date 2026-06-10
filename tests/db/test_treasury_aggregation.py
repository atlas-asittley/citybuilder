"""Tests for the treasury aggregation RPCs.

The Treasury chart used to bucket cash_transactions client-side;
PostgREST's 1000-row default cap was silently truncating heavy
ledgers. These RPCs aggregate server-side so the cap never bites.
"""
import datetime
import pytest


def _seed_cash(cur, player_id, source, amount, created_at, period_start=None):
    """Insert a cash_transactions row at a specific time. The savepoint
    fixture rolls it back at end of test."""
    cur.execute(
        "INSERT INTO public.cash_transactions "
        "(player_id, amount, source, context, created_at, period_start) "
        "VALUES (%s, %s, %s, '{}'::jsonb, %s, %s)",
        (str(player_id), amount, source, created_at, period_start),
    )


def test_auth_required(cur):
    """Both RPCs should reject unauthenticated callers."""
    cur.execute("SAVEPOINT _a")
    cur.execute("SELECT set_config('request.jwt.claims', '', true)")
    with pytest.raises(Exception) as exc:
        cur.execute("SELECT * FROM public.get_treasury_daily_series(7)")
    assert 'auth required' in str(exc.value)
    cur.execute("ROLLBACK TO SAVEPOINT _a")

    cur.execute("SAVEPOINT _b")
    cur.execute("SELECT set_config('request.jwt.claims', '', true)")
    with pytest.raises(Exception) as exc:
        cur.execute("SELECT * FROM public.get_cash_ledger_by_source(now())")
    assert 'auth required' in str(exc.value)
    cur.execute("ROLLBACK TO SAVEPOINT _b")


def test_daily_series_fixed_7_buckets(cur, make_player):
    """Always returns one row per day in the window even for empty days,
    so the chart's bar layout is consistent."""
    p = make_player()
    # Wipe any cash_transactions the choose_industry flow may have written.
    cur.execute("DELETE FROM public.cash_transactions WHERE player_id = %s",
                (str(p['id']),))
    cur.execute("SELECT count(*) FROM public.get_treasury_daily_series(7)")
    assert cur.fetchone()[0] == 8  # 7 full days + today's bucket = 8 buckets


def test_daily_series_buckets_by_day(cur, make_player):
    """Each row's earned/spent reflects its own day's transactions."""
    p = make_player()
    cur.execute("DELETE FROM public.cash_transactions WHERE player_id = %s",
                (str(p['id']),))
    today_minus = lambda days: datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(days=days)
    _seed_cash(cur, p['id'], 'tax_revenue',  500, today_minus(2))
    _seed_cash(cur, p['id'], 'upkeep',     -200, today_minus(2))
    _seed_cash(cur, p['id'], 'npc_trade',   300, today_minus(1))
    _seed_cash(cur, p['id'], 'tax_revenue', 100, today_minus(0.05))  # today

    cur.execute("""
      SELECT day, earned, spent, net
      FROM public.get_treasury_daily_series(7)
      WHERE earned > 0 OR spent > 0
      ORDER BY day
    """)
    rows = cur.fetchall()
    nets = [int(r[3]) for r in rows]
    assert sorted(nets) == sorted([300, 300, 100]), f"got {nets}"


def test_daily_series_continuous_accrual_splits_across_midnight(cur, make_player):
    """A row with period_start straddling midnight should split its
    amount across the two days proportional to the time spent in each."""
    p = make_player()
    cur.execute("DELETE FROM public.cash_transactions WHERE player_id = %s",
                (str(p['id']),))
    # Pick a fixed yesterday-midnight in UTC. period_start = midnight - 6h
    # (so 6h before the boundary), created_at = midnight + 2h (2h after).
    # Total span = 8h. The row's amount should split 6/8 → previous day,
    # 2/8 → today.
    cur.execute("SELECT date_trunc('day', now() AT TIME ZONE 'UTC')")
    today_midnight_utc = cur.fetchone()[0].replace(tzinfo=datetime.timezone.utc)
    period_start = today_midnight_utc - datetime.timedelta(hours=6)
    created_at = today_midnight_utc + datetime.timedelta(hours=2)
    _seed_cash(cur, p['id'], 'upkeep', -800, created_at, period_start=period_start)

    cur.execute("""
      SELECT day, net
      FROM public.get_treasury_daily_series(7)
      WHERE earned > 0 OR spent > 0
      ORDER BY day
    """)
    rows = cur.fetchall()
    assert len(rows) == 2, f"expected 2 days touched, got {rows}"
    yesterday_net, today_net = int(rows[0][1]), int(rows[1][1])
    # 6/8 of -800 = -600 → yesterday; 2/8 of -800 = -200 → today.
    assert -610 <= yesterday_net <= -590, yesterday_net
    assert -210 <= today_net <= -190, today_net


def test_daily_series_handles_more_than_1000_rows(cur, make_player):
    """The whole point: aggregation must NOT silently drop rows when
    a player has >1000 cash_transactions in the window. Seed 1500 rows
    and confirm the sum reflects all of them."""
    p = make_player()
    cur.execute("DELETE FROM public.cash_transactions WHERE player_id = %s",
                (str(p['id']),))
    base = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(hours=1)
    # Seed 1500 small transactions @ +$2 each → expected sum = $3000.
    rows = [
        (str(p['id']), 2, 'tax_revenue', '{}',
         (base - datetime.timedelta(seconds=i)).isoformat(), None)
        for i in range(1500)
    ]
    cur.executemany(
        "INSERT INTO public.cash_transactions "
        "(player_id, amount, source, context, created_at, period_start) "
        "VALUES (%s, %s, %s, %s::jsonb, %s, %s)",
        rows,
    )
    cur.execute("SELECT SUM(net) FROM public.get_treasury_daily_series(7)")
    total = cur.fetchone()[0]
    assert int(total) == 3000, f"server-side sum should be 3000; got {total}"


def test_daily_series_sources_and_sinks_are_per_day(cur, make_player):
    """The chart needs sources/sinks for the chips. Per-day jsonb
    breakdown should match the raw amounts."""
    p = make_player()
    cur.execute("DELETE FROM public.cash_transactions WHERE player_id = %s",
                (str(p['id']),))
    yesterday = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(days=1)
    _seed_cash(cur, p['id'], 'tax_revenue', 500, yesterday)
    _seed_cash(cur, p['id'], 'upkeep',     -200, yesterday)

    cur.execute("""
      SELECT sources, sinks FROM public.get_treasury_daily_series(7)
      WHERE earned > 0 OR spent > 0
    """)
    rows = cur.fetchall()
    assert len(rows) == 1, "exactly one day should have activity"
    sources, sinks = rows[0]
    assert int(sources['tax_revenue']) == 500
    assert int(sinks['upkeep']) == 200


def test_ledger_by_source_groups_correctly(cur, make_player):
    """get_cash_ledger_by_source returns one row per source with the
    summed amount."""
    p = make_player()
    cur.execute("DELETE FROM public.cash_transactions WHERE player_id = %s",
                (str(p['id']),))
    now = datetime.datetime.now(datetime.timezone.utc)
    _seed_cash(cur, p['id'], 'tax_revenue', 100, now - datetime.timedelta(hours=1))
    _seed_cash(cur, p['id'], 'tax_revenue', 200, now - datetime.timedelta(hours=2))
    _seed_cash(cur, p['id'], 'upkeep',     -50, now - datetime.timedelta(hours=3))

    cur.execute("""
      SELECT source, amount FROM public.get_cash_ledger_by_source(%s) ORDER BY source
    """, (now - datetime.timedelta(days=1),))
    rows = cur.fetchall()
    rolled = {r[0]: int(r[1]) for r in rows}
    assert rolled == {'tax_revenue': 300, 'upkeep': -50}


def test_ledger_player_isolation(cur, make_player, as_user):
    """One player's RPC call doesn't leak the other's transactions."""
    p1 = make_player()
    p2 = make_player()
    cur.execute("DELETE FROM public.cash_transactions WHERE player_id IN (%s, %s)",
                (str(p1['id']), str(p2['id'])))
    now = datetime.datetime.now(datetime.timezone.utc)
    _seed_cash(cur, p1['id'], 'tax_revenue', 100, now - datetime.timedelta(hours=1))
    _seed_cash(cur, p2['id'], 'tax_revenue', 999, now - datetime.timedelta(hours=1))

    as_user(p1['id'])
    cur.execute("SELECT amount FROM public.get_cash_ledger_by_source(%s) WHERE source='tax_revenue'",
                (now - datetime.timedelta(days=1),))
    assert int(cur.fetchone()[0]) == 100, "p1 should not see p2's $999"
