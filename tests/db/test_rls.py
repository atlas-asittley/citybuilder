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


def test_every_public_table_has_rls_enabled(cur):
    """Supabase's security advisor (rls_disabled_in_public) emailed a weekly
    'Action required' alert for months because trader_name_pool shipped in
    procedural_traders.sql without RLS, leaving anon full SIUD on it.
    Fixed 2026-07-28. This guards the whole schema, not just that table —
    a new migration that forgets ENABLE ROW LEVEL SECURITY fails here."""
    cur.execute("""
        SELECT c.relname
        FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = 'public'
          AND c.relkind = 'r'
          AND NOT c.relrowsecurity
        ORDER BY c.relname
    """)
    missing = [r[0] for r in cur.fetchall()]
    assert missing == [], \
        f"public tables without RLS (Supabase advisor will flag these): {missing}"


def test_trader_name_pool_not_client_readable(cur):
    """trader_name_pool is pure server-side flavour data. anon must not
    reach it directly; the only consumer is _pick_trader_name(), reached
    via SECURITY DEFINER _spawn_random_trader()."""
    for role in ('anon', 'authenticated'):
        cur.execute("SAVEPOINT rls_tnp")
        cur.execute(f"SET LOCAL ROLE {role}")
        try:
            cur.execute("SELECT count(*) FROM public.trader_name_pool")
            cur.execute("RESET ROLE")
            cur.execute("RELEASE SAVEPOINT rls_tnp")
            assert False, f"{role} can read trader_name_pool directly"
        except psycopg2.errors.InsufficientPrivilege:
            cur.execute("ROLLBACK TO SAVEPOINT rls_tnp")


def test_trader_spawn_still_works_after_name_pool_lockdown(cur):
    """Locking trader_name_pool must not break trader spawning: postgres
    owns the table and _spawn_random_trader is SECURITY DEFINER, so the
    definer path bypasses RLS. Regression guard for the 2026-07-28 fix."""
    cur.execute("SAVEPOINT spawn_tnp")
    cur.execute("SET LOCAL ROLE anon")
    try:
        cur.execute("SELECT public._spawn_random_trader('truck')")
        key = cur.fetchone()[0]
        assert key and key.startswith('proc_'), f"unexpected trader key: {key}"
    finally:
        cur.execute("RESET ROLE")
        cur.execute("ROLLBACK TO SAVEPOINT spawn_tnp")
