"""Reservation prices on trade_policies (2026-05-09).

min_sell_price / max_buy_price are global per-resource gates that
the sell/buy phase must respect: skip the partner if its catalog
prices don't beat the player's threshold."""
import psycopg2
import pytest


def _act_as(cur, player_id):
    cur.execute("SELECT set_config('request.jwt.claims', %s, true)",
                ('{"sub": "' + str(player_id) + '"}',))


def _set_inv(cur, player_id, resource_key, qty):
    cur.execute(
        "INSERT INTO public.inventories (player_id, resource_key, quantity) "
        "VALUES (%s, %s, %s) "
        "ON CONFLICT (player_id, resource_key) DO UPDATE SET quantity = EXCLUDED.quantity",
        (str(player_id), resource_key, qty)
    )


def _set_cap(cur, trader_key, resource_key, buy_cap, sell_cap):
    cur.execute(
        "UPDATE public.trader_prices SET daily_buy_cap=%s, daily_sell_cap=%s "
        "WHERE trader_key=%s AND resource_key=%s AND city_id IS NULL",
        (buy_cap, sell_cap, trader_key, resource_key)
    )


def _set_prices(cur, trader_key, resource_key, buy_price, sell_price):
    cur.execute(
        "UPDATE public.trader_prices SET buy_price=%s, sell_price=%s "
        "WHERE trader_key=%s AND resource_key=%s AND city_id IS NULL",
        (buy_price, sell_price, trader_key, resource_key)
    )


def _backdate_visit(cur, player_id, trader_key, minutes_ago):
    cur.execute(
        "INSERT INTO public.trader_visits "
        "(trader_key, player_id, capacity_total, capacity_used, summary, visited_at) "
        "VALUES (%s, %s, 20, 0, '[]'::jsonb, now() - (%s || ' minutes')::interval)",
        (trader_key, str(player_id), minutes_ago)
    )


def test_sell_phase_skips_when_partner_below_floor(make_player, cur, clear_resources):
    """river_traders pays $4 per timber. With a floor of $5, no sells fire."""
    p = make_player(industry='timber')
    clear_resources(p['id'])
    _set_prices(cur, 'river_traders', 'timber', buy_price=4, sell_price=8)
    _set_cap(cur, 'river_traders', 'timber', buy_cap=100, sell_cap=100)

    _act_as(cur, p['id'])
    cur.execute(
        "SELECT public.save_trade_policy('timber', 'sell_surplus', 0, 5, NULL)"
    )
    _set_inv(cur, p['id'], 'timber', 200)

    _backdate_visit(cur, p['id'], 'river_traders', 200)
    cur.execute("SELECT public.process_production()")

    cur.execute("""
        SELECT qty_bought FROM public.trader_daily_quota
        WHERE player_id=%s AND trader_key='river_traders' AND resource_key='timber'
          AND day_bucket=CURRENT_DATE
    """, (str(p['id']),))
    row = cur.fetchone()
    assert row is None, 'no quota row should exist — partner price below floor'


def test_sell_phase_fires_when_partner_meets_floor(make_player, cur, clear_resources):
    """Same setup but floor at $4 (== price) — should sell."""
    p = make_player(industry='timber')
    clear_resources(p['id'])
    _set_prices(cur, 'river_traders', 'timber', buy_price=4, sell_price=8)
    _set_cap(cur, 'river_traders', 'timber', buy_cap=100, sell_cap=100)

    _act_as(cur, p['id'])
    cur.execute(
        "SELECT public.save_trade_policy('timber', 'sell_surplus', 0, 4, NULL)"
    )
    _set_inv(cur, p['id'], 'timber', 200)

    _backdate_visit(cur, p['id'], 'river_traders', 200)
    cur.execute("SELECT public.process_production()")

    cur.execute("""
        SELECT qty_bought FROM public.trader_daily_quota
        WHERE player_id=%s AND trader_key='river_traders' AND resource_key='timber'
          AND day_bucket=CURRENT_DATE
    """, (str(p['id']),))
    row = cur.fetchone()
    assert row is not None and row[0] > 0, 'sells should fire when price equals floor'


def test_buy_phase_skips_when_partner_above_ceiling(make_player, cur, clear_resources):
    """river_traders sells lumber at $13. With ceiling $12, no buys fire."""
    p = make_player(industry='timber')
    clear_resources(p['id'])
    cur.execute("UPDATE public.player_profiles SET money=100000 WHERE id=%s", (str(p['id']),))
    _set_prices(cur, 'river_traders', 'lumber', buy_price=7, sell_price=13)
    _set_cap(cur, 'river_traders', 'lumber', buy_cap=100, sell_cap=100)

    _act_as(cur, p['id'])
    cur.execute(
        "SELECT public.save_trade_policy('lumber', 'buy_to_reserve', 100, NULL, 12)"
    )

    _backdate_visit(cur, p['id'], 'river_traders', 200)
    cur.execute("SELECT public.process_production()")

    cur.execute("""
        SELECT qty_sold FROM public.trader_daily_quota
        WHERE player_id=%s AND trader_key='river_traders' AND resource_key='lumber'
          AND day_bucket=CURRENT_DATE
    """, (str(p['id']),))
    row = cur.fetchone()
    assert row is None, 'no quota row should exist — partner price above ceiling'


def test_save_trade_policy_persists_prices(make_player, cur):
    p = make_player(industry='timber')
    _act_as(cur, p['id'])
    cur.execute(
        "SELECT public.save_trade_policy('timber', 'sell_surplus', 0, 7, NULL)"
    )
    cur.execute(
        "SELECT min_sell_price, max_buy_price FROM public.trade_policies "
        "WHERE player_id=%s AND resource_key='timber'",
        (str(p['id']),)
    )
    assert cur.fetchone() == (7, None)
    cur.execute(
        "SELECT public.save_trade_policy('lumber', 'buy_to_reserve', 50, NULL, 14)"
    )
    cur.execute(
        "SELECT min_sell_price, max_buy_price FROM public.trade_policies "
        "WHERE player_id=%s AND resource_key='lumber'",
        (str(p['id']),)
    )
    assert cur.fetchone() == (None, 14)


def test_null_prices_preserve_legacy_behavior(make_player, cur, clear_resources):
    """No price gates set → policy behaves exactly as before."""
    p = make_player(industry='timber')
    clear_resources(p['id'])
    _set_prices(cur, 'river_traders', 'timber', buy_price=4, sell_price=8)
    _set_cap(cur, 'river_traders', 'timber', buy_cap=50, sell_cap=50)

    _act_as(cur, p['id'])
    cur.execute(
        "SELECT public.save_trade_policy('timber', 'sell_surplus', 0)"
    )
    _set_inv(cur, p['id'], 'timber', 200)

    _backdate_visit(cur, p['id'], 'river_traders', 200)
    cur.execute("SELECT public.process_production()")

    cur.execute("""
        SELECT qty_bought FROM public.trader_daily_quota
        WHERE player_id=%s AND trader_key='river_traders' AND resource_key='timber'
          AND day_bucket=CURRENT_DATE
    """, (str(p['id']),))
    row = cur.fetchone()
    assert row is not None and row[0] > 0, 'no gates → trade fires regardless of price'
