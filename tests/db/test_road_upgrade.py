"""Tests for upgrade_road (in-place road tier upgrade — Jill report e2b47efb).

The fancier-roads migration + road tiers are already live, so this only applies
road_upgrade_rpc.sql into the session transaction.
"""
import os
import re
import pytest

RPC = os.path.expanduser("~/citybuilder/city-builder-mvp/migration_patches/road_upgrade_rpc.sql")


@pytest.fixture(scope="module", autouse=True)
def _apply(conn):
    c = conn.cursor()
    c.execute(re.sub(r'(?im)^\s*(BEGIN|COMMIT)\s*;\s*$', '', open(RPC).read()))
    c.close()
    yield


def _a_road(cur, uid):
    cur.execute("""SELECT b.id, b.building_type_key FROM public.buildings b
                   JOIN public.building_types bt ON bt.key=b.building_type_key
                   WHERE b.player_id=%s AND bt.category='road' AND b.status='active' LIMIT 1""", (str(uid),))
    return cur.fetchone()


def _give(cur, uid, res, qty):
    cur.execute("""INSERT INTO public.inventories (player_id, resource_key, quantity) VALUES (%s,%s,%s)
                   ON CONFLICT (player_id, resource_key) DO UPDATE SET quantity=EXCLUDED.quantity""",
                (str(uid), res, qty))


def test_upgrade_dirt_to_paved(cur, make_player, clear_resources):
    p = make_player(industry='timber', population=50)
    clear_resources(p['id'])                       # stamps the dirt-road cross
    bid, key = _a_road(cur, p['id'])
    assert key == 'road'
    _give(cur, p['id'], 'brick', 5)
    cur.execute("UPDATE public.player_profiles SET money=1000 WHERE id=%s", (str(p['id']),))

    cur.execute("SELECT public.upgrade_road(%s, 'paved_road')", (str(bid),))
    res = cur.fetchone()[0]
    assert res['building_type_key'] == 'paved_road'

    cur.execute("SELECT building_type_key FROM public.buildings WHERE id=%s", (str(bid),))
    assert cur.fetchone()[0] == 'paved_road', "type swapped in place"
    cur.execute("SELECT quantity FROM public.inventories WHERE player_id=%s AND resource_key='brick'", (str(p['id']),))
    assert float(cur.fetchone()[0]) == 4, "1 brick charged"
    cur.execute("SELECT money FROM public.player_profiles WHERE id=%s", (str(p['id']),))
    assert float(cur.fetchone()[0]) == 980, "build_cost 20 charged"
    # ledger row written (tagged as a road upgrade in context)
    cur.execute("""SELECT amount FROM public.cash_transactions
                   WHERE player_id=%s AND source='build_cost' AND context->>'road_upgrade'='true'""", (str(p['id']),))
    assert float(cur.fetchone()[0]) == -20


def test_cannot_downgrade_or_sidegrade(cur, make_player, clear_resources):
    p = make_player(industry='timber', population=50)
    clear_resources(p['id'])
    bid, _ = _a_road(cur, p['id'])
    _give(cur, p['id'], 'brick', 5); _give(cur, p['id'], 'tiles', 5)
    cur.execute("UPDATE public.player_profiles SET money=1000 WHERE id=%s", (str(p['id']),))
    cur.execute("SELECT public.upgrade_road(%s, 'tiled_avenue')", (str(bid),))  # dirt → tiled, ok
    # now try to "upgrade" tiled back to paved (lower tier) → reject
    with pytest.raises(Exception):
        cur.execute("SELECT public.upgrade_road(%s, 'paved_road')", (str(bid),))


def test_rejects_insufficient_materials(cur, make_player, clear_resources):
    p = make_player(industry='timber', population=50)
    clear_resources(p['id'])
    bid, _ = _a_road(cur, p['id'])
    cur.execute("DELETE FROM public.inventories WHERE player_id=%s AND resource_key='brick'", (str(p['id']),))
    cur.execute("UPDATE public.player_profiles SET money=1000 WHERE id=%s", (str(p['id']),))
    with pytest.raises(Exception):
        cur.execute("SELECT public.upgrade_road(%s, 'paved_road')", (str(bid),))


def test_rejects_non_road(cur, make_player, place, clear_resources):
    p = make_player(industry='timber', population=100)
    clear_resources(p['id'])
    hx, hy = p['home_x'], p['home_y']
    place('house', hx + 1, hy + 1)
    cur.execute("""SELECT id FROM public.buildings WHERE player_id=%s AND building_type_key='house' LIMIT 1""",
                (str(p['id']),))
    house_id = cur.fetchone()[0]
    with pytest.raises(Exception):
        cur.execute("SELECT public.upgrade_road(%s, 'paved_road')", (str(house_id),))
