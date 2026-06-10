"""Tests for player-to-player trade offers.

A player crafts an offer (give money + resources, receive money +
resources). Recipient accepts (atomic transfer) or rejects; sender
can cancel before resolution. Goods aren't locked at propose time —
balances are validated again at accept time.
"""
import json
import uuid
import psycopg2
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


# ── propose_trade ──

def test_propose_creates_pending_offer(make_player, cur):
    a = make_player(industry='timber', display_name='alice')
    b = make_player(industry='stone', display_name='bob')
    _set_money(cur, a['id'], 1000)
    _act_as(cur, a['id'])
    cur.execute("""SELECT public.propose_trade(%s, 100, '{}'::jsonb, 0, '{}'::jsonb, %s)""",
                (str(b['id']), 'gift'))
    offer_id = cur.fetchone()[0]
    cur.execute("""SELECT from_player_id, to_player_id, give_money, receive_money, status, message
                   FROM public.player_trade_offers WHERE id = %s""", (str(offer_id),))
    row = cur.fetchone()
    assert str(row[0]) == str(a['id'])
    assert str(row[1]) == str(b['id'])
    assert row[2] == 100
    assert row[3] == 0
    assert row[4] == 'pending'
    assert row[5] == 'gift'


def test_propose_rejects_self_trade(make_player, cur):
    a = make_player(display_name='solo')
    _act_as(cur, a['id'])
    with pytest.raises(psycopg2.errors.RaiseException):
        cur.execute("""SELECT public.propose_trade(%s, 100, '{}'::jsonb, 0, '{}'::jsonb, NULL)""",
                    (str(a['id']),))


def test_propose_rejects_empty_offer(make_player, cur):
    a = make_player(display_name='alice2')
    b = make_player(display_name='bob2')
    _act_as(cur, a['id'])
    with pytest.raises(psycopg2.errors.RaiseException):
        cur.execute("""SELECT public.propose_trade(%s, 0, '{}'::jsonb, 0, '{}'::jsonb, NULL)""",
                    (str(b['id']),))


def test_propose_rejects_negative_money(make_player, cur):
    a = make_player(display_name='alice3')
    b = make_player(display_name='bob3')
    _act_as(cur, a['id'])
    with pytest.raises(psycopg2.errors.RaiseException):
        cur.execute("""SELECT public.propose_trade(%s, -50, '{}'::jsonb, 0, '{}'::jsonb, NULL)""",
                    (str(b['id']),))


def test_propose_rejects_unknown_resource(make_player, cur):
    a = make_player(display_name='alice4')
    b = make_player(display_name='bob4')
    _act_as(cur, a['id'])
    with pytest.raises(psycopg2.errors.RaiseException):
        cur.execute("""SELECT public.propose_trade(%s, 0, %s::jsonb, 0, '{}'::jsonb, NULL)""",
                    (str(b['id']), '{"unobtainium": 5}'))


def test_propose_rejects_zero_or_negative_quantity(make_player, cur):
    a = make_player(display_name='alice5')
    b = make_player(display_name='bob5')
    _act_as(cur, a['id'])
    with pytest.raises(psycopg2.errors.RaiseException):
        cur.execute("""SELECT public.propose_trade(%s, 0, %s::jsonb, 0, '{}'::jsonb, NULL)""",
                    (str(b['id']), '{"timber": 0}'))


# ── accept_trade ──

def test_accept_money_only_gift(make_player, cur):
    a = make_player(display_name='gifter')
    b = make_player(display_name='giftee')
    _set_money(cur, a['id'], 5000)
    _set_money(cur, b['id'], 100)
    _act_as(cur, a['id'])
    cur.execute("""SELECT public.propose_trade(%s, 1000, '{}'::jsonb, 0, '{}'::jsonb, 'here you go')""",
                (str(b['id']),))
    offer_id = cur.fetchone()[0]
    _act_as(cur, b['id'])
    cur.execute("SELECT public.accept_trade(%s)", (str(offer_id),))
    assert _get_money(cur, a['id']) == 4000
    assert _get_money(cur, b['id']) == 1100
    cur.execute("SELECT status FROM public.player_trade_offers WHERE id = %s", (str(offer_id),))
    assert cur.fetchone()[0] == 'accepted'


def test_accept_two_way_resource_swap(make_player, cur):
    a = make_player(industry='timber', display_name='timber_p')
    b = make_player(industry='stone', display_name='stone_p')
    _set_money(cur, a['id'], 1000)
    _set_money(cur, b['id'], 1000)
    _set_inv(cur, a['id'], 'timber', 50.0)
    _set_inv(cur, b['id'], 'stone', 30.0)
    _act_as(cur, a['id'])
    cur.execute("""SELECT public.propose_trade(%s, 0, %s::jsonb, 0, %s::jsonb, NULL)""",
                (str(b['id']), '{"timber": 10}', '{"stone": 5}'))
    offer_id = cur.fetchone()[0]
    _act_as(cur, b['id'])
    cur.execute("SELECT public.accept_trade(%s)", (str(offer_id),))
    assert _get_inv(cur, a['id'], 'timber') == 40.0
    assert _get_inv(cur, b['id'], 'timber') == 10.0
    assert _get_inv(cur, a['id'], 'stone') == 5.0
    assert _get_inv(cur, b['id'], 'stone') == 25.0


def test_accept_with_money_and_resources(make_player, cur):
    a = make_player(industry='timber', display_name='ta')
    b = make_player(industry='stone', display_name='tb')
    _set_money(cur, a['id'], 1000)
    _set_money(cur, b['id'], 200)
    _set_inv(cur, b['id'], 'stone', 30.0)
    _act_as(cur, a['id'])
    cur.execute("""SELECT public.propose_trade(%s, 500, '{}'::jsonb, 0, %s::jsonb, NULL)""",
                (str(b['id']), '{"stone": 10}'))
    offer_id = cur.fetchone()[0]
    _act_as(cur, b['id'])
    cur.execute("SELECT public.accept_trade(%s)", (str(offer_id),))
    assert _get_money(cur, a['id']) == 500
    assert _get_money(cur, b['id']) == 700
    assert _get_inv(cur, a['id'], 'stone') == 10.0
    assert _get_inv(cur, b['id'], 'stone') == 20.0


def test_accept_fails_if_sender_short_money(make_player, cur):
    a = make_player(display_name='broke_a')
    b = make_player(display_name='broke_b')
    _set_money(cur, a['id'], 5000)
    _act_as(cur, a['id'])
    cur.execute("""SELECT public.propose_trade(%s, 1000, '{}'::jsonb, 0, '{}'::jsonb, NULL)""",
                (str(b['id']),))
    offer_id = cur.fetchone()[0]
    # Sender spent the money before accept.
    _set_money(cur, a['id'], 100)
    _act_as(cur, b['id'])
    with pytest.raises(psycopg2.errors.RaiseException):
        cur.execute("SELECT public.accept_trade(%s)", (str(offer_id),))


def test_accept_fails_if_recipient_short_money(make_player, cur):
    a = make_player(display_name='ra')
    b = make_player(display_name='rb')
    _set_money(cur, a['id'], 1000)
    _set_money(cur, b['id'], 100)
    _act_as(cur, a['id'])
    cur.execute("""SELECT public.propose_trade(%s, 0, '{}'::jsonb, 500, '{}'::jsonb, NULL)""",
                (str(b['id']),))
    offer_id = cur.fetchone()[0]
    _act_as(cur, b['id'])
    with pytest.raises(psycopg2.errors.RaiseException):
        cur.execute("SELECT public.accept_trade(%s)", (str(offer_id),))


def test_accept_fails_if_sender_short_resources(make_player, cur):
    a = make_player(industry='timber', display_name='ta2')
    b = make_player(display_name='tb2')
    _set_inv(cur, a['id'], 'timber', 10.0)
    _act_as(cur, a['id'])
    cur.execute("""SELECT public.propose_trade(%s, 0, %s::jsonb, 0, '{}'::jsonb, NULL)""",
                (str(b['id']), '{"timber": 50}'))
    offer_id = cur.fetchone()[0]
    _act_as(cur, b['id'])
    with pytest.raises(psycopg2.errors.RaiseException):
        cur.execute("SELECT public.accept_trade(%s)", (str(offer_id),))


def test_only_recipient_can_accept(make_player, cur):
    a = make_player(display_name='aa')
    b = make_player(display_name='bb')
    _set_money(cur, a['id'], 1000)
    _act_as(cur, a['id'])
    cur.execute("""SELECT public.propose_trade(%s, 100, '{}'::jsonb, 0, '{}'::jsonb, NULL)""",
                (str(b['id']),))
    offer_id = cur.fetchone()[0]
    # Sender tries to accept own offer.
    with pytest.raises(psycopg2.errors.RaiseException):
        cur.execute("SELECT public.accept_trade(%s)", (str(offer_id),))


def test_cannot_accept_twice(make_player, cur):
    a = make_player(display_name='dup_a')
    b = make_player(display_name='dup_b')
    _set_money(cur, a['id'], 1000)
    _act_as(cur, a['id'])
    cur.execute("""SELECT public.propose_trade(%s, 100, '{}'::jsonb, 0, '{}'::jsonb, NULL)""",
                (str(b['id']),))
    offer_id = cur.fetchone()[0]
    _act_as(cur, b['id'])
    cur.execute("SELECT public.accept_trade(%s)", (str(offer_id),))
    with pytest.raises(psycopg2.errors.RaiseException):
        cur.execute("SELECT public.accept_trade(%s)", (str(offer_id),))


# ── reject_trade / cancel_trade ──

def test_recipient_can_reject(make_player, cur):
    a = make_player(display_name='rj_a')
    b = make_player(display_name='rj_b')
    _set_money(cur, a['id'], 1000)
    _act_as(cur, a['id'])
    cur.execute("""SELECT public.propose_trade(%s, 100, '{}'::jsonb, 0, '{}'::jsonb, NULL)""",
                (str(b['id']),))
    offer_id = cur.fetchone()[0]
    _act_as(cur, b['id'])
    cur.execute("SELECT public.reject_trade(%s)", (str(offer_id),))
    cur.execute("SELECT status FROM public.player_trade_offers WHERE id = %s", (str(offer_id),))
    assert cur.fetchone()[0] == 'rejected'
    # No money moved.
    assert _get_money(cur, a['id']) == 1000


def test_sender_can_cancel(make_player, cur):
    a = make_player(display_name='cn_a')
    b = make_player(display_name='cn_b')
    _set_money(cur, a['id'], 1000)
    _act_as(cur, a['id'])
    cur.execute("""SELECT public.propose_trade(%s, 100, '{}'::jsonb, 0, '{}'::jsonb, NULL)""",
                (str(b['id']),))
    offer_id = cur.fetchone()[0]
    cur.execute("SELECT public.cancel_trade(%s)", (str(offer_id),))
    cur.execute("SELECT status FROM public.player_trade_offers WHERE id = %s", (str(offer_id),))
    assert cur.fetchone()[0] == 'cancelled'


def test_sender_cannot_reject_own_offer(make_player, cur):
    a = make_player(display_name='sr_a')
    b = make_player(display_name='sr_b')
    _set_money(cur, a['id'], 1000)
    _act_as(cur, a['id'])
    cur.execute("""SELECT public.propose_trade(%s, 100, '{}'::jsonb, 0, '{}'::jsonb, NULL)""",
                (str(b['id']),))
    offer_id = cur.fetchone()[0]
    with pytest.raises(psycopg2.errors.RaiseException):
        cur.execute("SELECT public.reject_trade(%s)", (str(offer_id),))


def test_recipient_cannot_cancel(make_player, cur):
    a = make_player(display_name='rc_a')
    b = make_player(display_name='rc_b')
    _set_money(cur, a['id'], 1000)
    _act_as(cur, a['id'])
    cur.execute("""SELECT public.propose_trade(%s, 100, '{}'::jsonb, 0, '{}'::jsonb, NULL)""",
                (str(b['id']),))
    offer_id = cur.fetchone()[0]
    _act_as(cur, b['id'])
    with pytest.raises(psycopg2.errors.RaiseException):
        cur.execute("SELECT public.cancel_trade(%s)", (str(offer_id),))
