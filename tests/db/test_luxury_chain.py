"""Tests for the T4 luxury chain extensions.

Each industry's food chain gets a final processor turning the T2 food
into a high-value luxury good:
  timber: wine        → spirits   (Distillery)
  stone:  smoked_fish → caviar    (Curing House)
  clay:   preserves   → spices    (Spicery)
  iron:   flour       → ale       (Brewery)

All four luxury outputs are flagged is_food=true so they auto-satisfy
the housing food gate (they're consumed by people).
"""
import psycopg2
import pytest


@pytest.mark.parametrize("industry,key", [
    ('timber', 'distillery'),
    ('stone',  'curing_house'),
    ('clay',   'spicery'),
    ('iron',   'brewery'),
])
def test_industry_can_place_luxury(industry, key, make_player, place, cur, clear_resources):
    p = make_player(industry=industry)
    clear_resources(p['id'])
    cur.execute("UPDATE public.player_profiles SET money = 5000 WHERE id = %s", (str(p['id']),))
    hx, hy = p['home_x'], p['home_y']
    place('road', hx + 1, hy + 1)
    result = place(key, hx + 1, hy + 2)
    assert 'building_id' in result


@pytest.mark.parametrize("wrong_industry,key", [
    ('stone',  'distillery'),
    ('timber', 'curing_house'),
    ('iron',   'spicery'),
    ('clay',   'brewery'),
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


@pytest.mark.parametrize("resource_key", ['spirits', 'caviar', 'spices', 'ale'])
def test_luxuries_are_food(resource_key, cur):
    cur.execute("SELECT is_food FROM resources WHERE key = %s", (resource_key,))
    assert cur.fetchone()[0] is True, f"{resource_key} should be is_food=true"


def test_distillery_produces_spirits(make_player, place, cur, clear_resources):
    """Distillery: wine → spirits. Stock wine, run a tick, expect spirits."""
    p = make_player(industry='timber')
    clear_resources(p['id'])
    cur.execute("UPDATE public.player_profiles SET money = 5000 WHERE id = %s", (str(p['id']),))
    cur.execute("UPDATE public.building_types SET worker_cost = 4 WHERE key = 'distillery'")
    hx, hy = p['home_x'], p['home_y']
    place('road', hx + 1, hy + 1)
    place('distillery', hx + 1, hy + 2)
    cur.execute("""INSERT INTO public.inventories (player_id, resource_key, quantity)
                   VALUES (%s, 'wine', 10.0)
                   ON CONFLICT (player_id, resource_key) DO UPDATE SET quantity = 10.0""",
                (str(p['id']),))
    cur.execute("""UPDATE public.buildings SET last_processed_at = now() - interval '60 seconds'
                   WHERE player_id = %s""", (str(p['id']),))
    cur.execute("SELECT public.process_production()")
    cur.execute("SELECT quantity FROM public.inventories WHERE player_id = %s AND resource_key = 'spirits'",
                (str(p['id']),))
    spirits = float(cur.fetchone()[0])
    # Distillery: 0.5 wine/min → 0.25 spirits/min, in 60s ≈ 0.25
    assert 0.20 < spirits < 0.30, f"distillery expected ~0.25 spirits, got {spirits}"


def test_brewery_competes_with_bakery_for_flour(make_player, place, cur, clear_resources):
    """Both Brewery and Bakery consume flour. With limited flour, both
    can run but each consumes some — the player decides via priorities
    or pausing which one to favor."""
    p = make_player(industry='iron')
    clear_resources(p['id'])
    cur.execute("UPDATE public.player_profiles SET money = 5000 WHERE id = %s", (str(p['id']),))
    cur.execute("UPDATE public.building_types SET worker_cost = 2 WHERE key IN ('brewery', 'bakery')")
    hx, hy = p['home_x'], p['home_y']
    place('road', hx + 1, hy + 1)
    place('road', hx + 3, hy + 1)
    # Brewery is 2x1 (covers hx+1..hx+2, hy+2). Place bakery at hx+3 so
    # the two footprints don't collide.
    place('brewery', hx + 1, hy + 2)
    place('bakery',  hx + 3, hy + 2)
    cur.execute("""INSERT INTO public.inventories (player_id, resource_key, quantity)
                   VALUES (%s, 'flour', 10.0)
                   ON CONFLICT (player_id, resource_key) DO UPDATE SET quantity = 10.0""",
                (str(p['id']),))
    cur.execute("""UPDATE public.buildings SET last_processed_at = now() - interval '60 seconds'
                   WHERE player_id = %s""", (str(p['id']),))
    cur.execute("SELECT public.process_production()")
    cur.execute("SELECT quantity FROM public.inventories WHERE player_id = %s AND resource_key IN ('ale', 'bread') ORDER BY resource_key",
                (str(p['id']),))
    rows = {r[0] for r in cur.fetchall()}
    cur.execute("""SELECT resource_key, quantity FROM public.inventories
                   WHERE player_id = %s AND resource_key IN ('ale', 'bread', 'flour')
                   ORDER BY resource_key""", (str(p['id']),))
    out = {k: float(q) for k, q in cur.fetchall()}
    # Both should produce something (ale + bread) at the same time
    assert out.get('ale', 0) > 0,   f"brewery should have produced ale, got {out.get('ale')}"
    assert out.get('bread', 0) > 0, f"bakery should have produced bread, got {out.get('bread')}"
    # And flour should be reduced
    assert out.get('flour', 10) < 10, f"flour should be consumed, got {out.get('flour')}"
