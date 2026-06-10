"""Tests for the paired food-extractor system.

Each industry gets a paired food extractor — locked to that industry via
`industry_key`. The extractors produce food at a flat rate (no path math,
no resource tile claim). Their output is flagged is_food=true so it
satisfies the housing food gate automatically.

  timber → orchard      → berries
  stone  → fishing_pier → fish
  clay   → garden       → vegetables
  grain  → grain_farm   → grain (existing; not industry-locked yet)
"""
import psycopg2
import pytest

def _tick_and_upgrade_all(cur):
    """process_production + auto-step every now-eligible house. Mirrors
    what the player does in the UI (the click on the Upgrade button)
    so tests written against the pre-2026-05-08 auto-upgrade flow stay
    truthful. Safe to call even when nothing is eligible."""
    cur.execute("SELECT public.process_production()")
    cur.execute("SELECT id FROM public.buildings WHERE evolution_eligible_at IS NOT NULL")
    for (bid,) in cur.fetchall():
        cur.execute("SAVEPOINT __tu")
        try:
            cur.execute("SELECT public.upgrade_house(%s)", (str(bid),))
            cur.execute("RELEASE SAVEPOINT __tu")
        except Exception:
            cur.execute("ROLLBACK TO SAVEPOINT __tu")




# ── industry filter on placement ─────────────────────────────

_FOOD_TILE_FOR = {'orchard': 'orchard_grove', 'fishing_pier': 'pond',
                  'garden': 'garden_plot', 'grain_farm': 'farmland'}


@pytest.mark.parametrize("industry,allowed_key", [
    ('timber', 'orchard'),
    ('stone',  'fishing_pier'),
    ('clay',   'garden'),
])
def test_industry_can_place_paired_food_extractor(industry, allowed_key, make_player, place, stamp_food_tile, cur, clear_resources):
    p = make_player(industry=industry)
    clear_resources(p['id'])
    hx, hy = p['home_x'], p['home_y']
    stamp_food_tile(_FOOD_TILE_FOR[allowed_key], hx + 1, hy + 1)
    result = place(allowed_key, hx + 1, hy + 1)
    assert result['building_id'] is not None


def test_timber_player_cannot_place_fishing_pier(make_player, place, cur, clear_resources):
    p = make_player(industry='timber')
    clear_resources(p['id'])
    hx, hy = p['home_x'], p['home_y']
    try:
        place('fishing_pier', hx + 1, hy + 1)
        assert False, "should have raised"
    except psycopg2.errors.RaiseException as e:
        assert 'industry' in str(e).lower()


def test_stone_player_cannot_place_orchard(make_player, place, cur, clear_resources):
    p = make_player(industry='stone')
    clear_resources(p['id'])
    hx, hy = p['home_x'], p['home_y']
    try:
        place('orchard', hx + 1, hy + 1)
        assert False, "should have raised"
    except psycopg2.errors.RaiseException as e:
        assert 'industry' in str(e).lower()


# ── flat-rate production ─────────────────────────────────────

def _food_extractors_cheap(cur):
    """Reduce food-extractor worker_cost so a new player's base capacity
    (5 workers) can staff one. Restored on savepoint rollback."""
    cur.execute("UPDATE public.building_types SET worker_cost = 4 WHERE category = 'food_extractor'")


def test_orchard_produces_berries_at_flat_rate(make_player, place, stamp_food_tile, cur, clear_resources):
    """orchard at output_rate=2 berries/min → ~2 berries over a 60s tick."""
    p = make_player(industry='timber')
    clear_resources(p['id'])
    _food_extractors_cheap(cur)
    hx, hy = p['home_x'], p['home_y']
    stamp_food_tile('orchard_grove', hx + 1, hy + 1)
    place('orchard', hx + 1, hy + 1)
    cur.execute("""UPDATE public.buildings
                   SET last_processed_at = now() - interval '60 seconds'
                   WHERE player_id = %s""", (str(p['id']),))
    _tick_and_upgrade_all(cur)
    cur.execute("SELECT quantity FROM public.inventories WHERE player_id = %s AND resource_key = 'berries'",
                (str(p['id']),))
    berries = float(cur.fetchone()[0])
    assert 3.5 < berries < 4.5, f"orchard expected ~4 berries/min, got {berries}"


def test_fishing_pier_produces_fish(make_player, place, stamp_food_tile, cur, clear_resources):
    p = make_player(industry='stone')
    clear_resources(p['id'])
    _food_extractors_cheap(cur)
    hx, hy = p['home_x'], p['home_y']
    stamp_food_tile('pond', hx + 1, hy + 1)
    place('fishing_pier', hx + 1, hy + 1)
    cur.execute("""UPDATE public.buildings
                   SET last_processed_at = now() - interval '60 seconds'
                   WHERE player_id = %s""", (str(p['id']),))
    _tick_and_upgrade_all(cur)
    cur.execute("SELECT quantity FROM public.inventories WHERE player_id = %s AND resource_key = 'fish'",
                (str(p['id']),))
    fish = float(cur.fetchone()[0])
    assert 3.5 < fish < 4.5, f"fishing pier expected ~4 fish/min, got {fish}"


# ── food extractor needs road access ─────────────────────────

def test_food_extractor_idle_without_road(make_player, place, stamp_food_tile, cur, clear_resources):
    """Food extractors now require road access (universal rule). A
    garden placed off-highway with no road touching it stays idle."""
    p = make_player(industry='clay')
    clear_resources(p['id'])
    _food_extractors_cheap(cur)
    hx, hy = p['home_x'], p['home_y']
    # Off-highway tile with no adjacent road.
    stamp_food_tile('garden_plot', hx + 2, hy + 2)
    bid = place('garden', hx + 2, hy + 2)['building_id']
    cur.execute("""UPDATE public.buildings
                   SET last_processed_at = now() - interval '60 seconds'
                   WHERE id = %s""", (bid,))
    _tick_and_upgrade_all(cur)
    cur.execute("SELECT COALESCE(SUM(quantity), 0) FROM public.inventories WHERE player_id = %s AND resource_key = 'vegetables'",
                (str(p['id']),))
    veg = float(cur.fetchone()[0])
    assert veg == 0, f"garden without road access should not produce; got {veg}"


def test_food_extractor_with_road_produces(make_player, place, stamp_food_tile, cur, clear_resources):
    """Same garden becomes productive once a road touches it."""
    p = make_player(industry='clay')
    clear_resources(p['id'])
    _food_extractors_cheap(cur)
    hx, hy = p['home_x'], p['home_y']
    place('road', hx + 2, hy + 1)  # road tile adjacent (north of) garden
    stamp_food_tile('garden_plot', hx + 2, hy + 2)
    bid = place('garden', hx + 2, hy + 2)['building_id']
    cur.execute("""UPDATE public.buildings
                   SET last_processed_at = now() - interval '60 seconds'
                   WHERE id = %s""", (bid,))
    _tick_and_upgrade_all(cur)
    cur.execute("SELECT quantity FROM public.inventories WHERE player_id = %s AND resource_key = 'vegetables'",
                (str(p['id']),))
    veg = float(cur.fetchone()[0])
    assert veg > 1.5, f"garden with road should produce; got {veg}"


# ── output satisfies housing food gate ───────────────────────

def test_orchard_output_satisfies_food_gate(make_player, place, stamp_food_tile, cur, clear_resources):
    """Berries from an orchard satisfy the tier-1+ housing food gate.
    Within a single process_production tick, the orchard's berries arrive
    in the inventory BEFORE the housing eval runs, so the food gate
    passes and the shanty upgrades to mud hut."""
    p = make_player(industry='timber')
    clear_resources(p['id'])
    _food_extractors_cheap(cur)
    hx, hy = p['home_x'], p['home_y']
    place('well', hx + 2, hy + 1)
    # Orchard needs road access — place at (hx-1, hy+1) which is
    # adjacent to the vertical highway at (hx, hy+1).
    stamp_food_tile('orchard_grove', hx - 1, hy + 1)
    place('orchard', hx - 1, hy + 1)
    house_id = place('house', hx + 1, hy + 2)['building_id']  # tier 0

    cur.execute("""UPDATE public.buildings
                   SET last_processed_at = now() - interval '60 seconds'
                   WHERE player_id = %s""", (str(p['id']),))
    cur.execute("""UPDATE public.player_profiles
                   SET last_food_tick_at = now() - interval '60 seconds',
                       population = 100
                   WHERE id = %s""", (str(p['id']),))

    _tick_and_upgrade_all(cur)

    cur.execute("SELECT quantity FROM public.inventories WHERE player_id = %s AND resource_key = 'berries'",
                (str(p['id']),))
    berries = float(cur.fetchone()[0])
    assert berries > 1.5, f"orchard should have produced berries, got {berries}"
    cur.execute("SELECT housing_tier FROM public.buildings WHERE id = %s", (house_id,))
    tier = cur.fetchone()[0]
    assert tier >= 1, f"house should have upgraded past tier 0 with berries; got tier {tier}"
