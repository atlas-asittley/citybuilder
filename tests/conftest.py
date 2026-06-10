"""Shared pytest fixtures for the City Builder test suite.

Tests run against the live Supabase database read via ~/.citybuilder_db_url.
Each test gets a savepoint + automatic ROLLBACK TO SAVEPOINT, so nothing
persists. The outer transaction is also rolled back at session end as a
defense in depth.

Auth simulation: we run as the postgres role (which bypasses RLS) but set
`request.jwt.claims` to fake a logged-in Supabase user. The Supabase
`auth.uid()` reads from that GUC, so RPCs work as if the user is signed in.
"""
import os
import uuid
import pytest
import psycopg2
import psycopg2.extras


# ───────────────────────────────────────────────────────────
# Connection (one per test session)
# ───────────────────────────────────────────────────────────

@pytest.fixture(scope="session")
def conn():
    url_path = os.path.expanduser('~/.citybuilder_db_url')
    if not os.path.exists(url_path):
        pytest.skip(f"DB URL file not found at {url_path}")
    url = open(url_path).read().strip()
    c = psycopg2.connect(url)
    c.autocommit = False
    # Bypass the desirability gate at the connection level. _pp_evolve_housing
    # checks `current_setting('city.skip_desirability_gate', true)`; setting
    # it 'true' once here means existing tier-evolution tests don't have to
    # be re-engineered to organically reach desirability 80+ for tier-6+
    # upgrades. Targeted gate tests can RESET it within their own savepoint.
    cur = c.cursor()
    cur.execute("SET \"city.skip_desirability_gate\" = 'true'")
    cur.close()
    yield c
    c.rollback()
    c.close()


# ───────────────────────────────────────────────────────────
# Per-test isolation via SAVEPOINT
# ───────────────────────────────────────────────────────────

@pytest.fixture
def cur(conn, request):
    """Yield a cursor wrapped in a savepoint. Auto-rollback after test."""
    sp_name = "sp_" + request.node.name.replace('-', '_').replace('[', '_').replace(']', '_').replace(' ', '_')
    sp_name = ''.join(c if c.isalnum() or c == '_' else '_' for c in sp_name)[:60]
    c = conn.cursor()
    c.execute(f"SAVEPOINT {sp_name}")
    try:
        yield c
    finally:
        try:
            c.execute(f"ROLLBACK TO SAVEPOINT {sp_name}")
        except psycopg2.Error:
            conn.rollback()  # if savepoint somehow vanished, nuke everything
        c.close()


# ───────────────────────────────────────────────────────────
# Test user helpers
# ───────────────────────────────────────────────────────────

def _create_auth_user(cur, email):
    """Insert a row into auth.users for FK purposes. Rolled back with savepoint."""
    uid = uuid.uuid4()
    cur.execute("""
        INSERT INTO auth.users (
            id, instance_id, aud, role, email, encrypted_password,
            email_confirmed_at, created_at, updated_at,
            raw_app_meta_data, raw_user_meta_data,
            is_super_admin, is_anonymous
        ) VALUES (
            %s, '00000000-0000-0000-0000-000000000000',
            'authenticated', 'authenticated',
            %s, '$2a$10$dummy.hash.value.for.tests.only',
            now(), now(), now(),
            '{}'::jsonb, '{}'::jsonb,
            false, false
        )
    """, (str(uid), email))
    return uid


def _set_auth(cur, user_id):
    """Make auth.uid() return the given UUID for this connection."""
    cur.execute(
        "SELECT set_config('request.jwt.claims', %s, true)",
        ('{"sub": "%s", "role": "authenticated"}' % user_id,)
    )


@pytest.fixture
def make_player(cur):
    """Factory: creates an auth user + invokes choose_industry to set up
    a fresh player with a starting district. Returns the player UUID.

    By default, bumps `highest_housing_tier_ever` to 8 so the
    progressive-unlock gate doesn't get in the way of tests that
    happen to place school / temple / luxury foods / industrial
    luxuries — those tests usually aren't asserting on the unlock
    mechanic itself. Pass `unlock_all=False` for tests that DO want
    the watermark to start at zero (e.g. the unlock-gate regression
    tests in test_progressive_unlock.py)."""
    counter = {'n': 0}
    def _make(industry='timber', display_name=None, unlock_all=True,
              tutorial_done=True, population=100):
        counter['n'] += 1
        suffix = uuid.uuid4().hex[:8]
        email = f"test-{counter['n']}-{suffix}@citybuilder.test"
        name = display_name or f"Tester{counter['n']}"
        uid = _create_auth_user(cur, email)
        _set_auth(cur, uid)
        cur.execute("SELECT public.choose_industry(%s, %s)", (name, industry))
        if unlock_all:
            cur.execute(
                "UPDATE public.player_profiles SET highest_housing_tier_ever = 8 WHERE id = %s",
                (str(uid),)
            )
        # Default to "tutorial complete" so tests don't get caught by
        # the AFTER INSERT trigger auto-bumping housing to tier 1 or
        # advancing tutorial_step in unexpected ways. Also seed a generous
        # worker pool — the tutorial-zero population default would leave
        # most tests with zero workers and zero production. Tests that
        # specifically exercise tutorial mechanics pass tutorial_done=False.
        if tutorial_done:
            cur.execute(
                "UPDATE public.player_profiles "
                "   SET tutorial_step = 4, trade_unlocked = true, "
                "       population = %s, worker_capacity = %s "
                " WHERE id = %s",
                (population, int(population), str(uid))
            )
        cur.execute("SELECT id, industry_key, money, chunks_owned, home_x, home_y FROM public.player_profiles WHERE id = %s", (str(uid),))
        row = cur.fetchone()
        assert row, f"choose_industry didn't create player_profile for {uid}"
        return {
            'id': uid,
            'industry_key': row[1],
            'money': row[2],
            'chunks_owned': row[3],
            'home_x': row[4],
            'home_y': row[5],
        }
    return _make


@pytest.fixture
def as_user(cur):
    """Switch the current connection's auth context to the given user."""
    def _as(user_id):
        _set_auth(cur, user_id if isinstance(user_id, str) else str(user_id))
    return _as


# ───────────────────────────────────────────────────────────
# Tile / building helpers
# ───────────────────────────────────────────────────────────

@pytest.fixture
def tile_id_at(cur):
    """Resolve (x, y) -> tile_id."""
    def _at(x, y):
        cur.execute("SELECT id FROM public.map_tiles WHERE x = %s AND y = %s", (x, y))
        row = cur.fetchone()
        return row[0] if row else None
    return _at


@pytest.fixture
def clear_resources(cur):
    """Wipe any random resource clusters from a player's district. Tests
    that build at known coordinates near home need this because the
    reject_build_on_resource trigger blocks building on a resource tile,
    and clustering may seed a resource right where the test wants to build.

    Also flattens the highway to a straight cross at (hx, *) and (*, hy)
    so the random curving highway doesn't run through the cells tests
    want to build on. The on-grid layout for tests is therefore:
      * Highway: y=hy (horizontal) and x=hx (vertical)
      * Buildable: everything else owned by the player
    """
    def _clear(player_id):
        cur.execute("SELECT home_x, home_y FROM public.player_profiles WHERE id = %s",
                    (str(player_id),))
        row = cur.fetchone()
        if not row or row[0] is None or row[1] is None:
            cur.execute(
                "UPDATE public.map_tiles SET resource_node_key = NULL WHERE owner_player_id = %s",
                (str(player_id),),
            )
            return
        hx, hy = row
        chunk_x = hx // 15 if hx >= 0 else (hx - 14) // 15
        chunk_y = hy // 15 if hy >= 0 else (hy - 14) // 15
        x_start = chunk_x * 15
        y_start = chunk_y * 15
        # Wipe random pre-placed roads (curving path) and re-stamp a
        # straight cross at (hx, *) and (*, hy) so tests have a
        # predictable road layout.
        cur.execute("""
            DELETE FROM public.buildings b
            USING public.building_types bt
            WHERE b.building_type_key = bt.key
              AND bt.category = 'road'
              AND b.player_id = %s
              AND b.x >= %s AND b.x < %s
              AND b.y >= %s AND b.y < %s
        """, (str(player_id), x_start, x_start + 15, y_start, y_start + 15))
        cur.execute("""
            UPDATE public.map_tiles
            SET resource_node_key = NULL,
                claimed_by_building_id = NULL
            WHERE owner_player_id = %s
              AND x >= %s AND x < %s AND y >= %s AND y < %s
        """, (str(player_id), x_start, x_start + 15, y_start, y_start + 15))
        # Re-place straight-cross roads via the helper used by allocate_district_chunk.
        for offset in range(15):
            cur.execute("SELECT public._place_pre_road(%s, %s, %s)",
                        (str(player_id), x_start + offset, hy))
            cur.execute("SELECT public._place_pre_road(%s, %s, %s)",
                        (str(player_id), hx, y_start + offset))
        # Clear resources across all owned tiles.
        cur.execute(
            "UPDATE public.map_tiles SET resource_node_key = NULL WHERE owner_player_id = %s",
            (str(player_id),),
        )
    return _clear


@pytest.fixture
def place(cur, tile_id_at):
    """Place a building via RPC. Returns the JSON result.

    Auto-resolves (x, y) to tile_id and asserts the tile exists.

    Also auto-tops-up the placing player's inventory with whatever the
    building's resource costs require (2026-05-08). The vast majority
    of existing tests place processors / services / police / transport
    to set up scenarios for OTHER assertions — they shouldn't have to
    enumerate brick / lime / lumber / etc just to get a building on
    the map. Tests that specifically exercise the resource-cost gate
    skip this fixture and call place_building directly with seeded
    inventory.
    """
    def _place(building_type_key, x, y):
        tid = tile_id_at(x, y)
        assert tid is not None, f"No tile at ({x}, {y}) — make sure the player's district covers it"
        # Look up the placing player's id (the one auth.uid() will return).
        cur.execute("SELECT current_setting('request.jwt.claims', true)")
        claims = cur.fetchone()[0]
        if claims:
            import json as _json
            try:
                uid = _json.loads(claims).get('sub')
            except Exception:
                uid = None
        else:
            uid = None
        # Top up resources for THIS building's costs.
        if uid:
            cur.execute(
                "SELECT resource_key, quantity FROM public.building_type_resource_costs "
                "WHERE building_type_key = %s",
                (building_type_key,)
            )
            for resource_key, qty in cur.fetchall():
                cur.execute(
                    "INSERT INTO public.inventories (player_id, resource_key, quantity) "
                    "VALUES (%s, %s, %s) "
                    "ON CONFLICT (player_id, resource_key) DO UPDATE SET "
                    "  quantity = GREATEST(public.inventories.quantity, EXCLUDED.quantity)",
                    (uid, resource_key, qty)
                )
        cur.execute("SELECT public.place_building(%s, %s)", (tid, building_type_key))
        return cur.fetchone()[0]
    return _place


@pytest.fixture
def tick(cur):
    """Run process_production() and then auto-step every house that the
    server flagged eligible (evolution_eligible_at IS NOT NULL).

    Manual upgrades (2026-05-08) replaced the auto-upgrade that
    process_production used to do — but most existing tests assume
    "tick → housing_tier += 1 if conditions hold". This helper keeps
    those tests truthful by walking through each newly-eligible house
    and calling upgrade_house, exactly as the player does in the UI.

    Tests that specifically want to verify the manual gate (i.e., that
    the user has to click) should call process_production directly and
    inspect evolution_eligible_at.
    """
    def _tick(player_id=None):
        cur.execute("SELECT public.process_production()")
        if player_id is None:
            cur.execute(
                "SELECT id FROM public.buildings WHERE evolution_eligible_at IS NOT NULL"
            )
        else:
            cur.execute(
                "SELECT id FROM public.buildings WHERE player_id = %s AND evolution_eligible_at IS NOT NULL",
                (str(player_id),),
            )
        for (bid,) in cur.fetchall():
            cur.execute("SAVEPOINT try_up")
            try:
                cur.execute("SELECT public.upgrade_house(%s)", (str(bid),))
                cur.execute("RELEASE SAVEPOINT try_up")
            except Exception:
                cur.execute("ROLLBACK TO SAVEPOINT try_up")
    return _tick


@pytest.fixture
def stamp_food_tile(cur, tile_id_at):
    """Stamp a food tile (resource_node_key) at (x, y). Use before placing
    a food extractor (orchard, fishing_pier, garden, grain_farm) since
    those buildings require their matching food tile to be present at
    placement time."""
    def _stamp(food_tile_key, x, y):
        tid = tile_id_at(x, y)
        assert tid is not None, f"No tile at ({x}, {y})"
        cur.execute("UPDATE public.map_tiles SET resource_node_key = %s WHERE id = %s",
                    (food_tile_key, str(tid)))
    return _stamp
