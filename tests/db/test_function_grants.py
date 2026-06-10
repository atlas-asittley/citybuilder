"""Regression guard for the 2026-05-29 cross-player exploit.

Internal tick helpers (_pp_* / compute_*) are SECURITY DEFINER and take a
client-controlled p_uid; they must NOT be directly EXECUTE-able by the
`authenticated` or `anon` roles, or a client could call e.g.
`_pp_update_power(victim_uuid)` to mutate another player's state. They're only
ever invoked internally by DEFINER orchestrators (which run as the owner), so
revoking client EXECUTE is safe. See security_hardening_2026_05_29.sql.
"""
import pytest


def _internal_helpers(cur, role):
    cur.execute("""
        SELECT p.proname, p.oid::regprocedure::text
        FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'public'
          AND (p.proname LIKE '\\_pp\\_%%' OR p.proname LIKE 'compute\\_%%')
          AND has_function_privilege(%s, p.oid, 'EXECUTE')
    """, (role,))
    return [r[1] for r in cur.fetchall()]


@pytest.mark.parametrize("role", ["authenticated", "anon"])
def test_internal_helpers_not_client_executable(cur, role):
    leaks = _internal_helpers(cur, role)
    assert leaks == [], (
        f"{len(leaks)} internal _pp_/compute_ helper(s) are EXECUTE-able by "
        f"'{role}' — cross-player exploit surface. Add a REVOKE: {leaks[:8]}"
    )


def test_legit_rpcs_still_client_executable(cur):
    """The revoke must not have caught the real client-facing RPCs."""
    for fn in ('process_production', 'place_building', 'demolish_building',
               'upgrade_road', 'upgrade_house', 'choose_industry'):
        cur.execute("""SELECT bool_or(has_function_privilege('authenticated', p.oid, 'EXECUTE'))
                       FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
                       WHERE n.nspname='public' AND p.proname=%s""", (fn,))
        assert cur.fetchone()[0] is True, f"{fn} must stay callable by authenticated"
