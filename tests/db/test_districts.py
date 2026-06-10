"""Tests for district allocation: row-based starters + player-picked expansion.

Layout rules under test:
  * Each player reserves one row at signup; starter chunk is at (0, row).
  * Expansion candidates = orthogonally-adjacent unowned chunks, excluding
    other players' reserved rows.
  * expand_district takes the chosen chunk and validates it's a candidate.

We don't wipe the live DB's existing data — savepoint isolates each test,
and the FK from buildings → map_tiles prevents wholesale tile delete. Tests
verify allocator BEHAVIOR: each new player gets a fresh chunk that doesn't
overlap with any existing one, and expansions land where the player picks.
"""
import pytest
import psycopg2


def _expand_pick_first(cur):
    """Helper: fetch the first expansion candidate for the auth'd player and
    call expand_district on it. Returns the RPC's JSON result."""
    cur.execute("SELECT chunk_x, chunk_y FROM public.expansion_candidates(auth.uid()) LIMIT 1")
    row = cur.fetchone()
    assert row is not None, "no expansion candidates available"
    cx, cy = row
    cur.execute("SELECT public.expand_district(%s, %s)", (cx, cy))
    return cur.fetchone()[0]


def test_new_player_gets_unique_chunk(make_player, cur):
    """Each new player's chunk shouldn't collide with any existing one."""
    cur.execute("SELECT chunk_x, chunk_y FROM public.district_chunks")
    existing = set((r[0], r[1]) for r in cur.fetchall())

    p = make_player()
    cur.execute(
        "SELECT chunk_x, chunk_y FROM public.district_chunks WHERE owner_player_id = %s",
        (str(p['id']),)
    )
    new_chunks = set((r[0], r[1]) for r in cur.fetchall())

    assert len(new_chunks) == 1, "first chunk should be exactly one slot"
    assert new_chunks.isdisjoint(existing), "new chunk overlaps with existing"


def test_two_new_players_get_different_chunks(make_player, cur):
    """Sequential signups never collide. With row-based starters, each
    new player goes to the next free row going down."""
    p1 = make_player()
    p2 = make_player()

    cur.execute(
        "SELECT chunk_x, chunk_y FROM public.district_chunks WHERE owner_player_id = %s",
        (str(p1['id']),)
    )
    c1 = set((r[0], r[1]) for r in cur.fetchall())
    cur.execute(
        "SELECT chunk_x, chunk_y FROM public.district_chunks WHERE owner_player_id = %s",
        (str(p2['id']),)
    )
    c2 = set((r[0], r[1]) for r in cur.fetchall())

    assert c1.isdisjoint(c2), "two players were given the same chunk"


def test_new_player_starter_at_column_zero(make_player, cur):
    """Starters always land at chunk_x = 0 in their reserved row."""
    p = make_player()
    cur.execute(
        "SELECT chunk_x FROM public.district_chunks WHERE owner_player_id = %s",
        (str(p['id']),)
    )
    cx = cur.fetchone()[0]
    assert cx == 0, f"starter should be at column 0, got {cx}"


def test_new_player_reserves_a_row(make_player, cur):
    """Each player has a reserved_row set after signup."""
    p = make_player()
    cur.execute("SELECT reserved_row FROM public.player_profiles WHERE id = %s", (str(p['id']),))
    row = cur.fetchone()[0]
    assert row is not None, "reserved_row should be set"


def test_two_new_players_get_different_reserved_rows(make_player, cur):
    p1 = make_player()
    p2 = make_player()
    cur.execute("SELECT reserved_row FROM public.player_profiles WHERE id IN (%s, %s)",
                (str(p1['id']), str(p2['id'])))
    rows = [r[0] for r in cur.fetchall()]
    assert rows[0] != rows[1], "two players should reserve distinct rows"


def test_expansion_candidates_includes_own_row_edges(make_player, cur, as_user):
    """A player can always expand left or right within their reserved row,
    so the candidate set is never empty."""
    p = make_player()
    as_user(p['id'])
    cur.execute("SELECT chunk_x, chunk_y FROM public.expansion_candidates(%s)", (str(p['id']),))
    cands = [(r[0], r[1]) for r in cur.fetchall()]
    row = next(r[1] for r in cands if r[1] is not None) if cands else None
    # Starter is at (0, row). Both (1, row) and (-1, row) should be candidates.
    cur.execute("SELECT reserved_row FROM public.player_profiles WHERE id = %s", (str(p['id']),))
    pr = cur.fetchone()[0]
    assert (1, pr) in cands, f"missing right-edge candidate: cands={cands}"
    assert (-1, pr) in cands, f"missing left-edge candidate: cands={cands}"


def test_expansion_candidates_ignore_reserved_row(make_player, cur, as_user):
    """Pre-2026-05-21 each player was locked to their reserved row by
    a filter that excluded chunks on other players' rows. Now
    candidates only filter on actual ownership — a player can expand
    in any of the four cardinal directions as long as the target chunk
    is unclaimed."""
    p = make_player()
    # Give p a second chunk in a fresh, isolated region of the world
    # so we have a clean 4-neighbor pattern to verify against (other
    # historical / parallel test players might already own (0, row±1)).
    SEED_X, SEED_Y = 999, 999
    cur.execute("""INSERT INTO public.district_chunks (chunk_x, chunk_y, owner_player_id)
                   VALUES (%s, %s, %s)""", (SEED_X, SEED_Y, str(p['id'])))
    as_user(p['id'])
    cur.execute("SELECT chunk_x, chunk_y FROM public.expansion_candidates(%s)", (str(p['id']),))
    cands = set((r[0], r[1]) for r in cur.fetchall())
    # All four orthogonal neighbors should appear, including the ones
    # on different rows than p's reserved_row. Before the migration the
    # vertical pair (above/below) would be filtered.
    assert (SEED_X + 1, SEED_Y) in cands
    assert (SEED_X - 1, SEED_Y) in cands
    assert (SEED_X, SEED_Y + 1) in cands, "vertical candidate (above) missing — reserved_row filter still in play?"
    assert (SEED_X, SEED_Y - 1) in cands, "vertical candidate (below) missing — reserved_row filter still in play?"


def test_expand_district_refuses_to_box_a_player_in(make_player, cur, as_user):
    """Reachability invariant: a claim that would leave another player
    with zero expansion candidates is rejected. Constructs a tight
    scenario in a remote part of the world (chunk coords ~1000) so the
    surrounding chunks are guaranteed to be unclaimed."""
    p1 = make_player()
    p2 = make_player()
    cur.execute("UPDATE public.player_profiles SET money = 10000000 WHERE id IN (%s, %s)",
                (str(p1['id']), str(p2['id'])))

    # Work in a far-off region of the world so no existing test or live
    # state collides with the chunks we're seeding.
    VICTIM_X, VICTIM_Y = 1000, 1000
    # Move p2's "owned" chunk count by giving them a single chunk at
    # (VICTIM_X, VICTIM_Y). The starter at (0, p2_row) still exists but
    # is far away — the reachability check evaluates p2's candidates
    # across ALL their owned chunks, but the (0, p2_row) cluster has
    # plenty of room so it's not the binding constraint. To make the
    # test deterministic, we instead REPLACE p2's chunks: delete the
    # starter, give them only the victim chunk.
    cur.execute("DELETE FROM public.district_chunks WHERE owner_player_id = %s", (str(p2['id']),))
    cur.execute("""INSERT INTO public.district_chunks (chunk_x, chunk_y, owner_player_id)
                   VALUES (%s, %s, %s)""", (VICTIM_X, VICTIM_Y, str(p2['id'])))

    # Now surround the victim chunk on three sides + give p1 a path-in
    # to the fourth side. p2's only candidate becomes (VICTIM_X-1, VICTIM_Y).
    for (cx, cy) in [
        (VICTIM_X + 1, VICTIM_Y),        # east
        (VICTIM_X,     VICTIM_Y + 1),    # north
        (VICTIM_X,     VICTIM_Y - 1),    # south
        (VICTIM_X - 1, VICTIM_Y + 1),    # NW — gives p1 access to (-1, victim_y)
    ]:
        cur.execute("""INSERT INTO public.district_chunks (chunk_x, chunk_y, owner_player_id)
                       VALUES (%s, %s, %s)""", (cx, cy, str(p1['id'])))

    cur.execute("SELECT COUNT(*) FROM public.expansion_candidates(%s)", (str(p2['id']),))
    assert cur.fetchone()[0] == 1, "setup: p2 should have exactly 1 candidate"

    as_user(p1['id'])
    # Claiming (VICTIM_X-1, VICTIM_Y) would leave p2 with 0 candidates → reject.
    with pytest.raises(psycopg2.errors.RaiseException) as exc:
        cur.execute("SELECT public.expand_district(%s, %s)", (VICTIM_X - 1, VICTIM_Y))
    msg = str(exc.value).lower()
    assert 'surround' in msg or 'box' in msg, f"expected boxing-in rejection, got: {exc.value}"


def test_expand_district_refuses_dead_end_boxing(make_player, cur, as_user):
    """Extended reachability: a claim that leaves another player with exactly
    one candidate is also rejected when that surviving candidate is itself a
    dead-end (taking it would leave zero candidates).

    Scenario mirrors the Drew/Max incident on 2026-05-28.

    Layout (chunk coords, all near 1200,1200):

         p1  p1  p1
         p1 [W] VIC  p1
         p1  p1  p1
       p1 <-- anchor

    p2 owns VIC (1200,1200).
    p1 owns the six surrounding tiles blocking VIC except VICTIM_W (1199,1200).
    p1 also owns an anchor at (1197,1200) adjacent to the unclaimed VICTIM_WW (1198,1200).
    VICTIM_W's only unclaimed neighbor is VICTIM_WW — so if p1 claims VICTIM_WW,
    VICTIM_W becomes a dead-end and the claim must be rejected.
    """
    p1 = make_player()
    p2 = make_player()
    cur.execute("UPDATE public.player_profiles SET money = 10000000 WHERE id IN (%s, %s)",
                (str(p1['id']), str(p2['id'])))

    # Remote region to avoid collisions with live data.
    VIC_X, VIC_Y = 1200, 1200
    W_X = VIC_X - 1   # 1199 — VICTIM_W (p2's only remaining candidate)
    WW_X = VIC_X - 2  # 1198 — VICTIM_WW (unclaimed; p1 will try to claim this)

    cur.execute("DELETE FROM public.district_chunks WHERE owner_player_id = %s", (str(p2['id']),))
    cur.execute("""INSERT INTO public.district_chunks (chunk_x, chunk_y, owner_player_id)
                   VALUES (%s, %s, %s)""", (VIC_X, VIC_Y, str(p2['id'])))

    # p1 surrounds VIC on E/N/S and surrounds W on N/S.
    # p1 anchor is at (WW_X-1, VIC_Y) so p1 can expand to VICTIM_WW.
    # VICTIM_W and VICTIM_WW stay unclaimed.
    for (cx, cy) in [
        (VIC_X + 1, VIC_Y),      # east of VIC
        (VIC_X,     VIC_Y + 1),  # north of VIC
        (VIC_X,     VIC_Y - 1),  # south of VIC
        (W_X,       VIC_Y + 1),  # north of W — blocks W's escape up
        (W_X,       VIC_Y - 1),  # south of W — blocks W's escape down
        (WW_X - 1,  VIC_Y),      # p1 anchor west of WW — gives p1 access to WW
    ]:
        cur.execute("""INSERT INTO public.district_chunks (chunk_x, chunk_y, owner_player_id)
                       VALUES (%s, %s, %s)""", (cx, cy, str(p1['id'])))

    # Verify p2 has exactly 1 candidate (W).
    cur.execute("SELECT COUNT(*) FROM public.expansion_candidates(%s)", (str(p2['id']),))
    assert cur.fetchone()[0] == 1, "setup: p2 should have exactly 1 candidate (W)"

    # Verify W's only unclaimed neighbor is WW (east=VIC owned, N/S owned by p1, west=WW unclaimed).
    cur.execute("""
        SELECT COUNT(*) FROM (
            SELECT %s+1 AS nx, %s AS ny UNION ALL
            SELECT %s-1,       %s       UNION ALL
            SELECT %s,         %s+1     UNION ALL
            SELECT %s,         %s-1
        ) n
        WHERE NOT EXISTS (
            SELECT 1 FROM public.district_chunks dc WHERE dc.chunk_x = n.nx AND dc.chunk_y = n.ny
        )
    """, (W_X, VIC_Y, W_X, VIC_Y, W_X, VIC_Y, W_X, VIC_Y))
    unclaimed_w_neighbors = cur.fetchone()[0]
    assert unclaimed_w_neighbors == 1, \
        f"setup: W should have exactly 1 unclaimed neighbor (WW), got {unclaimed_w_neighbors}"

    as_user(p1['id'])
    # p1 tries to claim WW. After this, p2 still has 1 candidate (W), but W is a dead-end.
    with pytest.raises(psycopg2.errors.RaiseException) as exc:
        cur.execute("SELECT public.expand_district(%s, %s)", (WW_X, VIC_Y))
    msg = str(exc.value).lower()
    assert 'surround' in msg or 'box' in msg or 'dead' in msg, \
        f"expected dead-end boxing rejection, got: {exc.value}"


def test_expand_district_allows_claim_when_target_player_has_other_options(make_player, cur, as_user):
    """Inverse of the boxing-in test: when the target player still has
    other escape routes, the claim succeeds."""
    p1 = make_player()
    p2 = make_player()
    cur.execute("UPDATE public.player_profiles SET money = 10000000 WHERE id IN (%s, %s)",
                (str(p1['id']), str(p2['id'])))

    VICTIM_X, VICTIM_Y = 1100, 1100
    cur.execute("DELETE FROM public.district_chunks WHERE owner_player_id = %s", (str(p2['id']),))
    cur.execute("""INSERT INTO public.district_chunks (chunk_x, chunk_y, owner_player_id)
                   VALUES (%s, %s, %s)""", (VICTIM_X, VICTIM_Y, str(p2['id'])))
    # p1 owns only the chunk north of victim — three escape routes remain.
    cur.execute("""INSERT INTO public.district_chunks (chunk_x, chunk_y, owner_player_id)
                   VALUES (%s, %s, %s)""", (VICTIM_X, VICTIM_Y + 1, str(p1['id'])))
    as_user(p1['id'])
    cur.execute("SELECT public.expand_district(%s, %s)", (VICTIM_X + 1, VICTIM_Y + 1))
    result = cur.fetchone()[0]
    assert result is not None
    # p2 must still have ≥ 2 candidates (E, W, S minus any p1 ate).
    cur.execute("SELECT COUNT(*) FROM public.expansion_candidates(%s)", (str(p2['id']),))
    assert cur.fetchone()[0] >= 2


def test_expand_district_costs_money(make_player, cur, as_user):
    p = make_player()
    cur.execute(
        "UPDATE public.player_profiles SET money = 10000 WHERE id = %s",
        (str(p['id']),),
    )
    as_user(p['id'])
    result = _expand_pick_first(cur)
    assert result['cost'] >= 500
    assert result['chunks_owned'] == 2
    cur.execute("SELECT money FROM public.player_profiles WHERE id = %s", (str(p['id']),))
    assert cur.fetchone()[0] == 10000 - result['cost']


def test_expand_district_cost_grows_quadratically(make_player, cur, as_user):
    p = make_player()
    cur.execute(
        "UPDATE public.player_profiles SET money = 1000000 WHERE id = %s",
        (str(p['id']),),
    )
    as_user(p['id'])
    costs = []
    for _ in range(3):
        result = _expand_pick_first(cur)
        costs.append(result['cost'])
    assert costs[1] > costs[0]
    assert costs[2] > costs[1]
    assert (costs[2] - costs[1]) > (costs[1] - costs[0])


def test_expand_fails_when_too_poor(make_player, cur, as_user):
    p = make_player()
    cur.execute(
        "UPDATE public.player_profiles SET money = 0 WHERE id = %s",
        (str(p['id']),),
    )
    as_user(p['id'])
    cur.execute("SELECT chunk_x, chunk_y FROM public.expansion_candidates(%s) LIMIT 1", (str(p['id']),))
    cx, cy = cur.fetchone()
    with pytest.raises(psycopg2.errors.RaiseException):
        cur.execute("SELECT public.expand_district(%s, %s)", (cx, cy))


def test_expand_rejects_non_candidate_chunk(make_player, cur, as_user):
    """Trying to claim a chunk that isn't an adjacent candidate must fail."""
    p = make_player()
    cur.execute(
        "UPDATE public.player_profiles SET money = 1000000 WHERE id = %s",
        (str(p['id']),),
    )
    as_user(p['id'])
    # A chunk far from the player's district is not a valid candidate.
    with pytest.raises(psycopg2.errors.RaiseException):
        cur.execute("SELECT public.expand_district(%s, %s)", (50, 50))


def test_resources_are_clustered_in_new_chunks(make_player, cur, as_user):
    """New chunks seed resources in blob/forest shapes via random walk, so
    most resource tiles should have at least one resource neighbor. A
    uniform 8% sprinkle would put that fraction near 28%; clustering
    pushes it well above 50%."""
    p = make_player()
    cur.execute(
        "UPDATE public.player_profiles SET money = 1000000 WHERE id = %s",
        (str(p['id']),),
    )
    as_user(p['id'])
    for _ in range(3):
        _expand_pick_first(cur)

    cur.execute("""
        WITH res AS (
          SELECT x, y FROM public.map_tiles
          WHERE owner_player_id = %s AND resource_node_key IS NOT NULL
        )
        SELECT
          (SELECT count(*) FROM res) AS total,
          (SELECT count(*) FROM res a
            WHERE EXISTS (
              SELECT 1 FROM res b
              WHERE (b.x = a.x+1 AND b.y = a.y)
                 OR (b.x = a.x-1 AND b.y = a.y)
                 OR (b.x = a.x   AND b.y = a.y+1)
                 OR (b.x = a.x   AND b.y = a.y-1)
            )) AS with_neighbor
    """, (str(p['id']),))
    total, with_neighbor = cur.fetchone()
    # Post-scarcity-pass: starter chunk has 2 industry + 1 food cluster,
    # subsequent chunks have 1 + 1. Across 4 chunks the typical sample
    # is in the high teens to mid-20s — enough for the cluster ratio
    # below to be meaningful.
    assert total >= 15, f"too few resources sampled: {total}"
    pct = with_neighbor / total
    assert pct > 0.5, f"resources don't look clustered: only {pct:.0%} have a neighbor"


def test_expansion_chunk_is_owned_by_player(make_player, cur, as_user):
    p = make_player()
    cur.execute(
        "UPDATE public.player_profiles SET money = 10000 WHERE id = %s",
        (str(p['id']),),
    )
    as_user(p['id'])
    result = _expand_pick_first(cur)
    cx, cy = result['chunk_x'], result['chunk_y']

    cur.execute(
        "SELECT owner_player_id FROM public.district_chunks WHERE chunk_x = %s AND chunk_y = %s",
        (cx, cy)
    )
    assert str(cur.fetchone()[0]) == str(p['id'])

    # Tiles in that chunk should also be owned by the player
    cur.execute("""
        SELECT COUNT(*) FROM public.map_tiles
        WHERE owner_player_id = %s
          AND x BETWEEN %s AND %s
          AND y BETWEEN %s AND %s
    """, (str(p['id']), cx * 15, cx * 15 + 14, cy * 15, cy * 15 + 14))
    assert cur.fetchone()[0] == 225, "expansion chunk should have 225 owned tiles"
