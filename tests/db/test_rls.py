"""Tests for Row Level Security policies.

Regression coverage:
- 2026-05-09 lockdown: direct INSERT/UPDATE/DELETE policies on
  player-scoped tables (buildings, player_profiles, inventories,
  trade_policies, trader_visits, trade_transactions) were dropped.
  All writes now go through SECURITY DEFINER RPCs. Verify the
  policies are gone AND direct writes are rejected.
- Cannot read other players' inventories.
"""
import pytest
import psycopg2


def test_no_direct_write_policies_on_buildings(cur):
    """RLS on buildings should allow only SELECT to client roles —
    every mutation goes through an RPC (place_building,
    demolish_building, set_building_paused, upgrade_house, etc)."""
    cur.execute("""
        SELECT polcmd FROM pg_policy
        WHERE polrelid = 'public.buildings'::regclass
          AND polcmd <> 'r'  -- 'r' = SELECT
    """)
    rows = cur.fetchall()
    assert rows == [], f"buildings has unexpected non-SELECT policies: {rows}"


def test_owner_cannot_directly_delete_building(make_player, place, cur, clear_resources):
    """Direct DELETE via PostgREST is locked out post-2026-05-09.
    Demolish must go through the demolish_building RPC."""
    p = make_player()
    clear_resources(p['id'])
    hx, hy = p['home_x'], p['home_y']
    result = place('road', hx + 1, hy + 1)
    bid = result['building_id']

    cur.execute("SET LOCAL ROLE authenticated")
    try:
        cur.execute("DELETE FROM public.buildings WHERE id = %s", (bid,))
        # RLS without a DELETE policy silently rejects (0 rows affected,
        # no error). Building should still be there.
    finally:
        cur.execute("RESET ROLE")
    cur.execute("SELECT COUNT(*) FROM public.buildings WHERE id = %s", (bid,))
    assert cur.fetchone()[0] == 1, \
        "Owner was able to bypass RPC and DELETE building directly via RLS"


def test_owner_can_demolish_via_rpc(make_player, place, cur, clear_resources):
    """The demolish_building RPC is the canonical demolish path.
    Refunds 50% of build_cost + writes a cash_transactions row."""
    p = make_player()
    clear_resources(p['id'])
    cur.execute("UPDATE public.player_profiles SET money = 10000 WHERE id = %s",
                (str(p['id']),))
    hx, hy = p['home_x'], p['home_y']
    place('road', hx + 1, hy + 1)
    bid = place('house', hx + 1, hy + 2)['building_id']

    cur.execute("SELECT public.demolish_building(%s)", (bid,))
    result = cur.fetchone()[0]
    assert result['refund'] >= 0
    cur.execute("SELECT COUNT(*) FROM public.buildings WHERE id = %s", (bid,))
    assert cur.fetchone()[0] == 0, "demolish_building should remove the row"


def test_cannot_demolish_other_players_building(make_player, place, as_user, cur, clear_resources):
    """demolish_building checks ownership. Cross-player call rejected."""
    pA = make_player()
    clear_resources(pA['id'])
    hx, hy = pA['home_x'], pA['home_y']
    result = place('road', hx + 1, hy + 1)
    bid = result['building_id']

    pB = make_player()
    as_user(pB['id'])

    cur.execute("SAVEPOINT s1")
    try:
        cur.execute("SELECT public.demolish_building(%s)", (bid,))
        cur.execute("RELEASE SAVEPOINT s1")
        assert False, "B was able to demolish A's building via RPC"
    except psycopg2.errors.RaiseException as e:
        cur.execute("ROLLBACK TO SAVEPOINT s1")
        assert 'not your building' in str(e).lower() or 'not authorized' in str(e).lower()


def test_inventory_select_is_self_only(make_player, as_user, cur):
    pA = make_player()
    pB = make_player()
    as_user(pB['id'])
    cur.execute("SET LOCAL ROLE authenticated")
    try:
        cur.execute("SELECT DISTINCT player_id FROM public.inventories")
        rows = cur.fetchall()
    finally:
        cur.execute("RESET ROLE")
    if rows:
        for (pid,) in rows:
            assert str(pid) == str(pB['id']), \
                f"B saw inventory row for {pid}; RLS isn't isolating"


def test_player_profiles_money_cannot_be_directly_set(make_player, cur):
    """Direct UPDATE on player_profiles.money was the triple-tap-cheat
    vector for any authenticated player — locked down 2026-05-09.
    The legitimate cheat path is now dev_grant_money RPC."""
    p = make_player()
    cur.execute("SELECT money FROM public.player_profiles WHERE id = %s", (str(p['id']),))
    starting = cur.fetchone()[0]

    cur.execute("SET LOCAL ROLE authenticated")
    cur.execute("SET LOCAL request.jwt.claims TO %s",
                ('{"sub": "' + str(p['id']) + '"}',))
    try:
        cur.execute("UPDATE public.player_profiles SET money = 99999999 WHERE id = %s",
                    (str(p['id']),))
    finally:
        cur.execute("RESET ROLE")
    cur.execute("SELECT money FROM public.player_profiles WHERE id = %s", (str(p['id']),))
    after = cur.fetchone()[0]
    assert after == starting, \
        f"Authenticated player altered money via direct UPDATE (was ${starting}, now ${after})"
