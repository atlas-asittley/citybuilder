"""Trader supply contracts: pooled-money pledges that bump a trader's
city-wide daily cap on a specific resource when the pool hits its
threshold.

Server contract lives in
city-builder-mvp/migration_patches/trader_supply_contracts.sql.
"""
import psycopg2
import pytest


def _set_money(cur, player_id, amount):
    cur.execute("UPDATE public.player_profiles SET money = %s WHERE id = %s",
                (amount, str(player_id)))


def _force_threshold(cur, contract_id, new_threshold):
    """Tests don't want to scale up the city pop just to make a contract
    affordable. After the initial create-or-fetch in contribute, override
    the contract's threshold so the next pledge can land at a known amount."""
    cur.execute("UPDATE public.trader_supply_contracts SET threshold_money = %s WHERE id = %s",
                (new_threshold, contract_id))


def _get_contract(cur, trader, resource, direction):
    cur.execute("""SELECT id, pool_money, threshold_money, bumps_funded, current_round_at, last_settled_at
      FROM trader_supply_contracts
      WHERE trader_key = %s AND resource_key = %s AND direction = %s""",
      (trader, resource, direction))
    row = cur.fetchone()
    return row


def _existing_pair(cur):
    """Pick any existing (trader, resource) pair we know has a trader_prices
    row, so the cap-bump path lands cleanly on real data."""
    cur.execute("""SELECT trader_key, resource_key, daily_sell_cap
      FROM trader_prices WHERE is_active AND daily_sell_cap >= 0 LIMIT 1""")
    return cur.fetchone()


# ── auth + validation ───────────────────────────────────────────────

def test_contribute_requires_auth(cur):
    cur.execute("SAVEPOINT _na")
    cur.execute("SELECT set_config('request.jwt.claims', '', true)")
    trader, resource, _ = _existing_pair(cur)
    with pytest.raises(psycopg2.errors.RaiseException):
        cur.execute("SELECT public.contribute_to_supply_contract(%s, %s, %s, %s)",
                    (trader, resource, 'sell', 1000))
    cur.execute("ROLLBACK TO SAVEPOINT _na")


def test_contribute_rejects_invalid_direction(make_player, cur, as_user):
    p = make_player()
    _set_money(cur, p['id'], 100000)
    as_user(p['id'])
    trader, resource, _ = _existing_pair(cur)
    with pytest.raises(psycopg2.errors.RaiseException) as exc:
        cur.execute("SELECT public.contribute_to_supply_contract(%s, %s, %s, %s)",
                    (trader, resource, 'borrow', 1000))
    assert 'direction' in str(exc.value).lower()


def test_contribute_rejects_unknown_resource(make_player, cur, as_user):
    p = make_player()
    _set_money(cur, p['id'], 100000)
    as_user(p['id'])
    trader, _, _ = _existing_pair(cur)
    with pytest.raises(psycopg2.errors.RaiseException) as exc:
        cur.execute("SELECT public.contribute_to_supply_contract(%s, %s, %s, %s)",
                    (trader, 'unobtanium', 'sell', 1000))
    assert 'unknown resource' in str(exc.value).lower()


def test_contribute_rejects_insufficient_funds(make_player, cur, as_user):
    p = make_player()
    _set_money(cur, p['id'], 100)   # not enough
    as_user(p['id'])
    trader, resource, _ = _existing_pair(cur)
    with pytest.raises(psycopg2.errors.RaiseException) as exc:
        cur.execute("SELECT public.contribute_to_supply_contract(%s, %s, %s, %s)",
                    (trader, resource, 'sell', 1000))
    assert 'not enough money' in str(exc.value).lower()


# ── pool accumulation ──────────────────────────────────────────────

def test_contribute_below_threshold_pools_without_settling(make_player, cur, as_user):
    p = make_player()
    _set_money(cur, p['id'], 200000)
    as_user(p['id'])
    trader, resource, _ = _existing_pair(cur)

    # First pledge auto-creates the contract.
    cur.execute("SELECT public.contribute_to_supply_contract(%s, %s, %s, %s)",
                (trader, resource, 'sell', 1000))
    contract = _get_contract(cur, trader, resource, 'sell')
    assert contract is not None
    contract_id, pool, threshold, bumps, _, last_settled = contract
    # Force the threshold high so subsequent pledges don't settle.
    _force_threshold(cur, contract_id, 1_000_000)

    # Second pledge accumulates.
    cur.execute("SELECT public.contribute_to_supply_contract(%s, %s, %s, %s)",
                (trader, resource, 'sell', 2500))
    contract2 = _get_contract(cur, trader, resource, 'sell')
    assert contract2[1] == 3500, f'pool should be 3500, got {contract2[1]}'
    assert contract2[3] == 0, 'should not have settled (bumps_funded=0)'
    assert contract2[5] is None, 'last_settled_at should still be NULL'


def test_pledge_debits_player_and_writes_ledger(make_player, cur, as_user):
    p = make_player()
    _set_money(cur, p['id'], 100000)
    as_user(p['id'])
    trader, resource, _ = _existing_pair(cur)
    cur.execute("SELECT public.contribute_to_supply_contract(%s, %s, %s, %s)",
                (trader, resource, 'sell', 5000))
    cur.execute("SELECT money FROM public.player_profiles WHERE id = %s", (str(p['id']),))
    assert cur.fetchone()[0] == 95000
    cur.execute("""SELECT source, amount FROM public.cash_transactions
      WHERE player_id = %s AND source = 'supply_contract' ORDER BY created_at DESC LIMIT 1""",
      (str(p['id']),))
    src, amt = cur.fetchone()
    assert src == 'supply_contract'
    assert amt == -5000


# ── settle path ─────────────────────────────────────────────────────

def test_contribute_at_or_over_threshold_triggers_settle(make_player, cur, as_user):
    p = make_player()
    _set_money(cur, p['id'], 100000)
    as_user(p['id'])
    trader, resource, old_cap = _existing_pair(cur)

    # First pledge creates the contract; then force-tweak threshold to a
    # very small number so the next pledge settles.
    cur.execute("SELECT public.contribute_to_supply_contract(%s, %s, %s, %s)",
                (trader, resource, 'sell', 100))
    contract = _get_contract(cur, trader, resource, 'sell')
    contract_id = contract[0]
    _force_threshold(cur, contract_id, 200)   # just above current pool of 100

    cur.execute("SELECT public.contribute_to_supply_contract(%s, %s, %s, %s)",
                (trader, resource, 'sell', 100))
    contract2 = _get_contract(cur, trader, resource, 'sell')
    # After settle: pool reset, bumps_funded incremented, last_settled_at set.
    assert contract2[1] == 0, f'pool should reset to 0, got {contract2[1]}'
    assert contract2[3] == 1, f'bumps_funded should be 1, got {contract2[3]}'
    assert contract2[5] is not None, 'last_settled_at should be set after settle'

    cur.execute("SELECT daily_sell_cap FROM public.trader_prices WHERE trader_key = %s AND resource_key = %s AND is_active",
                (trader, resource))
    new_cap = cur.fetchone()[0]
    # Cap should have grown +25% with a floor of 100.
    expected_cap = max(100, round((old_cap or 0) * 1.25))
    assert new_cap == expected_cap, f'cap should be {expected_cap}, got {new_cap}'


def test_settle_emits_bell_log_notifications_to_contributors(make_player, cur, as_user):
    p1 = make_player()
    p2 = make_player()
    _set_money(cur, p1['id'], 100000)
    _set_money(cur, p2['id'], 100000)
    trader, resource, _ = _existing_pair(cur)

    # p1 pledges (creates contract).
    as_user(p1['id'])
    cur.execute("SELECT public.contribute_to_supply_contract(%s, %s, %s, %s)",
                (trader, resource, 'sell', 100))
    contract_id = _get_contract(cur, trader, resource, 'sell')[0]
    _force_threshold(cur, contract_id, 300)

    # p2 pledges + triggers settle.
    as_user(p2['id'])
    cur.execute("SELECT public.contribute_to_supply_contract(%s, %s, %s, %s)",
                (trader, resource, 'sell', 250))

    for pid in (p1['id'], p2['id']):
        cur.execute("""SELECT count(*) FROM public.player_notifications
          WHERE player_id = %s AND kind = 'supply_contract_bumped'""",
          (str(pid),))
        assert cur.fetchone()[0] >= 1, f'player {pid} did not get a supply_contract_bumped notification'


def test_settle_creates_trader_prices_row_for_new_resource(make_player, cur, as_user):
    """For (trader, resource) pairs that don't yet have a trader_prices
    row, the first bump unlocks the trade by inserting a row with
    default markup pricing. Atlas: 'no matter what that resource may
    be' — including ones the trader doesn't currently deal in."""
    p = make_player()
    _set_money(cur, p['id'], 100000)
    as_user(p['id'])

    # Find a (trader, resource) pair that does NOT have a trader_prices row.
    cur.execute("""SELECT t.key, r.key
      FROM public.traders t, public.resources r
      WHERE t.is_active AND r.is_active AND r.kind <> 'terrain'
        AND NOT EXISTS (
          SELECT 1 FROM public.trader_prices tp
          WHERE tp.trader_key = t.key AND tp.resource_key = r.key
        )
      LIMIT 1""")
    pair = cur.fetchone()
    if not pair:
        pytest.skip('no un-traded (trader, resource) pair available')
    trader, resource = pair

    cur.execute("SELECT public.contribute_to_supply_contract(%s, %s, %s, %s)",
                (trader, resource, 'sell', 100))
    contract_id = _get_contract(cur, trader, resource, 'sell')[0]
    _force_threshold(cur, contract_id, 200)

    cur.execute("SELECT public.contribute_to_supply_contract(%s, %s, %s, %s)",
                (trader, resource, 'sell', 100))

    cur.execute("""SELECT daily_sell_cap, buy_price, sell_price FROM public.trader_prices
      WHERE trader_key = %s AND resource_key = %s AND is_active""",
      (trader, resource))
    row = cur.fetchone()
    assert row is not None, 'settle should have created a trader_prices row'
    assert row[0] >= 100, f'new resource sell cap should be at floor 100, got {row[0]}'
    assert row[1] >= 1, 'buy_price should be set'
    assert row[2] >= 1, 'sell_price should be set'


# ── withdraw ────────────────────────────────────────────────────────

def test_withdraw_refunds_player_and_drops_pool(make_player, cur, as_user):
    p = make_player()
    _set_money(cur, p['id'], 100000)
    as_user(p['id'])
    trader, resource, _ = _existing_pair(cur)

    cur.execute("SELECT public.contribute_to_supply_contract(%s, %s, %s, %s)",
                (trader, resource, 'sell', 5000))
    contract_id = _get_contract(cur, trader, resource, 'sell')[0]
    _force_threshold(cur, contract_id, 1_000_000)
    cur.execute("SELECT public.contribute_to_supply_contract(%s, %s, %s, %s)",
                (trader, resource, 'sell', 2000))

    cur.execute("SELECT money FROM public.player_profiles WHERE id = %s", (str(p['id']),))
    money_after_pledges = cur.fetchone()[0]
    assert money_after_pledges == 93000

    cur.execute("SELECT public.withdraw_from_supply_contract(%s)", (contract_id,))
    cur.execute("SELECT money FROM public.player_profiles WHERE id = %s", (str(p['id']),))
    money_after_withdraw = cur.fetchone()[0]
    assert money_after_withdraw == 100000, f'should have full refund, got {money_after_withdraw}'

    contract = _get_contract(cur, trader, resource, 'sell')
    assert contract[1] == 0, f'pool should drop to 0 after withdraw, got {contract[1]}'


def test_withdraw_only_returns_own_pledges(make_player, cur, as_user):
    p1 = make_player()
    p2 = make_player()
    _set_money(cur, p1['id'], 50000)
    _set_money(cur, p2['id'], 50000)
    trader, resource, _ = _existing_pair(cur)

    as_user(p1['id'])
    cur.execute("SELECT public.contribute_to_supply_contract(%s, %s, %s, %s)",
                (trader, resource, 'sell', 3000))
    contract_id = _get_contract(cur, trader, resource, 'sell')[0]
    _force_threshold(cur, contract_id, 1_000_000)

    as_user(p2['id'])
    cur.execute("SELECT public.contribute_to_supply_contract(%s, %s, %s, %s)",
                (trader, resource, 'sell', 7000))
    cur.execute("SELECT public.withdraw_from_supply_contract(%s)", (contract_id,))

    # p2 got back $7000; p1's $3000 remains in pool.
    cur.execute("SELECT money FROM public.player_profiles WHERE id = %s", (str(p2['id']),))
    assert cur.fetchone()[0] == 50000

    cur.execute("SELECT pool_money FROM public.trader_supply_contracts WHERE id = %s", (contract_id,))
    assert cur.fetchone()[0] == 3000, 'p1 stake should still be in pool'


def test_withdraw_rejects_if_no_active_pledges(make_player, cur, as_user):
    p = make_player()
    _set_money(cur, p['id'], 50000)
    as_user(p['id'])
    trader, resource, _ = _existing_pair(cur)
    cur.execute("SELECT public.contribute_to_supply_contract(%s, %s, %s, %s)",
                (trader, resource, 'sell', 100))
    contract_id = _get_contract(cur, trader, resource, 'sell')[0]
    _force_threshold(cur, contract_id, 200)
    cur.execute("SELECT public.contribute_to_supply_contract(%s, %s, %s, %s)",
                (trader, resource, 'sell', 100))
    # contract just settled; previous pledges marked refunded=false but
    # round_at was rolled forward, so they're no longer in the current
    # round. Withdraw should reject.
    with pytest.raises(psycopg2.errors.RaiseException) as exc:
        cur.execute("SELECT public.withdraw_from_supply_contract(%s)", (contract_id,))
    assert 'no active pledges' in str(exc.value).lower()


# ── list view ───────────────────────────────────────────────────────

def test_list_supply_contracts_returns_my_pledge_and_contributors(make_player, cur, as_user):
    p1 = make_player()
    p2 = make_player()
    _set_money(cur, p1['id'], 50000)
    _set_money(cur, p2['id'], 50000)
    trader, resource, _ = _existing_pair(cur)

    as_user(p1['id'])
    cur.execute("SELECT public.contribute_to_supply_contract(%s, %s, %s, %s)",
                (trader, resource, 'sell', 2000))
    contract_id = _get_contract(cur, trader, resource, 'sell')[0]
    _force_threshold(cur, contract_id, 1_000_000)
    as_user(p2['id'])
    cur.execute("SELECT public.contribute_to_supply_contract(%s, %s, %s, %s)",
                (trader, resource, 'sell', 4500))

    # p2 listing should see contributors list with both names and own pledge = 4500.
    cur.execute("SELECT id, my_pledge, contributors FROM public.list_supply_contracts() WHERE id = %s",
                (contract_id,))
    row = cur.fetchone()
    assert row is not None
    cid, my_pledge, contributors = row
    assert my_pledge == 4500
    names = sorted(c['display_name'] for c in contributors)
    assert len(names) == 2, f'expected 2 contributors, got {names}'
