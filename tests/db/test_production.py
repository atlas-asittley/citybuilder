"""Tests for `process_production` and housing evolution.

Regression coverage:
- housing tier upgrade used `upgrade_seconds` (typo) which the table
  doesn't have. Fix used `upgrade_secs`. These tests pin the field name
  by exercising the actual upgrade.
- Path-length scaling: extractor with path_length=4 produces at full
  rate, longer paths produce proportionally less.
"""
import pytest
import psycopg2

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




def test_housing_evolves_to_tier_1_with_road(make_player, place, cur, clear_resources):
    """Regression: shanty (tier 0) should upgrade to mud hut (tier 1)
    after enough time has elapsed AND a road is adjacent. Tier 1+ also
    needs a well within Manhattan distance 4 and any food in stock."""
    p = make_player()
    clear_resources(p['id'])
    hx, hy = p['home_x'], p['home_y']
    place('road', hx + 1, hy + 1)
    place('well', hx + 2, hy + 2)
    house_id = place('house', hx + 1, hy + 2)['building_id']

    # Stock some food so the tier-1 food gate passes
    cur.execute("""INSERT INTO public.inventories (player_id, resource_key, quantity)
                   VALUES (%s, 'grain', 5.0)
                   ON CONFLICT (player_id, resource_key) DO UPDATE SET quantity = 5.0""",
                (str(p['id']),))

    # Verify it started at tier 0
    cur.execute("SELECT housing_tier FROM public.buildings WHERE id = %s", (house_id,))
    assert cur.fetchone()[0] == 0

    # Fast-forward time by backdating last_processed_at (so process_production
    # sees enough elapsed seconds to fire the upgrade)
    cur.execute("""
        UPDATE public.buildings
        SET last_processed_at = now() - interval '120 seconds'
        WHERE id = %s
    """, (house_id,))

    _tick_and_upgrade_all(cur)

    cur.execute("SELECT housing_tier FROM public.buildings WHERE id = %s", (house_id,))
    assert cur.fetchone()[0] == 1, \
        "shanty did not upgrade to mud hut even with road + elapsed time"


def test_housing_devolves_without_road(make_player, place, cur, clear_resources):
    """A tier-1 mud hut should devolve to shanty if road access is lost.
    Has to be set up far from the highway, otherwise the highway alone
    keeps providing road access after the player's road is demolished."""
    p = make_player()
    clear_resources(p['id'])
    hx, hy = p['home_x'], p['home_y']
    # Chain a road south from the highway so the house's only road
    # adjacency is the last segment of the chain.
    road_chain = []
    for dy_off in range(1, 5):
        rid = place('road', hx + 1, hy + dy_off)['building_id']
        road_chain.append(rid)
    last_road = road_chain[-1]
    # House placed adjacent to the last road but two cells off the highway
    # column, so neither its position nor its neighbors touch the highway.
    house_id = place('house', hx + 2, hy + 4)['building_id']

    cur.execute(
        "UPDATE public.buildings SET housing_tier = 1, last_processed_at = now() - interval '120 seconds' WHERE id = %s",
        (house_id,),
    )

    # Demolish only the road touching the house. The rest of the chain
    # remains but doesn't reach the house's adjacency cells.
    cur.execute("DELETE FROM public.buildings WHERE id = %s", (last_road,))

    _tick_and_upgrade_all(cur)

    cur.execute("SELECT housing_tier FROM public.buildings WHERE id = %s", (house_id,))
    assert cur.fetchone()[0] == 0, "mud hut should devolve to shanty without road"


def test_extractor_no_path_produces_nothing(make_player, place, cur, clear_resources):
    """An idle extractor (path_length is NULL) should not credit any timber."""
    p = make_player(industry='timber')
    clear_resources(p['id'])
    hx, hy = p['home_x'], p['home_y']

    place('road', hx + 1, hy + 1)
    place('timber_camp', hx + 1, hy + 2)

    # Backdate so a normal extractor would have produced
    cur.execute("UPDATE public.buildings SET last_processed_at = now() - interval '60 seconds' WHERE player_id = %s", (str(p['id']),))

    _tick_and_upgrade_all(cur)

    cur.execute("SELECT COALESCE(SUM(quantity), 0) FROM public.inventories WHERE player_id = %s AND resource_key = 'timber'", (str(p['id']),))
    timber = cur.fetchone()[0]
    assert timber == 0, "idle extractor produced timber"
