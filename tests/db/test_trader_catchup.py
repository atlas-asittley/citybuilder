"""Tests for trader auto-trade catch-up across offline time.

A player with a sell_surplus or buy_to_reserve policy who has been
"offline" for multiple visit intervals should, on next call to
resolve_trader_visit, have all the missed visits resolved at once.
This mirrors how process_production catches up for elapsed time.
"""
import psycopg2
import pytest


def _act_as(cur, uid):
    cur.execute("SELECT set_config('request.jwt.claims', %s, true)",
                ('{"sub": "%s", "role": "authenticated"}' % str(uid),))


def _set_inv(cur, uid, key, qty):
    cur.execute("""INSERT INTO public.inventories (player_id, resource_key, quantity)
                   VALUES (%s, %s, %s)
                   ON CONFLICT (player_id, resource_key) DO UPDATE SET quantity = %s""",
                (str(uid), key, qty, qty))


def _get_inv(cur, uid, key):
    cur.execute("SELECT COALESCE(quantity, 0) FROM public.inventories WHERE player_id = %s AND resource_key = %s",
                (str(uid), key))
    r = cur.fetchone()
    return float(r[0]) if r else 0


def _money(cur, uid):
    cur.execute("SELECT money FROM public.player_profiles WHERE id = %s", (str(uid),))
    return cur.fetchone()[0]


def _set_policy(cur, uid, resource_key, mode, reserve_target):
    """Insert/update a trade_policies row directly (the save_trade_policy
    RPC has its own validation that depends on which traders are
    unlocked; tests bypass that with a direct write)."""
    cur.execute("""INSERT INTO public.trade_policies (player_id, resource_key, mode, reserve_target)
                   VALUES (%s, %s, %s, %s)
                   ON CONFLICT (player_id, resource_key) DO UPDATE SET
                     mode = EXCLUDED.mode, reserve_target = EXCLUDED.reserve_target""",
                (str(uid), resource_key, mode, reserve_target))


def _backdate_profile(cur, uid, minutes):
    """Move the player's profile created_at backwards so the trader's
    'first visit' anchor is far enough in the past for many visits to
    be due."""
    cur.execute("UPDATE public.player_profiles SET created_at = now() - make_interval(mins => %s) WHERE id = %s",
                (minutes, str(uid)))


def _delete_visits(cur, uid):
    cur.execute("DELETE FROM public.trader_visits WHERE player_id = %s", (str(uid),))


def _clear_quota(cur, trader_key, resource_key):
    """trader_daily_quota is shared global state — any sell_surplus
    activity by REAL players during the day fills the bucket and
    blocks tests that try to sell the same resource. Tests should
    clear the relevant row at start; the savepoint wrapping each test
    rolls the deletion back."""
    cur.execute("DELETE FROM public.trader_daily_quota "
                " WHERE trader_key = %s AND resource_key = %s "
                "   AND day_bucket = CURRENT_DATE",
                (trader_key, resource_key))


def test_single_visit_resolves(make_player, cur):
    """Auto-resolve: a process_production tick resolves any visits whose
    cooldown has elapsed. Used to require an explicit resolve_trader_visit
    call but that's now legacy — auto-resolve in _pp_resolve_trader_visits
    handles it during the regular tick."""
    p = make_player(industry='timber', display_name='single_v')
    _act_as(cur, p['id'])
    _set_policy(cur, p['id'], 'timber', 'sell_surplus', 0)
    _set_inv(cur, p['id'], 'timber', 25.0)
    _backdate_profile(cur, p['id'], 11)
    _delete_visits(cur, p['id'])
    _clear_quota(cur, 'river_traders', 'timber')
    cur.execute("SELECT public.process_production()")
    cur.execute("""SELECT count(*) FROM public.trader_visits
                   WHERE player_id = %s AND trader_key = 'river_traders'""",
                (str(p['id']),))
    assert cur.fetchone()[0] >= 1


def test_multiple_offline_visits_catch_up(make_player, cur):
    """Player with 100 timber, sell_surplus policy. Backdate 65 min →
    ~6 visits due. Auto-resolve drains inventory across the catch-up."""
    p = make_player(industry='timber', display_name='catchup_player')
    _act_as(cur, p['id'])
    _set_policy(cur, p['id'], 'timber', 'sell_surplus', 0)
    _set_inv(cur, p['id'], 'timber', 100.0)
    _backdate_profile(cur, p['id'], 65)
    _delete_visits(cur, p['id'])
    _clear_quota(cur, 'river_traders', 'timber')
    money_before = _money(cur, p['id'])

    cur.execute("SELECT public.process_production()")

    cur.execute("""SELECT count(*) FROM public.trader_visits
                   WHERE player_id = %s AND trader_key = 'river_traders'""",
                (str(p['id']),))
    visits_resolved = cur.fetchone()[0]
    assert visits_resolved >= 5, f"expected ≥5 visits resolved, got {visits_resolved}"
    timber_after = _get_inv(cur, p['id'], 'timber')
    money_after = _money(cur, p['id'])
    assert timber_after == 0, f"expected timber to fully sell, got {timber_after}"
    assert money_after - money_before == 400, f"expected +400g, got +{money_after - money_before}"


def test_catchup_records_separate_visit_rows(make_player, cur):
    """Each catch-up visit records its own row in trader_visits with a
    distinct visited_at, so the visit history reflects the conceptual
    timeline rather than collapsing to one big row.

    Now driven through process_production (resolve_trader_visit was
    dropped in big_bug_sweep_2026_05_20 as a security-hole orphan)."""
    p = make_player(industry='timber', display_name='visit_history')
    _act_as(cur, p['id'])
    _set_policy(cur, p['id'], 'timber', 'sell_surplus', 0)
    _set_inv(cur, p['id'], 'timber', 50.0)
    _backdate_profile(cur, p['id'], 35)  # ~3 visits due
    _delete_visits(cur, p['id'])
    _clear_quota(cur, 'river_traders', 'timber')
    cur.execute("SELECT public.process_production()")
    cur.execute("""SELECT count(*) FROM public.trader_visits
                   WHERE player_id = %s AND trader_key = 'river_traders'""",
                (str(p['id']),))
    assert cur.fetchone()[0] >= 3


def test_no_visits_resolved_when_not_due(make_player, cur):
    """If the cooldown hasn't elapsed yet, process_production should not
    record any river_traders visits."""
    p = make_player(industry='timber', display_name='not_due')
    _act_as(cur, p['id'])
    _set_policy(cur, p['id'], 'timber', 'sell_surplus', 0)
    _set_inv(cur, p['id'], 'timber', 25.0)
    # Backdate only a few minutes — less than the 10 min interval.
    _backdate_profile(cur, p['id'], 3)
    _delete_visits(cur, p['id'])
    cur.execute("SELECT public.process_production()")
    cur.execute("""SELECT count(*) FROM public.trader_visits
                   WHERE player_id = %s AND trader_key = 'river_traders'""",
                (str(p['id']),))
    assert cur.fetchone()[0] == 0


def test_catchup_capped_at_50(make_player, cur):
    """Runaway guard: even if a player is offline for years, only 50
    visits resolve in one process_production call (otherwise the tick
    could lock the row arbitrarily long)."""
    p = make_player(industry='timber', display_name='capped')
    _act_as(cur, p['id'])
    _set_policy(cur, p['id'], 'timber', 'sell_surplus', 0)
    _set_inv(cur, p['id'], 'timber', 10000.0)
    # 100 visits' worth of backlog (10-min interval × 100 = 1000 min).
    _backdate_profile(cur, p['id'], 1000)
    _delete_visits(cur, p['id'])
    _clear_quota(cur, 'river_traders', 'timber')
    cur.execute("SELECT public.process_production()")
    cur.execute("""SELECT count(*) FROM public.trader_visits
                   WHERE player_id = %s AND trader_key = 'river_traders'""",
                (str(p['id']),))
    visits = cur.fetchone()[0]
    assert visits == 50, f"expected exactly 50 (cap), got {visits}"


def test_buy_to_reserve_also_catches_up(make_player, place, cur):
    """Buy-to-reserve policy should also accumulate across catch-up
    visits, via the auto-resolve in process_production. Uses
    river_traders (Neighboring City) — the always-on starter — since
    desert_caravan and mountain_folk were deactivated during the
    2026-05-08 trader-collapse migration."""
    p = make_player(industry='timber', display_name='buy_catchup')
    _act_as(cur, p['id'])
    cur.execute("UPDATE public.player_profiles SET money = 100000 WHERE id = %s", (str(p['id']),))
    _set_policy(cur, p['id'], 'timber', 'buy_to_reserve', 100)
    _set_inv(cur, p['id'], 'timber', 0.0)
    _backdate_profile(cur, p['id'], 60)
    _delete_visits(cur, p['id'])
    _clear_quota(cur, 'river_traders', 'timber')
    cur.execute("SELECT public.process_production()")
    cur.execute("""SELECT count(*) FROM public.trader_visits
                   WHERE player_id = %s AND trader_key = 'river_traders'""",
                (str(p['id']),))
    assert cur.fetchone()[0] >= 1
    timber = _get_inv(cur, p['id'], 'timber')
    assert timber >= 26, f"expected catch-up to accumulate timber, got {timber}"
