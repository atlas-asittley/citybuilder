"""Tests for the happiness + population system.

Coverage:
- Initial happiness is between 0 and 100.
- Population dynamic is symmetric: max ±1 citizen/min in either
  direction, scaled by distance from happiness=50. Hard floor at
  population=5 (citizens never leave below baseline, even at
  happiness=0 — prevents the death spiral).
- Population clamps DOWN to housing capacity when housing is lost.
- worker_capacity reflects floor(population) (the legacy tavern
  +10 bonus was removed on 2026-05-08).
"""
import pytest




def _backdate_population_tick(cur, player_id, secs):
    cur.execute("""
        UPDATE public.player_profiles
        SET last_population_tick_at = now() - make_interval(secs => %s)
        WHERE id = %s
    """, (secs, str(player_id)))


def test_initial_happiness_is_in_range(make_player, cur):
    p = make_player(industry='timber')
    cur.execute("SELECT (public.compute_happiness(%s)->>'happiness')::numeric", (str(p['id']),))
    h = cur.fetchone()[0]
    assert 0 <= h <= 100


def test_initial_population_starts_at_floor(make_player, cur):
    """Post-tutorial player starts at the floor=15. tutorial_done=False
    starts at column default 0 (tutorial floor)."""
    # tutorial_done=True (default) sets pop to 100 in the conftest fixture,
    # so use tutorial_done=False to see the column default behavior.
    p = make_player(industry='timber', tutorial_done=False)
    cur.execute("SELECT population FROM public.player_profiles WHERE id = %s", (str(p['id']),))
    assert cur.fetchone()[0] == 0  # column default for fresh profile


def test_population_grows_toward_capacity_when_happy(make_player, place, cur, clear_resources):
    """When housing capacity exceeds population AND happiness ≥ 50,
    citizens immigrate gradually. Post-tutorial floor=15, so a
    happy long tick fills toward 15 + housing_supply."""
    p = make_player(industry='timber', population=5)  # below floor=15
    clear_resources(p['id'])
    hx, hy = p['home_x'], p['home_y']

    # Tier-1 housing (Mud Hut, 6 workers) → target = 15 + 6 = 21.
    # Below-floor branch refills toward 15 first, then immigration fills
    # the remaining 6 toward 21 if happy.
    place('well', hx + 3, hy + 1)
    place('house', hx + 2, hy + 1)
    cur.execute("UPDATE public.buildings SET housing_tier = 1 WHERE player_id = %s AND building_type_key = 'house'",
                (str(p['id']),))

    _backdate_population_tick(cur, p['id'], 10 * 60 * 60)
    cur.execute("SELECT public.process_production()")
    result = cur.fetchone()[0]
    assert result['population'] > 5, (
        f"happy long tick should grow pop above 5; got {result['population']}"
    )
    assert result['population'] <= 21, (
        f"pop should never exceed target 15+6=21; got {result['population']}"
    )
    assert result['migration_rate'] >= 0, (
        f"migration_rate should be non-negative when filling; got {result['migration_rate']}"
    )


def test_population_clamps_down_when_above_target(make_player, cur, clear_resources):
    """If population is somehow above the housing-capacity target (e.g.
    housing devolved or was demolished), the next tick clamps it back
    down to target. Verifies the LEAST(target, ...) branch."""
    p = make_player(industry='timber', population=20)
    clear_resources(p['id'])
    # No housing → target = floor (15) + 0 = 15. Pop=20 > target → clamp.
    cur.execute("""
        UPDATE public.player_profiles
        SET population = 20, last_population_tick_at = now()
        WHERE id = %s
    """, (str(p['id']),))
    cur.execute("SELECT public.process_production()")
    result = cur.fetchone()[0]
    assert result['population'] == 15, (
        f"pop above no-housing target (15) should clamp; got {result['population']}"
    )


def test_happiness_staffing_ratio_uses_capacity_vs_need(make_player, place, stamp_food_tile, cur, clear_resources):
    """Regression for the staffing-ratio computation in compute_happiness:
    earlier versions overwrote v_staffed and ended up measuring road
    connectivity, not staffing health. The contribution should track
    worker_capacity / workers_needed instead."""
    p = make_player(industry='timber')
    clear_resources(p['id'])
    hx, hy = p['home_x'], p['home_y']

    # No worker buildings yet → v_workers_needed=0 → staffing ratio = 1.0 → +20.
    cur.execute("SELECT public.compute_happiness(%s)", (str(p['id']),))
    base_breakdown = cur.fetchone()[0]['breakdown']
    assert base_breakdown['workers_needed'] == 0
    assert base_breakdown['staffing_ratio'] == 1.0

    # Place an extractor + food extractor (both have worker_cost > 0).
    place('timber_camp', hx + 1, hy - 1)
    stamp_food_tile('orchard_grove', hx + 1, hy + 1)
    place('orchard', hx + 1, hy + 1)
    cur.execute("SELECT public.compute_happiness(%s)", (str(p['id']),))
    bk = cur.fetchone()[0]['breakdown']
    assert bk['workers_needed'] > 0
    # Default starting capacity is 5 (population floor); workers_needed
    # for two extractors is 20 (2 × 10). Ratio should be 5/20 = 0.25.
    expected = bk['worker_capacity'] / bk['workers_needed']
    assert abs(float(bk['staffing_ratio']) - min(1.0, expected)) < 0.01, (
        f"staffing_ratio={bk['staffing_ratio']} expected≈{expected}"
    )


def test_population_floor_at_5_blocks_death_spiral(make_player, cur, clear_resources):
    """Death-spiral prevention: if population somehow drops below the
    baseline of 5 (e.g. fresh player or a regression), the next tick
    refills toward 5 at full rate REGARDLESS of happiness. Atlas asked
    to verify that an unhappy city can always recover — keeping ≥5
    workers means the player can always staff a Well or Watch House
    to start clawing back."""
    p = make_player(industry='timber')
    clear_resources(p['id'])
    # Force pop below floor and simulate a long tick.
    cur.execute("""
        UPDATE public.player_profiles
        SET population = 2, last_population_tick_at = now() - interval '60 minutes'
        WHERE id = %s
    """, (str(p['id']),))
    cur.execute("SELECT public.process_production()")
    result = cur.fetchone()[0]
    # Under-floor branch refills at max_rate=1/min × 60min, capped at floor=5.
    assert result['population'] >= 5, (
        f"population should refill to floor=5 from below; got {result['population']}"
    )


def test_emigration_caps_at_floor(make_player, place, cur, clear_resources):
    """Same floor enforced from the other direction: with housing but
    happiness < 50, emigration should drain pop only to floor=5,
    never below. Combined with the under-floor refill, this guarantees
    the player always has at least 5 workers to recover from."""
    p = make_player(industry='timber')
    clear_resources(p['id'])
    hx, hy = p['home_x'], p['home_y']

    # Tier-1 housing → target = 5 + 6 = 11.
    place('well', hx + 3, hy + 1)
    place('house', hx + 2, hy + 1)
    cur.execute("UPDATE public.buildings SET housing_tier = 1 WHERE player_id = %s AND building_type_key = 'house'",
                (str(p['id']),))
    # Three tax offices (-9 happiness) push us below 50 into the
    # emigration branch. Insert directly to bypass place_building's
    # tile / road checks (which fight the random highway placement).
    # Pick three unoccupied owned tiles by query.
    cur.execute("""SELECT id, x, y FROM public.map_tiles
                   WHERE owner_player_id = %s
                     AND occupied_building_id IS NULL
                     AND resource_node_key IS NULL
                     AND buildable = true
                   LIMIT 3""", (str(p['id']),))
    tiles = cur.fetchall()
    assert len(tiles) >= 3, "test fixture needs 3 free tiles"
    for tid, tx, ty in tiles:
        cur.execute("""INSERT INTO public.buildings
                       (player_id, building_type_key, x, y, status, tile_id)
                       VALUES (%s, 'tax_man', %s, %s, 'active', %s)""",
                    (str(p['id']), tx, ty, str(tid)))
        cur.execute("UPDATE public.map_tiles SET occupied_building_id = (SELECT id FROM public.buildings WHERE tile_id = %s) WHERE id = %s",
                    (str(tid), str(tid)))
    cur.execute("UPDATE public.player_profiles SET population = 11 WHERE id = %s", (str(p['id']),))
    # Backdate 24 hours — at 1/min emigration that would drain 11 → -1429
    # without a floor. Floor caps at 5.
    _backdate_population_tick(cur, p['id'], 24 * 60 * 60)
    cur.execute("SELECT public.process_production()")
    result = cur.fetchone()[0]
    assert result['population'] >= 5, (
        f"long unhappy spell should not drain below floor=5; got {result['population']}"
    )


def test_worker_capacity_uses_floor_population(make_player, cur):
    """worker_capacity = floor(population). The legacy tavern +10
    bonus was removed on 2026-05-08, so this is now a clean equality."""
    p = make_player(industry='timber')
    cur.execute("SELECT public.process_production()")
    result = cur.fetchone()[0]
    assert result['worker_supply'] == int(result['population']), (
        f"worker_supply ({result['worker_supply']}) should == floor(population) ({result['population']})"
    )
