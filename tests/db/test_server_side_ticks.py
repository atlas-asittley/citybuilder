"""Tests for the server-side tick architecture (2026-05-11).

Atlas: "let's go with option 2" — replace client-poll-driven ticks
with a pg_cron-scheduled job that ticks every player every minute,
online or offline.

Architecture:
  - _pp_for_uid(p_uid) — private helper, runs the full tick. Not
    callable by authenticated/anon roles.
  - process_production() — public RPC, wraps _pp_for_uid(auth.uid()).
  - _pp_tick_all_players() — cron worker, iterates active players.

Tests:
  - _pp_for_uid is locked down (authenticated role can't call it
    with another player's id).
  - process_production still works for the calling player.
  - _pp_tick_all_players ticks each post-tutorial player exactly
    once.
  - One player erroring doesn't halt the worker (it swallows
    EXCEPTION WHEN OTHERS).
"""


def test_pp_for_uid_not_callable_by_authenticated(cur, make_player):
    """A regular authenticated user MUST NOT be able to call
    _pp_for_uid(other_player_id) — that would let them tick anyone
    else's city and read the full state JSON. Helper is REVOKEd
    from the authenticated and anon roles."""
    p1 = make_player()
    p2 = make_player()

    # Switch to a SET ROLE authenticated context so the privilege
    # check actually fires. Default postgres role bypasses privs.
    cur.execute("SAVEPOINT _role")
    cur.execute("SET LOCAL ROLE authenticated")
    try:
        try:
            cur.execute("SELECT public._pp_for_uid(%s)", (str(p2['id']),))
            failed = False
        except Exception as e:
            failed = True
            err = str(e)
        assert failed, "_pp_for_uid should be REVOKE'd from authenticated"
        assert 'permission denied' in err.lower() or 'no permission' in err.lower(), (
            f"expected permission-denied error, got: {err}"
        )
    finally:
        cur.execute("ROLLBACK TO SAVEPOINT _role")


def test_process_production_still_works_for_caller(cur, make_player):
    """The 0-arg public RPC still ticks the calling player via
    auth.uid()."""
    p = make_player()
    cur.execute("SELECT public.process_production()")
    result = cur.fetchone()[0]
    assert result is not None
    assert 'population' in result
    assert 'money' in result


def test_tick_all_players_ticks_each_post_tutorial(cur, make_player):
    """_pp_tick_all_players returns the count of players ticked.
    Should match the number of post-tutorial players."""
    p1 = make_player()
    p2 = make_player()
    p3 = make_player()  # all 3 default to tutorial_step=4 in make_player

    # Also create a tutorial player (step < 4) — it should be skipped.
    p4 = make_player(tutorial_done=False)
    cur.execute("UPDATE public.player_profiles SET tutorial_step = 0 WHERE id = %s",
                (str(p4['id']),))

    # Count post-tutorial players before the call.
    cur.execute("SELECT count(*) FROM public.player_profiles WHERE tutorial_step >= 4")
    expected = cur.fetchone()[0]

    cur.execute("SELECT public._pp_tick_all_players()")
    ticked = cur.fetchone()[0]
    assert ticked == expected, (
        f"expected {expected} players ticked, got {ticked}"
    )


def test_tick_all_players_continues_past_individual_errors(cur, make_player):
    """If one player's tick errors (e.g., bad data, corrupted state),
    the worker should swallow it and continue with the rest. We don't
    have an easy way to FORCE a per-player error from inside a test
    without altering the function, so this test asserts the wrapper
    is shaped to handle errors — verified by the EXCEPTION WHEN OTHERS
    block in its body via pg_get_functiondef inspection."""
    cur.execute("""
      SELECT pg_get_functiondef(oid)
      FROM pg_proc WHERE proname = '_pp_tick_all_players'
    """)
    src = cur.fetchone()[0]
    assert 'EXCEPTION WHEN OTHERS' in src, (
        '_pp_tick_all_players must have EXCEPTION WHEN OTHERS so one '
        'player errors does not halt the world. body:\n' + src
    )
    assert 'RAISE WARNING' in src, (
        'errored ticks should RAISE WARNING into pg_cron job_run_details'
    )


def test_cron_job_is_scheduled(cur):
    """The cron job 'tick-all-players' should be scheduled to run
    every minute."""
    cur.execute("SELECT schedule FROM cron.job WHERE jobname = 'tick-all-players'")
    row = cur.fetchone()
    assert row is not None, "tick-all-players cron job not scheduled"
    assert row[0] == '* * * * *', f"expected every-minute schedule, got {row[0]}"
