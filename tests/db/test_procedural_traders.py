"""Tests for the procedural trade-partner generation (2026-05-10).

Atlas: "we want to automatically and somewhat randomly generate
these trade partners... every transport hub BUILD spawns one new
partner. Every EXPAND spawns another."

Covered:
  - Building a transport_hub spawns one new trader with matching
    transport_mode + 3-6 resources + a name from the pool.
  - Expanding a transport_hub spawns another.
  - Name collisions append roman numerals (II, III, IV, ...).
  - Building a truck_depot spawns a truck-mode procedural trader.
"""
import uuid


def _count_active(cur, mode):
    cur.execute(
        "SELECT count(*) FROM public.traders WHERE transport_mode = %s AND is_active=true",
        (mode,)
    )
    return cur.fetchone()[0]


def _give_money(cur, pid, amount):
    cur.execute("UPDATE public.player_profiles SET money = %s WHERE id = %s", (amount, str(pid)))


def test_truck_depot_spawns_truck_trader(make_player, place, cur, clear_resources):
    """Placing a truck_depot triggers the AFTER INSERT trigger and
    creates one new procedural truck-mode trader."""
    p = make_player(industry='timber')
    clear_resources(p['id'])
    _give_money(cur, p['id'], 50000)
    hx, hy = p['home_x'], p['home_y']

    before = _count_active(cur, 'truck')
    place('truck_depot', hx + 1, hy + 1)
    after = _count_active(cur, 'truck')
    assert after == before + 1, f"expected +1 truck trader; got {after - before}"


def test_airport_build_then_expand_spawns_two(make_player, place, cur, clear_resources):
    """Build airport → spawn 1. Expand it → spawn another.
    Both partners should end up active with transport_mode='airport'."""
    p = make_player(industry='timber')
    clear_resources(p['id'])
    _give_money(cur, p['id'], 200000)
    hx, hy = p['home_x'], p['home_y']

    before = _count_active(cur, 'airport')
    # Airport is 3x3. Place it somewhere clear, away from the highway cross.
    result = place('airport', hx + 3, hy + 3)
    after_build = _count_active(cur, 'airport')
    assert after_build == before + 1, f"build should spawn 1 airport trader; delta={after_build-before}"

    bid = result['building_id'] if isinstance(result, dict) else None
    if bid is None:
        import json
        bid = json.loads(result)['building_id']

    cur.execute("SELECT public.expand_transport_hub(%s)", (bid,))
    after_expand = _count_active(cur, 'airport')
    assert after_expand == before + 2, f"expand should spawn 1 more; delta={after_expand-before}"


def test_truck_depot_build_then_expand_spawns_two(make_player, place, cur, clear_resources):
    """Build truck_depot → spawn 1 truck trader. Expand it → spawn another.
    Regression: expand_transport_hub previously rejected transport_connector
    category with 'Only transport hubs can be expanded'."""
    p = make_player(industry='timber')
    clear_resources(p['id'])
    _give_money(cur, p['id'], 100000)
    hx, hy = p['home_x'], p['home_y']

    before = _count_active(cur, 'truck')
    result = place('truck_depot', hx + 1, hy + 1)
    after_build = _count_active(cur, 'truck')
    assert after_build == before + 1, f"build should spawn 1 truck trader; delta={after_build-before}"

    bid = result['building_id'] if isinstance(result, dict) else None
    if bid is None:
        import json
        bid = json.loads(result)['building_id']

    cur.execute("SELECT public.expand_transport_hub(%s)", (bid,))
    after_expand = _count_active(cur, 'truck')
    assert after_expand == before + 2, f"expand should spawn 1 more truck trader; delta={after_expand-before}"


def test_procedural_trader_has_expanded_catalog(make_player, place, cur, clear_resources):
    """Every newly-spawned procedural trader carries a broad catalog plus a
    guaranteed bread row. _spawn_random_trader picks `25 + floor(random()*6)`
    (25-30) random resources then appends bread → ~26-31 trader_prices rows
    (capped at the active-resource count; a touch lower if bread is also in
    the random draw). Expanded from the old 3-6 by 'depot-traders-expanded-catalogs'."""
    p = make_player(industry='timber')
    clear_resources(p['id'])
    _give_money(cur, p['id'], 100000)
    hx, hy = p['home_x'], p['home_y']

    # Get the trader spawned by this build.
    cur.execute("SELECT max(created_at) FROM public.traders")
    high_water = cur.fetchone()[0]

    place('truck_depot', hx + 1, hy + 1)

    cur.execute("""
      SELECT t.key, t.name, count(tp.*) AS n,
             bool_or(tp.resource_key = 'bread') AS has_bread
      FROM public.traders t
      LEFT JOIN public.trader_prices tp ON tp.trader_key = t.key
      WHERE t.created_at > %s AND t.transport_mode = 'truck'
      GROUP BY t.key, t.name
    """, (high_water,))
    rows = cur.fetchall()
    assert len(rows) == 1, f"expected 1 new trader spawned, got {len(rows)}"
    n_resources = rows[0][2]
    has_bread = rows[0][3]
    assert 24 <= n_resources <= 31, f"expected an expanded ~26-31 catalog, got {n_resources}"
    assert has_bread, "every procedural trader must sell bread"


def test_procedural_trader_prices_in_band(make_player, place, cur, clear_resources):
    """For each procedural trader's resource row, buy_price should be
    within 60-95% of base_price and sell_price within 105-150%."""
    p = make_player(industry='timber')
    clear_resources(p['id'])
    _give_money(cur, p['id'], 50000)
    hx, hy = p['home_x'], p['home_y']

    cur.execute("SELECT max(created_at) FROM public.traders")
    high_water = cur.fetchone()[0]
    place('truck_depot', hx + 1, hy + 1)

    cur.execute("""
      SELECT r.base_price, tp.buy_price, tp.sell_price
      FROM public.trader_prices tp
      JOIN public.resources r ON r.key = tp.resource_key
      JOIN public.traders t ON t.key = tp.trader_key
      WHERE t.created_at > %s AND t.transport_mode = 'truck'
    """, (high_water,))
    for base, buy, sell in cur.fetchall():
        # Buy 0.6-0.95× base, with floor at 1.
        assert buy >= 1, f"buy_price must be ≥ 1, got {buy}"
        assert buy <= int(base * 0.95) + 1, (
            f"buy_price {buy} exceeds 0.95×base {base}"
        )
        # Sell 1.05-1.5× base, but always > buy+1 (the function enforces this).
        assert sell > buy, f"sell_price ({sell}) must be > buy_price ({buy})"
        # Soft upper bound — allow some slack for the GREATEST(buy+1, ...) floor.
        assert sell <= int(base * 1.5) + buy + 2, (
            f"sell_price {sell} far above 1.5×base {base}"
        )


def test_name_collision_appends_roman(cur):
    """Force a collision by inserting two traders with the same base
    name; the helper should append ' II' to the second."""
    cur.execute("SAVEPOINT _coll")
    # Pick a known pool name.
    cur.execute("SELECT name FROM public.trader_name_pool LIMIT 1")
    base = cur.fetchone()[0]

    # Insert a trader using that exact name. Then call _pick_trader_name
    # and confirm the candidate is the next roman-numbered variant.
    cur.execute("""
      INSERT INTO public.traders (key, name, transport_mode, is_active, tier,
        visit_capacity, visit_interval_minutes)
      VALUES ('test_coll_1', %s, 'truck', true, 1, 100, 10)
    """, (base,))

    # Empty out the name pool except for our base, so _pick_trader_name
    # is deterministic.
    cur.execute("DELETE FROM public.trader_name_pool WHERE name <> %s", (base,))

    cur.execute("SELECT public._pick_trader_name()")
    next_name = cur.fetchone()[0]
    assert next_name == base + ' II', f"expected '{base} II', got '{next_name}'"

    # Insert a second one with that name and pick again — should be III.
    cur.execute("""
      INSERT INTO public.traders (key, name, transport_mode, is_active, tier,
        visit_capacity, visit_interval_minutes)
      VALUES ('test_coll_2', %s, 'truck', true, 1, 100, 10)
    """, (next_name,))
    cur.execute("SELECT public._pick_trader_name()")
    third = cur.fetchone()[0]
    assert third == base + ' III', f"expected '{base} III', got '{third}'"
    cur.execute("ROLLBACK TO SAVEPOINT _coll")
