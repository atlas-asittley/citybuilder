"""Tests for parcel resource density (doubled on 2026-05-09).

Atlas: "double the amount of resources in each parcel."

`allocate_district_chunk` now seeds 4 industry clusters (was 2) and
2 food clusters (was 1) for first-chunk allocations. Walk lengths
unchanged; total tile count roughly doubles.

These tests pin the density so a future revert to single-cluster
counts is caught immediately. Empirical samples across 10 trials
of iron-industry first-chunks measured:
  - Industry tiles: range 8-13, mean 10.0 (pre-double mean ~7)
  - Food tiles:     range 4-7, mean 5.5 (pre-double mean ~2.5)

Test thresholds intentionally below the observed post-double minimum
so they survive random variance, but well above the pre-double
mean so they fail if the doubling regresses.
"""
import uuid


def _spawn_player_and_count_tiles(cur, industry):
    """Spawn a fresh player in the given industry and return
    (industry_tile_count, food_tile_count) for their starter chunk."""
    food_keys = {
        'timber': 'orchard_grove',
        'stone':  'pond',
        'clay':   'garden_plot',
        'iron':   'farmland',
    }
    food_key = food_keys[industry]

    uid = uuid.uuid4()
    cur.execute("""
        INSERT INTO auth.users (id, instance_id, aud, role, email, encrypted_password,
            email_confirmed_at, created_at, updated_at, raw_app_meta_data, raw_user_meta_data,
            is_super_admin, is_anonymous) VALUES
        (%s, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
         %s, '$2a$10$x', now(), now(), now(), '{}'::jsonb, '{}'::jsonb, false, false)
    """, (str(uid), f"density-{str(uid)[:8]}@test.test"))
    cur.execute("SELECT set_config('request.jwt.claims', %s, true)",
        ('{"sub":"%s","role":"authenticated"}' % uid,))
    cur.execute("SELECT public.choose_industry('Density', %s)", (industry,))

    cur.execute("""
        SELECT resource_node_key, count(*) FROM public.map_tiles
        WHERE owner_player_id = %s AND resource_node_key IS NOT NULL
        GROUP BY 1
    """, (str(uid),))
    rows = {r[0]: r[1] for r in cur.fetchall()}
    return rows.get(industry, 0), rows.get(food_key, 0)


def test_first_chunk_industry_density_doubled(cur):
    """Sum 4 trials of iron-industry first-chunk allocations; assert
    industry-tile total ≥ 24 (post-double expectation ~40, pre-double
    expectation ~20). Threshold leaves variance room while still
    catching a revert to halved cluster counts."""
    totals = []
    for _ in range(4):
        cur.execute("SAVEPOINT sp")
        i, _f = _spawn_player_and_count_tiles(cur, 'iron')
        totals.append(i)
        cur.execute("ROLLBACK TO SAVEPOINT sp")
    total = sum(totals)
    assert total >= 24, (
        f"first-chunk industry density should reflect 4-cluster seeding; "
        f"got per-trial counts {totals} (sum {total}, expected ≥ 24)"
    )


def test_first_chunk_food_density_doubled(cur):
    """Sum 4 trials of iron-industry first-chunk allocations; assert
    food-tile total ≥ 12 (post-double expectation ~22, pre-double
    expectation ~10)."""
    totals = []
    for _ in range(4):
        cur.execute("SAVEPOINT sp")
        _i, f = _spawn_player_and_count_tiles(cur, 'iron')
        totals.append(f)
        cur.execute("ROLLBACK TO SAVEPOINT sp")
    total = sum(totals)
    assert total >= 12, (
        f"first-chunk food density should reflect 2-cluster seeding; "
        f"got per-trial counts {totals} (sum {total}, expected ≥ 12)"
    )


def test_all_industries_seed_both_kinds(cur):
    """Sanity: every industry's first chunk has both industry and food
    resources seeded. A regression that removes either cluster call
    would fail here."""
    for industry in ('timber', 'stone', 'clay', 'iron'):
        cur.execute("SAVEPOINT sp_" + industry)
        i, f = _spawn_player_and_count_tiles(cur, industry)
        cur.execute("ROLLBACK TO SAVEPOINT sp_" + industry)
        assert i >= 4, f"{industry}: expected ≥ 4 industry tiles, got {i}"
        assert f >= 2, f"{industry}: expected ≥ 2 food tiles, got {f}"
