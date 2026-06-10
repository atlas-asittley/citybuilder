"""Tests for Phase C2 — advanced cross-recipe T4 buildings.

Each industry has one T4 cross-recipe building consuming its own T3
output PLUS another industry's cross-good. The trade dependency cycles:

  timber: Cabinetmaker          (furniture + lime     → cabinets)
  stone:  Architect             (statuary  + glass    → monuments)
  clay:   Mosaic Workshop       (tiles     + nails    → mosaics)
  iron:   Engineer's Workshop   (tools     + charcoal → machinery)

Round-robin: timber→stone→clay→iron→timber on the cross-good cycle.
Each industry consumes the previous industry's cross-good and
produces one for the next.
"""
import psycopg2
import pytest


# ── industry filter ─────────────────────────────────────────

@pytest.mark.parametrize("industry,key", [
    ('timber', 'cabinetmaker'),
    ('stone',  'architect'),
    ('clay',   'mosaic_workshop'),
    ('iron',   'engineer_workshop'),
])
def test_industry_can_place_t4(industry, key, make_player, place, cur, clear_resources):
    p = make_player(industry=industry)
    clear_resources(p['id'])
    cur.execute("UPDATE public.player_profiles SET money = 5000 WHERE id = %s", (str(p['id']),))
    hx, hy = p['home_x'], p['home_y']
    place('road', hx + 1, hy + 1)
    result = place(key, hx + 1, hy + 2)
    assert 'building_id' in result


@pytest.mark.parametrize("wrong_industry,key", [
    ('stone',  'cabinetmaker'),
    ('iron',   'architect'),
    ('timber', 'mosaic_workshop'),
    ('clay',   'engineer_workshop'),
])
def test_wrong_industry_rejected(wrong_industry, key, make_player, place, cur, clear_resources):
    p = make_player(industry=wrong_industry)
    clear_resources(p['id'])
    cur.execute("UPDATE public.player_profiles SET money = 5000 WHERE id = %s", (str(p['id']),))
    hx, hy = p['home_x'], p['home_y']
    try:
        place(key, hx + 1, hy + 1)
        assert False, "should have raised"
    except psycopg2.errors.RaiseException as e:
        assert 'industry' in str(e).lower()


# ── outputs are tracked correctly (non-food) ────────────────

@pytest.mark.parametrize("resource_key", ['cabinets', 'monuments', 'mosaics', 'machinery'])
def test_t4_outputs_not_food(resource_key, cur):
    cur.execute("SELECT is_food FROM resources WHERE key = %s", (resource_key,))
    assert cur.fetchone()[0] is False, f"{resource_key} should be is_food=false"


# ── recipes correctly require the right cross-good ─────────

@pytest.mark.parametrize("building,own_input,cross_input,output", [
    ('cabinetmaker',     'furniture', 'lime',     'cabinets'),
    ('architect',        'statuary',  'glass',    'monuments'),
    ('mosaic_workshop',  'tiles',     'nails',    'mosaics'),
    ('engineer_workshop','tools',     'charcoal', 'machinery'),
])
def test_t4_recipe_inputs(building, own_input, cross_input, output, cur):
    cur.execute("""SELECT input_resource_key, input_resource_key_2, output_resource_key
                   FROM building_types WHERE key = %s""", (building,))
    row = cur.fetchone()
    assert row[0] == own_input,   f"{building} input1: expected {own_input}, got {row[0]}"
    assert row[1] == cross_input, f"{building} input2: expected {cross_input}, got {row[1]}"
    assert row[2] == output,      f"{building} output: expected {output}, got {row[2]}"


# ── production with both inputs in stock ────────────────────

def test_cabinetmaker_produces_with_both_inputs(make_player, place, cur, clear_resources):
    p = make_player(industry='timber')
    clear_resources(p['id'])
    cur.execute("UPDATE public.player_profiles SET money = 5000 WHERE id = %s", (str(p['id']),))
    cur.execute("UPDATE public.building_types SET worker_cost = 4 WHERE key = 'cabinetmaker'")
    hx, hy = p['home_x'], p['home_y']
    place('road', hx + 1, hy + 1)
    place('cabinetmaker', hx + 1, hy + 2)
    cur.execute("""INSERT INTO public.inventories (player_id, resource_key, quantity) VALUES
                     (%s, 'furniture', 5.0), (%s, 'lime', 5.0)
                   ON CONFLICT (player_id, resource_key) DO UPDATE SET quantity = EXCLUDED.quantity""",
                (str(p['id']), str(p['id'])))
    cur.execute("""UPDATE public.buildings SET last_processed_at = now() - interval '60 seconds'
                   WHERE player_id = %s""", (str(p['id']),))
    cur.execute("SELECT public.process_production()")
    cur.execute("""SELECT resource_key, quantity FROM public.inventories
                   WHERE player_id = %s AND resource_key IN ('furniture', 'lime', 'cabinets')""",
                (str(p['id']),))
    rows = {r[0]: float(r[1]) for r in cur.fetchall()}
    # 0.5 furniture + 0.5 lime → 0.25 cabinets in 60s
    assert 4.45 < rows['furniture'] < 4.55, f"furniture: expected ~4.5, got {rows['furniture']}"
    assert 4.45 < rows['lime']      < 4.55, f"lime: expected ~4.5, got {rows['lime']}"
    assert 0.20 < rows['cabinets']  < 0.30, f"cabinets: expected ~0.25, got {rows['cabinets']}"


# ── gated by missing cross-good ─────────────────────────────

def test_cabinetmaker_idle_without_lime(make_player, place, cur, clear_resources):
    """Timber player has furniture but no lime → cabinetmaker idles
    completely (no furniture drained, no cabinets produced)."""
    p = make_player(industry='timber')
    clear_resources(p['id'])
    cur.execute("UPDATE public.player_profiles SET money = 5000 WHERE id = %s", (str(p['id']),))
    cur.execute("UPDATE public.building_types SET worker_cost = 4 WHERE key = 'cabinetmaker'")
    hx, hy = p['home_x'], p['home_y']
    place('road', hx + 1, hy + 1)
    place('cabinetmaker', hx + 1, hy + 2)
    cur.execute("""INSERT INTO public.inventories (player_id, resource_key, quantity) VALUES
                     (%s, 'furniture', 5.0), (%s, 'lime', 0)
                   ON CONFLICT (player_id, resource_key) DO UPDATE SET quantity = EXCLUDED.quantity""",
                (str(p['id']), str(p['id'])))
    cur.execute("""UPDATE public.buildings SET last_processed_at = now() - interval '60 seconds'
                   WHERE player_id = %s""", (str(p['id']),))
    cur.execute("SELECT public.process_production()")
    cur.execute("""SELECT resource_key, quantity FROM public.inventories
                   WHERE player_id = %s AND resource_key IN ('furniture', 'cabinets')""",
                (str(p['id']),))
    rows = {r[0]: float(r[1]) for r in cur.fetchall()}
    assert rows['furniture'] == 5.0, \
        f"furniture should not be consumed without lime, got {rows['furniture']}"
    assert rows.get('cabinets', 0) == 0, \
        f"no cabinets without lime, got {rows.get('cabinets')}"


# ── round-robin trade dependency: each industry consumes a different industry's cross-good ──

def test_round_robin_trade_dependency(cur):
    """Sanity check the trade cycle: each industry's T4 building consumes
    a cross-good produced by exactly one OTHER industry's cross-converter.
    No industry consumes its own cross-good."""
    cur.execute("""
      SELECT t4.industry_key AS consumer,
             cc.industry_key AS producer,
             t4.input_resource_key_2 AS cross_good
      FROM building_types t4
      JOIN building_types cc ON cc.output_resource_key = t4.input_resource_key_2
      WHERE t4.key IN ('cabinetmaker', 'architect', 'mosaic_workshop', 'engineer_workshop')
        AND cc.category = 'processor'
        AND cc.tier = 2
        AND cc.key IN ('charcoal_kiln', 'lime_kiln', 'glassworks', 'nail_forge')
      ORDER BY t4.industry_key
    """)
    deps = cur.fetchall()
    # 4 dependencies, all cross-industry (consumer != producer)
    assert len(deps) == 4, f"expected 4 trade dependencies, got {len(deps)}"
    for consumer, producer, cross_good in deps:
        assert consumer != producer, \
            f"{consumer} should not consume its own cross-good {cross_good}"
    # Cycle: timber→stone→clay→iron→timber means timber consumes stone's lime, etc.
    deps_dict = {consumer: producer for consumer, producer, _ in deps}
    assert deps_dict['timber'] == 'stone', f"timber should consume stone's good, got {deps_dict['timber']}"
    assert deps_dict['stone']  == 'clay',  f"stone should consume clay's good, got {deps_dict['stone']}"
    assert deps_dict['clay']   == 'iron',  f"clay should consume iron's good, got {deps_dict['clay']}"
    assert deps_dict['iron']   == 'timber',f"iron should consume timber's good, got {deps_dict['iron']}"
