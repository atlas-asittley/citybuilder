"""Tests for the resource tile rules:
  - Can't build on a tile with resource_node_key (BEFORE INSERT trigger).
  - clear_resource_tile RPC frees up an owned resource tile.
  - clear_resource_tile rejects: not owned, no resource, claimed extractor.
"""
import pytest
import psycopg2


def _resource_tile_in_district(cur, player_id, resource_key):
    """Find any tile in the player's district that currently has the
    given resource. Returns (id, x, y) or None."""
    cur.execute("""
        SELECT id, x, y FROM public.map_tiles
        WHERE owner_player_id = %s AND resource_node_key = %s
        LIMIT 1
    """, (str(player_id), resource_key))
    return cur.fetchone()


def test_cannot_build_on_resource_tile(make_player, place, cur):
    p = make_player(industry='timber')
    tile = _resource_tile_in_district(cur, p['id'], 'timber')
    assert tile is not None, "starter chunk should have at least one timber tile"
    tile_id, tx, ty = tile
    with pytest.raises(psycopg2.errors.RaiseException):
        place('house', tx, ty)


def test_clear_resource_tile_removes_resource(make_player, cur, as_user):
    p = make_player(industry='timber')
    tile = _resource_tile_in_district(cur, p['id'], 'timber')
    tile_id, tx, ty = tile
    as_user(p['id'])
    cur.execute("SELECT public.clear_resource_tile(%s)", (str(tile_id),))
    result = cur.fetchone()[0]
    assert result['cleared_resource'] == 'timber'
    cur.execute("SELECT resource_node_key FROM public.map_tiles WHERE id = %s", (str(tile_id),))
    assert cur.fetchone()[0] is None


def test_can_build_on_cleared_resource_tile(make_player, place, cur, as_user):
    """After clear_resource_tile, the player can build on that tile."""
    p = make_player(industry='timber')
    tile = _resource_tile_in_district(cur, p['id'], 'timber')
    tile_id, tx, ty = tile
    as_user(p['id'])
    cur.execute("SELECT public.clear_resource_tile(%s)", (str(tile_id),))
    # Now placement should succeed.
    result = place('house', tx, ty)
    assert 'building_id' in result


def test_clear_resource_tile_rejects_unowned(make_player, cur, as_user):
    """A player can't clear a resource on a tile they don't own."""
    p1 = make_player(industry='timber')
    p2 = make_player(industry='timber')
    # Find a resource tile owned by p1.
    tile = _resource_tile_in_district(cur, p1['id'], 'timber')
    tile_id, _, _ = tile
    as_user(p2['id'])
    with pytest.raises(psycopg2.errors.RaiseException):
        cur.execute("SELECT public.clear_resource_tile(%s)", (str(tile_id),))


def test_clear_resource_tile_rejects_no_resource(make_player, cur, as_user):
    """Trying to clear a tile that has no resource is an error."""
    p = make_player(industry='timber')
    # Pick the home tile — guaranteed no resource (city center clears it).
    cur.execute("""
        SELECT id FROM public.map_tiles
        WHERE owner_player_id = %s AND resource_node_key IS NULL
        LIMIT 1
    """, (str(p['id']),))
    tile_id = cur.fetchone()[0]
    as_user(p['id'])
    with pytest.raises(psycopg2.errors.RaiseException):
        cur.execute("SELECT public.clear_resource_tile(%s)", (str(tile_id),))
