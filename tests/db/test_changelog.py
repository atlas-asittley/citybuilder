"""Tests for the player-facing changelog system.

Covers the three RPCs (get_unseen_changelog_entries, list_changelog_entries,
mark_changelog_seen) plus the watermark behavior on player_profiles.
"""
import json
import uuid
import pytest


def _wipe_changelog(cur):
    """Clear any pre-seeded changelog rows (e.g. the production seed
    from the migration) so each test starts from a clean slate. The
    savepoint fixture rolls this back at end of test."""
    cur.execute("DELETE FROM public.changelog_entries")


def _seed_entry(cur, slug, title, body, published_at=None):
    """Insert a changelog entry. Returns its id."""
    if published_at is None:
        cur.execute(
            "INSERT INTO public.changelog_entries (slug, title, body) "
            "VALUES (%s, %s, %s) RETURNING id",
            (slug, title, body),
        )
    else:
        cur.execute(
            "INSERT INTO public.changelog_entries (slug, title, body, published_at) "
            "VALUES (%s, %s, %s, %s) RETURNING id",
            (slug, title, body, published_at),
        )
    return cur.fetchone()[0]


def test_auth_required(cur):
    """All three RPCs require an authenticated user."""
    for rpc in ('get_unseen_changelog_entries()',
                'list_changelog_entries()',
                'mark_changelog_seen()'):
        cur.execute("SAVEPOINT _auth_check")
        cur.execute("SELECT set_config('request.jwt.claims', '', true)")
        with pytest.raises(Exception) as exc:
            cur.execute(f"SELECT public.{rpc}")
        assert 'auth required' in str(exc.value), f"{rpc} should have rejected unauth"
        cur.execute("ROLLBACK TO SAVEPOINT _auth_check")


def test_first_time_player_sees_only_most_recent(cur, make_player):
    """A new player (NULL watermark) gets just the most recent entry,
    not the entire history."""
    p = make_player()
    _wipe_changelog(cur)
    # Seed three entries at distinct times.
    _seed_entry(cur, 'e1', 'First', 'oldest', '2026-01-01 00:00:00+00')
    _seed_entry(cur, 'e2', 'Second', 'middle', '2026-02-01 00:00:00+00')
    _seed_entry(cur, 'e3', 'Third', 'newest', '2026-03-01 00:00:00+00')

    # Watermark starts NULL by default; clear any tutorial setup leftover.
    cur.execute(
        "UPDATE public.player_profiles SET last_changelog_seen_at = NULL WHERE id = %s",
        (str(p['id']),),
    )

    cur.execute("SELECT slug FROM public.get_unseen_changelog_entries()")
    rows = cur.fetchall()
    slugs = [r[0] for r in rows]
    assert slugs == ['e3'], f"new player should see only most recent; got {slugs}"


def test_returning_player_sees_everything_since_watermark(cur, make_player):
    """A player with a watermark sees all entries published after it,
    newest first."""
    p = make_player()
    _wipe_changelog(cur)
    cur.execute(
        "UPDATE public.player_profiles SET last_changelog_seen_at = %s WHERE id = %s",
        ('2026-02-15 00:00:00+00', str(p['id'])),
    )
    _seed_entry(cur, 'old1', 'Old1', 'old', '2026-01-01 00:00:00+00')
    _seed_entry(cur, 'old2', 'Old2', 'old', '2026-02-01 00:00:00+00')
    _seed_entry(cur, 'new1', 'New1', 'new', '2026-03-01 00:00:00+00')
    _seed_entry(cur, 'new2', 'New2', 'new', '2026-04-01 00:00:00+00')

    cur.execute("SELECT slug FROM public.get_unseen_changelog_entries()")
    slugs = [r[0] for r in cur.fetchall()]
    # Only entries newer than 2026-02-15, newest first.
    assert slugs == ['new2', 'new1'], f"returning player saw {slugs}"


def test_mark_seen_clears_unseen(cur, make_player):
    """After mark_changelog_seen, get_unseen returns nothing."""
    p = make_player()
    _wipe_changelog(cur)
    cur.execute(
        "UPDATE public.player_profiles SET last_changelog_seen_at = %s WHERE id = %s",
        ('2026-01-01 00:00:00+00', str(p['id'])),
    )
    _seed_entry(cur, 'unseen', 'Unseen', 'body', '2026-04-01 00:00:00+00')

    cur.execute("SELECT count(*) FROM public.get_unseen_changelog_entries()")
    assert cur.fetchone()[0] == 1, "should have one unseen before marking"

    cur.execute("SELECT public.mark_changelog_seen()")
    cur.execute("SELECT count(*) FROM public.get_unseen_changelog_entries()")
    assert cur.fetchone()[0] == 0, "should have zero unseen after marking"

    # And the watermark on the profile actually moved to ~now.
    cur.execute(
        "SELECT last_changelog_seen_at FROM public.player_profiles WHERE id = %s",
        (str(p['id']),),
    )
    seen = cur.fetchone()[0]
    assert seen is not None
    cur.execute("SELECT now() - %s < interval '1 minute'", (seen,))
    assert cur.fetchone()[0], "watermark should be ~now()"


def test_player_isolation(cur, make_player, as_user):
    """One player's mark_seen doesn't affect another player's unseen list."""
    p1 = make_player()
    p2 = make_player()
    _wipe_changelog(cur)
    _seed_entry(cur, 'shared', 'Shared', 'body', '2026-04-01 00:00:00+00')

    # Both players start with NULL watermark.
    cur.execute(
        "UPDATE public.player_profiles SET last_changelog_seen_at = NULL "
        "WHERE id IN (%s, %s)",
        (str(p1['id']), str(p2['id'])),
    )

    # p1 marks seen.
    as_user(p1['id'])
    cur.execute("SELECT public.mark_changelog_seen()")

    # p1 has nothing unseen now.
    cur.execute("SELECT count(*) FROM public.get_unseen_changelog_entries()")
    assert cur.fetchone()[0] == 0, "p1 should be caught up"

    # p2 still sees the entry.
    as_user(p2['id'])
    cur.execute("SELECT count(*) FROM public.get_unseen_changelog_entries()")
    assert cur.fetchone()[0] == 1, "p2's view should be untouched by p1's mark"


def test_list_changelog_returns_history_regardless_of_watermark(cur, make_player):
    """list_changelog_entries always returns history (for the Settings
    'What's new' viewer), independent of the seen watermark."""
    p = make_player()
    _wipe_changelog(cur)
    _seed_entry(cur, 'h1', 'H1', 'body', '2026-01-01 00:00:00+00')
    _seed_entry(cur, 'h2', 'H2', 'body', '2026-02-01 00:00:00+00')
    _seed_entry(cur, 'h3', 'H3', 'body', '2026-03-01 00:00:00+00')

    # Mark everything seen.
    cur.execute("SELECT public.mark_changelog_seen()")

    # get_unseen should be empty…
    cur.execute("SELECT count(*) FROM public.get_unseen_changelog_entries()")
    assert cur.fetchone()[0] == 0

    # …but list_changelog_entries should still return all three (newest first).
    cur.execute("SELECT slug FROM public.list_changelog_entries()")
    slugs = [r[0] for r in cur.fetchall()]
    assert slugs[:3] == ['h3', 'h2', 'h1'], f"history view returned {slugs[:3]}"


def test_list_changelog_respects_limit(cur, make_player):
    """p_limit caps the result count and clamps to [1, 100]."""
    make_player()
    _wipe_changelog(cur)
    for i in range(5):
        _seed_entry(cur, f'lim{i}', f'L{i}', 'b', f'2026-0{i+1}-01 00:00:00+00')

    cur.execute("SELECT count(*) FROM public.list_changelog_entries(2)")
    assert cur.fetchone()[0] == 2

    # Negative / zero clamps up to 1.
    cur.execute("SELECT count(*) FROM public.list_changelog_entries(0)")
    assert cur.fetchone()[0] == 1
