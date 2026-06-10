"""Per-player daily trade quotas (2026-05-08).

daily_buy_cap and daily_sell_cap on trader_prices used to be
decorative — _rtv_*_phase ignored them. Now they're enforced
PER PLAYER (not city-wide): each player has their own daily
qty_bought / qty_sold counter against the catalog cap.
"""
import psycopg2


def _set_inv(cur, player_id, resource_key, qty):
    cur.execute(
        "INSERT INTO public.inventories (player_id, resource_key, quantity) "
        "VALUES (%s, %s, %s) "
        "ON CONFLICT (player_id, resource_key) DO UPDATE SET quantity = EXCLUDED.quantity",
        (str(player_id), resource_key, qty)
    )


def _set_policy(cur, player_id, resource_key, mode, reserve_target=0):
    cur.execute(
        "INSERT INTO public.trade_policies (player_id, resource_key, mode, reserve_target) "
        "VALUES (%s, %s, %s, %s) "
        "ON CONFLICT (player_id, resource_key) DO UPDATE SET "
        "  mode = EXCLUDED.mode, reserve_target = EXCLUDED.reserve_target",
        (str(player_id), resource_key, mode, reserve_target)
    )


def _set_cap(cur, trader_key, resource_key, buy_cap, sell_cap):
    """Pin the global catalog cap for a (trader, resource) pair."""
    cur.execute(
        "UPDATE public.trader_prices "
        "SET daily_buy_cap = %s, daily_sell_cap = %s "
        "WHERE trader_key = %s AND resource_key = %s AND city_id IS NULL",
        (buy_cap, sell_cap, trader_key, resource_key)
    )


def _backdate_visit(cur, player_id, trader_key, minutes_ago):
    """Stamp a fake last visit so the next process_production sees the
    trader as due. trader_visits has the visited_at column."""
    cur.execute(
        "INSERT INTO public.trader_visits "
        "(trader_key, player_id, capacity_total, capacity_used, summary, visited_at) "
        "VALUES (%s, %s, 20, 0, '[]'::jsonb, now() - (%s || ' minutes')::interval)",
        (trader_key, str(player_id), minutes_ago)
    )


def test_sell_quota_caps_player_at_daily_buy_cap(make_player, place, cur, clear_resources):
    """One player with sell_surplus and a low cap. They can't sell
    more than daily_buy_cap units of that resource per day."""
    p = make_player(industry='timber')
    clear_resources(p['id'])
    cur.execute("UPDATE public.player_profiles SET money=10000 WHERE id=%s", (str(p['id']),))
    _set_cap(cur, 'river_traders', 'timber', buy_cap=20, sell_cap=20)
    _set_policy(cur, p['id'], 'timber', 'sell_surplus', reserve_target=0)
    _set_inv(cur, p['id'], 'timber', 200)

    # Drive multiple visits by backdating last visit far enough.
    _backdate_visit(cur, p['id'], 'river_traders', 200)  # 20+ visits possible
    cur.execute("SELECT public.process_production()")

    cur.execute("""
        SELECT qty_bought FROM public.trader_daily_quota
        WHERE player_id = %s AND trader_key = 'river_traders' AND resource_key = 'timber'
          AND day_bucket = CURRENT_DATE
    """, (str(p['id']),))
    row = cur.fetchone()
    assert row is not None, 'quota row should exist after sells'
    assert row[0] == 20, f"qty_bought should hit cap 20, got {row[0]}"
    # And inventory should have dropped exactly that much.
    cur.execute("SELECT quantity FROM public.inventories WHERE player_id=%s AND resource_key='timber'",
                (str(p['id']),))
    assert float(cur.fetchone()[0]) == 180.0


def test_quota_is_per_player_not_city_wide(make_player, place, cur, clear_resources):
    """Two players in the same city — Player A burning their quota
    on a resource shouldn't affect Player B's quota."""
    a = make_player(industry='timber', display_name='alfa')
    b = make_player(industry='timber', display_name='bravo')
    clear_resources(a['id'])
    clear_resources(b['id'])
    cur.execute("UPDATE public.player_profiles SET money=10000 WHERE id=%s", (str(a['id']),))
    cur.execute("UPDATE public.player_profiles SET money=10000 WHERE id=%s", (str(b['id']),))
    _set_cap(cur, 'river_traders', 'timber', buy_cap=15, sell_cap=15)

    # Player A: sell surplus aggressively, hitting the cap.
    cur.execute("SELECT set_config('request.jwt.claims', %s, false)",
                ('{"sub": "' + str(a['id']) + '"}',))
    _set_policy(cur, a['id'], 'timber', 'sell_surplus', reserve_target=0)
    _set_inv(cur, a['id'], 'timber', 200)
    _backdate_visit(cur, a['id'], 'river_traders', 200)
    cur.execute("SELECT public.process_production()")

    # Player B: should still have their full cap available.
    cur.execute("SELECT set_config('request.jwt.claims', %s, false)",
                ('{"sub": "' + str(b['id']) + '"}',))
    _set_policy(cur, b['id'], 'timber', 'sell_surplus', reserve_target=0)
    _set_inv(cur, b['id'], 'timber', 200)
    _backdate_visit(cur, b['id'], 'river_traders', 200)
    cur.execute("SELECT public.process_production()")

    # Both should have used 15.
    # Scope to JUST these two test players — live production data also
    # has rows in this table.
    cur.execute("""
        SELECT player_id, qty_bought FROM public.trader_daily_quota
        WHERE trader_key = 'river_traders' AND resource_key = 'timber'
          AND day_bucket = CURRENT_DATE
          AND player_id IN (%s, %s)
        ORDER BY qty_bought DESC
    """, (str(a['id']), str(b['id'])))
    rows = cur.fetchall()
    assert len(rows) == 2, f'expected 2 quota rows (one per player), got {len(rows)}'
    assert all(r[1] == 15 for r in rows), \
        f'each player should have hit the per-player cap of 15: {rows}'


def test_buy_quota_caps_player_at_daily_sell_cap(make_player, place, cur, clear_resources):
    """buy_to_reserve policy can't fetch more than daily_sell_cap
    units per day."""
    p = make_player(industry='timber')
    clear_resources(p['id'])
    cur.execute("UPDATE public.player_profiles SET money=100000 WHERE id=%s", (str(p['id']),))
    _set_cap(cur, 'river_traders', 'lumber', buy_cap=10, sell_cap=10)
    _set_policy(cur, p['id'], 'lumber', 'buy_to_reserve', reserve_target=500)

    _backdate_visit(cur, p['id'], 'river_traders', 200)
    cur.execute("SELECT public.process_production()")

    cur.execute("""
        SELECT qty_sold FROM public.trader_daily_quota
        WHERE player_id = %s AND trader_key = 'river_traders' AND resource_key = 'lumber'
          AND day_bucket = CURRENT_DATE
    """, (str(p['id']),))
    row = cur.fetchone()
    assert row is not None
    assert row[0] == 10, f'qty_sold should hit cap 10, got {row[0]}'
    cur.execute("SELECT quantity FROM public.inventories WHERE player_id=%s AND resource_key='lumber'",
                (str(p['id']),))
    assert float(cur.fetchone()[0]) == 10.0
