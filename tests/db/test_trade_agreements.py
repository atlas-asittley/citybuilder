"""Tests for recurring trade agreements between players.

Lifecycle: propose (pending) → accept (active) → fires on interval
→ cancel (cancelled). Resolver fires at most once per call, only
when driven by the proposer (from_player_id). Skipped firings (one
side can't pay) leave last_fired_at alone so the firing retries.
"""
import json
import uuid
import pytest


def _set_inv(cur, player_id, resource_key, qty):
    cur.execute("""INSERT INTO public.inventories (player_id, resource_key, quantity)
                   VALUES (%s, %s, %s)
                   ON CONFLICT (player_id, resource_key) DO UPDATE SET quantity = %s""",
                (str(player_id), resource_key, qty, qty))


def _get_inv(cur, player_id, resource_key):
    cur.execute("""SELECT quantity FROM public.inventories
                   WHERE player_id = %s AND resource_key = %s""",
                (str(player_id), resource_key))
    row = cur.fetchone()
    return float(row[0]) if row else 0


def _set_money(cur, player_id, money):
    cur.execute("UPDATE public.player_profiles SET money = %s WHERE id = %s",
                (money, str(player_id)))


def _get_money(cur, player_id):
    cur.execute("SELECT money FROM public.player_profiles WHERE id = %s", (str(player_id),))
    return cur.fetchone()[0]


def _act_as(cur, player_id):
    cur.execute("SELECT set_config('request.jwt.claims', %s, true)",
                ('{"sub": "%s", "role": "authenticated"}' % str(player_id),))


def _backdate_agreement(cur, agr_id, minutes_ago):
    """Push last_fired_at back so the agreement is due."""
    cur.execute("""UPDATE public.trade_agreements
                   SET last_fired_at = now() - (%s || ' minutes')::interval
                   WHERE id = %s""", (minutes_ago, str(agr_id)))


def test_propose_creates_pending_agreement(make_player, cur):
    a = make_player(industry='timber', display_name='alice')
    b = make_player(industry='stone', display_name='bob')
    _act_as(cur, a['id'])

    cur.execute("""SELECT (public.propose_trade_agreement(
        %s, %s::jsonb, 0, %s::jsonb, 0, 30, 'lumber for stone weekly'
    )).id""", (str(b['id']), json.dumps({'lumber': 5}), json.dumps({'stone': 10})))
    agr_id = cur.fetchone()[0]

    cur.execute("""SELECT status, from_player_id, to_player_id, interval_minutes
                   FROM public.trade_agreements WHERE id = %s""", (str(agr_id),))
    row = cur.fetchone()
    assert row[0] == 'pending'
    assert str(row[1]) == str(a['id'])
    assert str(row[2]) == str(b['id'])
    assert row[3] == 30


def test_propose_rejects_self_trade(make_player, cur):
    a = make_player()
    _act_as(cur, a['id'])
    with pytest.raises(Exception, match='cannot trade with yourself'):
        cur.execute("""SELECT public.propose_trade_agreement(
            %s, %s::jsonb, 0, %s::jsonb, 0, 30, NULL)""",
            (str(a['id']), json.dumps({'lumber': 1}), json.dumps({'stone': 1})))


def test_propose_rejects_zero_sided_trade(make_player, cur):
    a = make_player()
    b = make_player()
    _act_as(cur, a['id'])
    with pytest.raises(Exception, match='both sides must offer something'):
        cur.execute("""SELECT public.propose_trade_agreement(
            %s, %s::jsonb, 0, %s::jsonb, 0, 30, NULL)""",
            (str(b['id']), json.dumps({}), json.dumps({'stone': 1})))


def test_propose_rejects_bad_interval(make_player, cur):
    a = make_player()
    b = make_player()
    _act_as(cur, a['id'])
    with pytest.raises(Exception, match='interval must be between'):
        cur.execute("""SELECT public.propose_trade_agreement(
            %s, %s::jsonb, 0, %s::jsonb, 0, 1, NULL)""",
            (str(b['id']), json.dumps({'lumber': 1}), json.dumps({'stone': 1})))


def test_accept_activates_agreement(make_player, cur):
    a = make_player()
    b = make_player()
    _act_as(cur, a['id'])
    cur.execute("""SELECT (public.propose_trade_agreement(
        %s, %s::jsonb, 0, %s::jsonb, 0, 30, NULL)).id""",
        (str(b['id']), json.dumps({'lumber': 5}), json.dumps({'stone': 10})))
    agr_id = cur.fetchone()[0]

    _act_as(cur, b['id'])
    cur.execute("""SELECT (public.accept_trade_agreement(%s)).status""", (str(agr_id),))
    assert cur.fetchone()[0] == 'active'


def test_accept_rejects_non_recipient(make_player, cur):
    a = make_player()
    b = make_player()
    c = make_player()
    _act_as(cur, a['id'])
    cur.execute("""SELECT (public.propose_trade_agreement(
        %s, %s::jsonb, 0, %s::jsonb, 0, 30, NULL)).id""",
        (str(b['id']), json.dumps({'lumber': 1}), json.dumps({'stone': 1})))
    agr_id = cur.fetchone()[0]

    _act_as(cur, c['id'])
    with pytest.raises(Exception, match='only the counterparty can accept'):
        cur.execute("""SELECT public.accept_trade_agreement(%s)""", (str(agr_id),))


def test_cancel_works_from_either_side(make_player, cur):
    a = make_player()
    b = make_player()
    _act_as(cur, a['id'])
    cur.execute("""SELECT (public.propose_trade_agreement(
        %s, %s::jsonb, 0, %s::jsonb, 0, 30, NULL)).id""",
        (str(b['id']), json.dumps({'lumber': 1}), json.dumps({'stone': 1})))
    agr_id = cur.fetchone()[0]
    _act_as(cur, b['id'])
    cur.execute("""SELECT (public.accept_trade_agreement(%s)).status""", (str(agr_id),))
    assert cur.fetchone()[0] == 'active'

    # Either side can cancel.
    _act_as(cur, b['id'])
    cur.execute("""SELECT (public.cancel_trade_agreement(%s)).status""", (str(agr_id),))
    assert cur.fetchone()[0] == 'cancelled'


def test_resolver_fires_when_due_with_stock(make_player, cur):
    a = make_player()
    b = make_player()
    _set_inv(cur, a['id'], 'lumber', 100)
    _set_inv(cur, b['id'], 'stone', 100)

    _act_as(cur, a['id'])
    cur.execute("""SELECT (public.propose_trade_agreement(
        %s, %s::jsonb, 0, %s::jsonb, 0, 30, NULL)).id""",
        (str(b['id']), json.dumps({'lumber': 5}), json.dumps({'stone': 10})))
    agr_id = cur.fetchone()[0]
    _act_as(cur, b['id'])
    cur.execute("""SELECT public.accept_trade_agreement(%s)""", (str(agr_id),))
    _backdate_agreement(cur, agr_id, 60)  # 60 min ago, due now

    _act_as(cur, a['id'])
    cur.execute("SELECT public._pp_run_agreements(%s)", (str(a['id']),))

    assert _get_inv(cur, a['id'], 'lumber') == 95
    assert _get_inv(cur, b['id'], 'lumber') == 5
    assert _get_inv(cur, b['id'], 'stone') == 90
    assert _get_inv(cur, a['id'], 'stone') == 10


def test_resolver_skips_when_proposer_short(make_player, cur):
    a = make_player()
    b = make_player()
    _set_inv(cur, a['id'], 'lumber', 2)  # short — needs 5
    _set_inv(cur, b['id'], 'stone', 100)

    _act_as(cur, a['id'])
    cur.execute("""SELECT (public.propose_trade_agreement(
        %s, %s::jsonb, 0, %s::jsonb, 0, 30, NULL)).id""",
        (str(b['id']), json.dumps({'lumber': 5}), json.dumps({'stone': 10})))
    agr_id = cur.fetchone()[0]
    _act_as(cur, b['id'])
    cur.execute("SELECT public.accept_trade_agreement(%s)", (str(agr_id),))
    _backdate_agreement(cur, agr_id, 60)

    _act_as(cur, a['id'])
    cur.execute("SELECT public._pp_run_agreements(%s)", (str(a['id']),))

    # Inventories unchanged.
    assert _get_inv(cur, a['id'], 'lumber') == 2
    assert _get_inv(cur, b['id'], 'stone') == 100
    # Schedule didn't advance — still due.
    cur.execute("""SELECT (now() - last_fired_at) > (interval_minutes || ' minutes')::interval
                   FROM public.trade_agreements WHERE id = %s""", (str(agr_id),))
    assert cur.fetchone()[0] is True


def test_resolver_skips_when_recipient_short(make_player, cur):
    a = make_player()
    b = make_player()
    _set_inv(cur, a['id'], 'lumber', 100)
    _set_inv(cur, b['id'], 'stone', 3)  # short — needs 10

    _act_as(cur, a['id'])
    cur.execute("""SELECT (public.propose_trade_agreement(
        %s, %s::jsonb, 0, %s::jsonb, 0, 30, NULL)).id""",
        (str(b['id']), json.dumps({'lumber': 5}), json.dumps({'stone': 10})))
    agr_id = cur.fetchone()[0]
    _act_as(cur, b['id'])
    cur.execute("SELECT public.accept_trade_agreement(%s)", (str(agr_id),))
    _backdate_agreement(cur, agr_id, 60)

    _act_as(cur, a['id'])
    cur.execute("SELECT public._pp_run_agreements(%s)", (str(a['id']),))

    assert _get_inv(cur, a['id'], 'lumber') == 100
    assert _get_inv(cur, b['id'], 'stone') == 3


def test_resolver_fires_at_most_once_per_call(make_player, cur):
    """Bounded backlog: a long-overdue agreement only fires once per call."""
    a = make_player()
    b = make_player()
    _set_inv(cur, a['id'], 'lumber', 100)
    _set_inv(cur, b['id'], 'stone', 100)

    _act_as(cur, a['id'])
    cur.execute("""SELECT (public.propose_trade_agreement(
        %s, %s::jsonb, 0, %s::jsonb, 0, 30, NULL)).id""",
        (str(b['id']), json.dumps({'lumber': 5}), json.dumps({'stone': 10})))
    agr_id = cur.fetchone()[0]
    _act_as(cur, b['id'])
    cur.execute("SELECT public.accept_trade_agreement(%s)", (str(agr_id),))
    _backdate_agreement(cur, agr_id, 600)  # 10 hours ago — 20 cycles overdue

    _act_as(cur, a['id'])
    cur.execute("SELECT public._pp_run_agreements(%s)", (str(a['id']),))
    cur.execute("SELECT public._pp_run_agreements(%s)", (str(a['id']),))
    cur.execute("SELECT public._pp_run_agreements(%s)", (str(a['id']),))

    # Three calls = at most three fires, even though 20+ cycles are overdue.
    assert _get_inv(cur, a['id'], 'lumber') == 85  # 100 - 3*5
    assert _get_inv(cur, b['id'], 'stone') == 70   # 100 - 3*10


def test_resolver_only_runs_for_proposer(make_player, cur):
    """Recipient ticking does not fire — keeps single-driver semantics."""
    a = make_player()
    b = make_player()
    _set_inv(cur, a['id'], 'lumber', 100)
    _set_inv(cur, b['id'], 'stone', 100)

    _act_as(cur, a['id'])
    cur.execute("""SELECT (public.propose_trade_agreement(
        %s, %s::jsonb, 0, %s::jsonb, 0, 30, NULL)).id""",
        (str(b['id']), json.dumps({'lumber': 5}), json.dumps({'stone': 10})))
    agr_id = cur.fetchone()[0]
    _act_as(cur, b['id'])
    cur.execute("SELECT public.accept_trade_agreement(%s)", (str(agr_id),))
    _backdate_agreement(cur, agr_id, 60)

    # B (recipient) ticks — should NOT fire.
    cur.execute("SELECT public._pp_run_agreements(%s)", (str(b['id']),))
    assert _get_inv(cur, a['id'], 'lumber') == 100


def test_money_only_agreement(make_player, cur):
    a = make_player()
    b = make_player()
    _set_money(cur, a['id'], 5000)
    _set_money(cur, b['id'], 5000)
    _set_inv(cur, b['id'], 'lumber', 50)

    _act_as(cur, a['id'])
    # A pays $100 every 30min for 5 lumber from B.
    cur.execute("""SELECT (public.propose_trade_agreement(
        %s, %s::jsonb, 100, %s::jsonb, 0, 30, NULL)).id""",
        (str(b['id']), json.dumps({}), json.dumps({'lumber': 5})))
    agr_id = cur.fetchone()[0]
    _act_as(cur, b['id'])
    cur.execute("SELECT public.accept_trade_agreement(%s)", (str(agr_id),))
    _backdate_agreement(cur, agr_id, 60)

    _act_as(cur, a['id'])
    cur.execute("SELECT public._pp_run_agreements(%s)", (str(a['id']),))

    assert _get_money(cur, a['id']) == 4900
    assert _get_money(cur, b['id']) == 5100
    assert _get_inv(cur, a['id'], 'lumber') == 5
    assert _get_inv(cur, b['id'], 'lumber') == 45


def test_list_returns_role_and_counterparty(make_player, cur):
    a = make_player(display_name='alice')
    b = make_player(display_name='bob')
    _act_as(cur, a['id'])
    cur.execute("""SELECT (public.propose_trade_agreement(
        %s, %s::jsonb, 0, %s::jsonb, 0, 30, NULL)).id""",
        (str(b['id']), json.dumps({'lumber': 1}), json.dumps({'stone': 1})))

    cur.execute("SELECT role, counterparty_name FROM public.list_trade_agreements()")
    rows = cur.fetchall()
    assert len(rows) == 1
    assert rows[0][0] == 'proposer'
    assert rows[0][1] == 'bob'

    _act_as(cur, b['id'])
    cur.execute("SELECT role, counterparty_name FROM public.list_trade_agreements()")
    rows = cur.fetchall()
    assert len(rows) == 1
    assert rows[0][0] == 'recipient'
    assert rows[0][1] == 'alice'
