"""RPC cross-player authorization guards.

Audit on 2026-05-09 found four RPCs that accepted p_player_id
without checking it matches auth.uid(): reset_player,
allocate_district_chunk, place_pre_road, recompute_extractor_paths.
The reset_player one was a complete account-takeover vector (any
authenticated player could wipe any other). All four now raise
'not authorized' when the caller's uid doesn't match the parameter.
"""
import psycopg2
import pytest


def _act_as(cur, player_id):
    cur.execute("SELECT set_config('request.jwt.claims', %s, true)",
                ('{"sub": "' + str(player_id) + '"}',))


def _try(cur, sql, *args):
    """Run a possibly-raising query inside a savepoint and return
    the error message if it raised, else None."""
    cur.execute("SAVEPOINT s")
    try:
        cur.execute(sql, args)
        cur.execute("RELEASE SAVEPOINT s")
        return None
    except psycopg2.errors.RaiseException as e:
        cur.execute("ROLLBACK TO SAVEPOINT s")
        return str(e)


def test_reset_player_blocks_cross_player(make_player, cur):
    """Drew calling reset_player(jill.id) must raise."""
    a = make_player(industry='timber')
    b = make_player(industry='stone')
    _act_as(cur, a['id'])
    err = _try(cur, "SELECT public.reset_player(%s)", str(b['id']))
    assert err is not None, 'reset_player allowed cross-player call'
    assert 'not authorized' in err.lower()


def test_reset_player_allows_self(make_player, cur):
    """Drew calling reset_player(drew.id) must succeed (and indeed
    nuke his own record)."""
    a = make_player(industry='timber')
    _act_as(cur, a['id'])
    cur.execute("SELECT public.reset_player(%s)", (str(a['id']),))
    cur.execute("SELECT count(*) FROM public.player_profiles WHERE id = %s",
                (str(a['id']),))
    assert cur.fetchone()[0] == 0


def test_allocate_district_chunk_blocks_cross_player(make_player, cur):
    a = make_player(industry='timber')
    b = make_player(industry='stone')
    _act_as(cur, a['id'])
    err = _try(cur, "SELECT public.allocate_district_chunk(%s, 99, 99)", str(b['id']))
    assert err is not None
    assert 'not authorized' in err.lower()


def test_place_pre_road_blocks_cross_player(make_player, cur):
    a = make_player(industry='timber')
    b = make_player(industry='stone')
    _act_as(cur, a['id'])
    err = _try(cur, "SELECT public.place_pre_road(%s, 0, 0)", str(b['id']))
    assert err is not None
    assert 'not authorized' in err.lower()


def test_recompute_extractor_paths_blocks_cross_player(make_player, cur):
    a = make_player(industry='timber')
    b = make_player(industry='stone')
    _act_as(cur, a['id'])
    err = _try(cur, "SELECT public.recompute_extractor_paths(%s)", str(b['id']))
    assert err is not None
    assert 'not authorized' in err.lower()
