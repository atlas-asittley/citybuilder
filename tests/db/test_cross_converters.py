"""Tests for the 4 cross-converter buildings + multi-input processor support.

Each industry has one cross-converter producing a unique support good:
  timber: Charcoal Kiln (timber → charcoal)
  stone:  Lime Kiln     (stone  → lime)
  clay:   Glassworks    (clay   → glass)
  iron:   Nail Forge    (iron   → nails)

Multi-input processor support is also tested by temporarily promoting
charcoal_kiln to take 2 inputs — verifies the new processor-loop logic
limits production by the scarcest input.
"""
import psycopg2
import pytest


# ── industry filter ────────────────────────────────────────

@pytest.mark.parametrize("industry,key", [
    ('timber', 'charcoal_kiln'),
    ('stone',  'lime_kiln'),
    ('clay',   'glassworks'),
    ('iron',   'nail_forge'),
])
def test_industry_can_place_cross_converter(industry, key, make_player, place, cur, clear_resources):
    p = make_player(industry=industry)
    clear_resources(p['id'])
    cur.execute("UPDATE public.player_profiles SET money = 5000 WHERE id = %s", (str(p['id']),))
    hx, hy = p['home_x'], p['home_y']
    place('road', hx + 1, hy + 1)
    result = place(key, hx + 1, hy + 2)
    assert 'building_id' in result


@pytest.mark.parametrize("wrong_industry,key", [
    ('stone', 'charcoal_kiln'),
    ('clay',  'lime_kiln'),
    ('iron',  'glassworks'),
    ('timber', 'nail_forge'),
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


# ── new resources flagged correctly (none are food) ────────

@pytest.mark.parametrize("resource_key", ['charcoal', 'lime', 'glass', 'nails'])
def test_cross_goods_are_not_food(resource_key, cur):
    cur.execute("SELECT is_food FROM resources WHERE key = %s", (resource_key,))
    assert cur.fetchone()[0] is False, f"{resource_key} should be is_food=false"


# ── cross-converter production ─────────────────────────────

def test_charcoal_kiln_produces_charcoal(make_player, place, cur, clear_resources):
    p = make_player(industry='timber')
    clear_resources(p['id'])
    cur.execute("UPDATE public.player_profiles SET money = 5000 WHERE id = %s", (str(p['id']),))
    cur.execute("UPDATE public.building_types SET worker_cost = 4 WHERE key = 'charcoal_kiln'")
    hx, hy = p['home_x'], p['home_y']
    place('road', hx + 1, hy + 1)
    place('charcoal_kiln', hx + 1, hy + 2)
    cur.execute("""INSERT INTO public.inventories (player_id, resource_key, quantity)
                   VALUES (%s, 'timber', 10.0)
                   ON CONFLICT (player_id, resource_key) DO UPDATE SET quantity = 10.0""",
                (str(p['id']),))
    cur.execute("""UPDATE public.buildings SET last_processed_at = now() - interval '60 seconds'
                   WHERE player_id = %s""", (str(p['id']),))
    cur.execute("SELECT public.process_production()")
    cur.execute("SELECT quantity FROM public.inventories WHERE player_id = %s AND resource_key = 'charcoal'",
                (str(p['id']),))
    charcoal = float(cur.fetchone()[0])
    # 1 timber/min input → 0.5 charcoal/min output, in 60s ≈ 0.5
    assert 0.4 < charcoal < 0.6, f"charcoal_kiln expected ~0.5 charcoal, got {charcoal}"


def test_existing_processors_unchanged(make_player, place, cur, clear_resources):
    """Single-input processors (sawmill, mason, etc.) should keep working
    after the multi-input extension. The processor loop reads input_resource_key_2
    but defaults NULL → behaves as before."""
    p = make_player(industry='timber')
    clear_resources(p['id'])
    cur.execute("UPDATE public.player_profiles SET money = 5000 WHERE id = %s", (str(p['id']),))
    cur.execute("UPDATE public.building_types SET worker_cost = 4 WHERE key = 'sawmill'")
    hx, hy = p['home_x'], p['home_y']
    place('road', hx + 1, hy + 1)
    place('sawmill', hx + 1, hy + 2)
    cur.execute("""INSERT INTO public.inventories (player_id, resource_key, quantity)
                   VALUES (%s, 'timber', 10.0)
                   ON CONFLICT (player_id, resource_key) DO UPDATE SET quantity = 10.0""",
                (str(p['id']),))
    cur.execute("""UPDATE public.buildings SET last_processed_at = now() - interval '60 seconds'
                   WHERE player_id = %s""", (str(p['id']),))
    cur.execute("SELECT public.process_production()")
    cur.execute("SELECT quantity FROM public.inventories WHERE player_id = %s AND resource_key = 'lumber'",
                (str(p['id']),))
    lumber = float(cur.fetchone()[0])
    # Sawmill: 1 timber → 0.5 lumber, in 60s ≈ 0.5
    assert 0.4 < lumber < 0.6, f"sawmill (single-input) regression — got {lumber}"


# ── multi-input processor support ──────────────────────────

def test_multi_input_processor_consumes_both(make_player, place, cur, clear_resources):
    """Promote charcoal_kiln to take a 2nd input (lime). Verify both
    inputs drain proportional to elapsed AND output is gated by the
    most-depleted input."""
    p = make_player(industry='timber')
    clear_resources(p['id'])
    cur.execute("UPDATE public.player_profiles SET money = 5000 WHERE id = %s", (str(p['id']),))
    cur.execute("UPDATE public.building_types SET worker_cost = 4 WHERE key = 'charcoal_kiln'")
    # Hack the building_types row to be 2-input: timber + lime → charcoal
    cur.execute("""UPDATE public.building_types
                   SET input_resource_key_2 = 'lime', input_rate_2 = 0.5
                   WHERE key = 'charcoal_kiln'""")
    hx, hy = p['home_x'], p['home_y']
    place('road', hx + 1, hy + 1)
    place('charcoal_kiln', hx + 1, hy + 2)
    cur.execute("""INSERT INTO public.inventories (player_id, resource_key, quantity) VALUES
                     (%s, 'timber', 10.0), (%s, 'lime', 10.0)
                   ON CONFLICT (player_id, resource_key) DO UPDATE SET quantity = EXCLUDED.quantity""",
                (str(p['id']), str(p['id'])))
    cur.execute("""UPDATE public.buildings SET last_processed_at = now() - interval '60 seconds'
                   WHERE player_id = %s""", (str(p['id']),))
    cur.execute("SELECT public.process_production()")
    cur.execute("""SELECT resource_key, quantity FROM public.inventories
                   WHERE player_id = %s AND resource_key IN ('timber', 'lime', 'charcoal')""",
                (str(p['id']),))
    rows = {r[0]: float(r[1]) for r in cur.fetchall()}
    # Both inputs available → progress = 1, full tick:
    #   timber: 10 - 1.0 = 9.0
    #   lime:   10 - 0.5 = 9.5
    #   charcoal: ~0.5
    assert 8.9 < rows['timber'] < 9.1, f"timber: expected ~9.0, got {rows['timber']}"
    assert 9.4 < rows['lime']   < 9.6, f"lime: expected ~9.5, got {rows['lime']}"
    assert 0.4 < rows['charcoal'] < 0.6, f"charcoal: expected ~0.5, got {rows['charcoal']}"


def test_multi_input_processor_gated_by_scarcest(make_player, place, cur, clear_resources):
    """Same setup but the second input is half-stocked. Output should
    drop to half (gated by lime)."""
    p = make_player(industry='timber')
    clear_resources(p['id'])
    cur.execute("UPDATE public.player_profiles SET money = 5000 WHERE id = %s", (str(p['id']),))
    cur.execute("UPDATE public.building_types SET worker_cost = 4 WHERE key = 'charcoal_kiln'")
    cur.execute("""UPDATE public.building_types
                   SET input_resource_key_2 = 'lime', input_rate_2 = 0.5
                   WHERE key = 'charcoal_kiln'""")
    hx, hy = p['home_x'], p['home_y']
    place('road', hx + 1, hy + 1)
    place('charcoal_kiln', hx + 1, hy + 2)
    # Stock timber = 10 (need 1.0), lime = 0.25 (need 0.5 — half what's needed)
    cur.execute("""INSERT INTO public.inventories (player_id, resource_key, quantity) VALUES
                     (%s, 'timber', 10.0), (%s, 'lime', 0.25)
                   ON CONFLICT (player_id, resource_key) DO UPDATE SET quantity = EXCLUDED.quantity""",
                (str(p['id']), str(p['id'])))
    cur.execute("""UPDATE public.buildings SET last_processed_at = now() - interval '60 seconds'
                   WHERE player_id = %s""", (str(p['id']),))
    cur.execute("SELECT public.process_production()")
    cur.execute("""SELECT resource_key, quantity FROM public.inventories
                   WHERE player_id = %s AND resource_key IN ('timber', 'lime', 'charcoal')""",
                (str(p['id']),))
    rows = {r[0]: float(r[1]) for r in cur.fetchall()}
    # Progress = min(10/1, 0.25/0.5) = min(10, 0.5) = 0.5
    # timber drained 0.5 (50% of 1)
    # lime drained 0.25 (50% of 0.5 — all of it)
    # charcoal made: 0.5 × 0.5 = 0.25
    assert 9.4 < rows['timber'] < 9.6, f"timber: expected ~9.5 (only 50% drained), got {rows['timber']}"
    assert rows['lime'] < 0.05, f"lime: expected ~0 (all drained), got {rows['lime']}"
    assert 0.20 < rows['charcoal'] < 0.30, f"charcoal: expected ~0.25 (gated by lime), got {rows['charcoal']}"


def test_multi_input_processor_no_second_input_no_production(make_player, place, cur, clear_resources):
    """If the 2nd input is required but missing, no production at all."""
    p = make_player(industry='timber')
    clear_resources(p['id'])
    cur.execute("UPDATE public.player_profiles SET money = 5000 WHERE id = %s", (str(p['id']),))
    cur.execute("UPDATE public.building_types SET worker_cost = 4 WHERE key = 'charcoal_kiln'")
    cur.execute("""UPDATE public.building_types
                   SET input_resource_key_2 = 'lime', input_rate_2 = 0.5
                   WHERE key = 'charcoal_kiln'""")
    hx, hy = p['home_x'], p['home_y']
    place('road', hx + 1, hy + 1)
    place('charcoal_kiln', hx + 1, hy + 2)
    cur.execute("""INSERT INTO public.inventories (player_id, resource_key, quantity) VALUES
                     (%s, 'timber', 10.0), (%s, 'lime', 0)
                   ON CONFLICT (player_id, resource_key) DO UPDATE SET quantity = EXCLUDED.quantity""",
                (str(p['id']), str(p['id'])))
    cur.execute("""UPDATE public.buildings SET last_processed_at = now() - interval '60 seconds'
                   WHERE player_id = %s""", (str(p['id']),))
    cur.execute("SELECT public.process_production()")
    cur.execute("""SELECT resource_key, quantity FROM public.inventories
                   WHERE player_id = %s AND resource_key IN ('timber', 'charcoal')""",
                (str(p['id']),))
    rows = {r[0]: float(r[1]) for r in cur.fetchall()}
    # progress = min(10, 0/0.5) = 0
    # timber: not drained (no production happened)
    # charcoal: 0 produced
    assert rows['timber'] == 10.0, f"timber should not be drained when 2nd input missing, got {rows['timber']}"
    assert rows.get('charcoal', 0) == 0, f"no charcoal should be produced, got {rows.get('charcoal')}"
