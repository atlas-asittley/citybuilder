"""Smoke tests for RPCs that the client calls but had no test
coverage. Each one verifies the happy path + at least one
authorization or validation failure mode."""
import psycopg2
import pytest


def _act_as(cur, player_id):
    cur.execute("SELECT set_config('request.jwt.claims', %s, true)",
                ('{"sub": "' + str(player_id) + '"}',))


# ── black_market_trade ────────────────────────────────────────────────


def test_black_market_sell_credits_money(make_player, cur):
    p = make_player(industry='timber')
    cur.execute("UPDATE public.player_profiles SET money=0 WHERE id=%s", (str(p['id']),))
    cur.execute("INSERT INTO public.inventories (player_id, resource_key, quantity) "
                "VALUES (%s, 'timber', 100) "
                "ON CONFLICT (player_id, resource_key) DO UPDATE SET quantity=100",
                (str(p['id']),))
    cur.execute("SELECT public.black_market_trade('timber', 10, 'sell')")
    result = cur.fetchone()[0]
    assert result['unit_price'] >= 1
    assert result['total_price'] == result['unit_price'] * 10
    cur.execute("SELECT money FROM public.player_profiles WHERE id=%s", (str(p['id']),))
    assert cur.fetchone()[0] == result['total_price']


def test_black_market_sell_rejects_insufficient_inventory(make_player, cur):
    p = make_player(industry='timber')
    cur.execute("UPDATE public.player_profiles SET money=0 WHERE id=%s", (str(p['id']),))
    cur.execute("INSERT INTO public.inventories (player_id, resource_key, quantity) "
                "VALUES (%s, 'timber', 5) "
                "ON CONFLICT (player_id, resource_key) DO UPDATE SET quantity=5",
                (str(p['id']),))
    with pytest.raises(psycopg2.errors.RaiseException) as exc:
        cur.execute("SELECT public.black_market_trade('timber', 100, 'sell')")
    assert 'not enough' in str(exc.value).lower()


def test_black_market_buy_debits_money(make_player, cur):
    p = make_player(industry='timber')
    cur.execute("UPDATE public.player_profiles SET money=10000 WHERE id=%s", (str(p['id']),))
    cur.execute("DELETE FROM public.inventories WHERE player_id=%s AND resource_key='lumber'",
                (str(p['id']),))
    cur.execute("SELECT public.black_market_trade('lumber', 5, 'buy')")
    result = cur.fetchone()[0]
    cur.execute("SELECT quantity FROM public.inventories WHERE player_id=%s AND resource_key='lumber'",
                (str(p['id']),))
    assert float(cur.fetchone()[0]) == 5.0
    cur.execute("SELECT money FROM public.player_profiles WHERE id=%s", (str(p['id']),))
    assert cur.fetchone()[0] == 10000 - result['total_price']


def test_black_market_buy_rejects_insufficient_money(make_player, cur):
    p = make_player(industry='timber')
    cur.execute("UPDATE public.player_profiles SET money=1 WHERE id=%s", (str(p['id']),))
    with pytest.raises(psycopg2.errors.RaiseException) as exc:
        cur.execute("SELECT public.black_market_trade('lumber', 100, 'buy')")
    assert 'not enough money' in str(exc.value).lower()


# ── save_trade_policy ─────────────────────────────────────────────────


def test_save_trade_policy_inserts_and_updates(make_player, cur):
    p = make_player(industry='timber')
    _act_as(cur, p['id'])
    cur.execute("DELETE FROM public.trade_policies WHERE player_id=%s", (str(p['id']),))
    cur.execute("SELECT public.save_trade_policy('timber', 'sell_surplus', 50)")
    cur.execute("SELECT mode, reserve_target FROM public.trade_policies "
                "WHERE player_id=%s AND resource_key='timber'", (str(p['id']),))
    assert cur.fetchone() == ('sell_surplus', 50)
    # Update path
    cur.execute("SELECT public.save_trade_policy('timber', 'buy_to_reserve', 75)")
    cur.execute("SELECT mode, reserve_target FROM public.trade_policies "
                "WHERE player_id=%s AND resource_key='timber'", (str(p['id']),))
    assert cur.fetchone() == ('buy_to_reserve', 75)


# ── rename_district / rename_city ─────────────────────────────────────


def test_rename_district_changes_name(make_player, cur):
    p = make_player(industry='timber')
    _act_as(cur, p['id'])
    cur.execute("SELECT public.rename_district('Greenglen')")
    cur.execute("SELECT district_name FROM public.player_profiles WHERE id=%s", (str(p['id']),))
    assert cur.fetchone()[0] == 'Greenglen'


def test_rename_district_rejects_too_short(make_player, cur):
    p = make_player(industry='timber')
    _act_as(cur, p['id'])
    with pytest.raises(psycopg2.errors.RaiseException):
        cur.execute("SELECT public.rename_district('a')")


def test_rename_city_changes_name(make_player, cur):
    p = make_player(industry='timber')
    _act_as(cur, p['id'])
    cur.execute("SELECT public.rename_city('Quarryton')")
    cur.execute("SELECT c.name FROM public.cities c "
                "JOIN public.player_profiles p ON p.city_id=c.id WHERE p.id=%s",
                (str(p['id']),))
    assert cur.fetchone()[0] == 'Quarryton'


# ── dev_grant_money ───────────────────────────────────────────────────


def test_dev_grant_money_credits_and_logs(make_player, cur):
    p = make_player(industry='timber')
    _act_as(cur, p['id'])
    cur.execute("SELECT money FROM public.player_profiles WHERE id=%s", (str(p['id']),))
    starting = cur.fetchone()[0]
    cur.execute("SELECT public.dev_grant_money(50000)")
    cur.execute("SELECT money FROM public.player_profiles WHERE id=%s", (str(p['id']),))
    assert cur.fetchone()[0] == starting + 50000
    # Ledger row recorded.
    cur.execute("SELECT amount FROM public.cash_transactions "
                "WHERE player_id=%s AND source='ledger_adjustment' "
                "  AND context->>'reason' = 'triple_tap_cheat'",
                (str(p['id']),))
    assert cur.fetchone()[0] == 50000


def _expect_raise(cur, sql, *args):
    """Wrap an expected-to-fail call in its own savepoint so the
    transaction stays usable for the next assertion."""
    cur.execute("SAVEPOINT er")
    try:
        cur.execute(sql, args)
        cur.execute("RELEASE SAVEPOINT er")
        raise AssertionError(f'expected RaiseException, got success: {sql}')
    except psycopg2.errors.RaiseException as e:
        cur.execute("ROLLBACK TO SAVEPOINT er")
        return str(e)


def test_dev_grant_money_rejects_invalid_amount(make_player, cur):
    p = make_player(industry='timber')
    _act_as(cur, p['id'])
    _expect_raise(cur, "SELECT public.dev_grant_money(-100)")
    _expect_raise(cur, "SELECT public.dev_grant_money(0)")
    _expect_raise(cur, "SELECT public.dev_grant_money(99999999)")


# ── submit_bug_report ─────────────────────────────────────────────────


def test_submit_bug_report_writes_row(make_player, cur):
    p = make_player(industry='timber')
    _act_as(cur, p['id'])
    cur.execute("SELECT public.submit_bug_report('Test description', '{}'::jsonb)")
    bug_id = cur.fetchone()[0]
    cur.execute("SELECT description, server_state IS NOT NULL FROM public.bug_reports WHERE id=%s",
                (str(bug_id),))
    desc, has_state = cur.fetchone()
    assert desc == 'Test description'
    assert has_state, 'submit_bug_report should populate server_state snapshot'


def test_submit_bug_report_rejects_empty_description(make_player, cur):
    p = make_player(industry='timber')
    _act_as(cur, p['id'])
    _expect_raise(cur, "SELECT public.submit_bug_report('   ', '{}'::jsonb)")
    _expect_raise(cur, "SELECT public.submit_bug_report(repeat('x', 6000), '{}'::jsonb)")


# ── fetch_unread_notifications ─────────────────────────────────────────


def test_fetch_unread_notifications_returns_then_empty(make_player, cur):
    a = make_player(industry='timber', display_name='Aa')
    b = make_player(industry='timber', display_name='Bb')
    # Drew offers Jill a trade — trigger fires, Jill gets a notification row.
    _act_as(cur, a['id'])
    cur.execute("SELECT public.propose_trade_agreement(%s, '{\"timber\":1}'::jsonb, 0, '{}'::jsonb, 5, 60, 'test')",
                (str(b['id']),))
    # Jill drains.
    _act_as(cur, b['id'])
    cur.execute("SELECT count(*) FROM public.fetch_unread_notifications()")
    first = cur.fetchone()[0]
    assert first >= 1
    cur.execute("SELECT count(*) FROM public.fetch_unread_notifications()")
    second = cur.fetchone()[0]
    assert second == 0, 'second call should return nothing (rows already marked read)'
