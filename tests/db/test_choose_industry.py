"""Tests for the `choose_industry` RPC.

Regression coverage: this RPC originally only allowed 'timber' and
'stone' even though grain and clay industries existed. M1's migration
fixed the validator to accept all four. These tests pin that behavior.
"""
import pytest
import psycopg2


def test_creates_player_with_district(make_player):
    p = make_player(industry='timber')
    assert p['industry_key'] == 'timber'
    assert p['money'] == 2000  # bumped 500 → 1000 (2026-05-06) → 2000 (2026-05-10)
    assert p['chunks_owned'] == 1
    assert p['home_x'] is not None
    assert p['home_y'] is not None


def test_starting_chunk_has_resource_tiles(make_player, cur):
    p = make_player(industry='timber')
    cur.execute("""
        SELECT COUNT(*) FROM public.map_tiles
        WHERE owner_player_id = %s AND resource_node_key = 'timber'
    """, (str(p['id']),))
    n = cur.fetchone()[0]
    # Post-scarcity-pass: starter chunk seeds 2 industry clusters of
    # U(2,5) steps each. Random walks can overlap themselves, so the
    # observed count varies from ~3 (heavy doubling-back) to ~10.
    assert 3 <= n <= 25, f"unexpected resource tile count: {n}"


def test_total_tiles_in_chunk_is_225(make_player, cur):
    p = make_player()
    cur.execute(
        "SELECT COUNT(*) FROM public.map_tiles WHERE owner_player_id = %s",
        (str(p['id']),),
    )
    assert cur.fetchone()[0] == 225


@pytest.mark.parametrize("industry", ['timber', 'stone', 'iron', 'clay'])
def test_accepts_all_four_industries(make_player, industry):
    """Regression: choose_industry used to only accept ('timber', 'stone').
    Then accepted ('timber', 'stone', 'grain', 'clay'). Then grain was
    reclassified as a food only, replaced by iron as the 4th industry."""
    p = make_player(industry=industry)
    assert p['industry_key'] == industry


def test_rejects_unknown_industry(make_player):
    with pytest.raises(psycopg2.errors.RaiseException):
        make_player(industry='nonsense')


def test_rejects_legacy_grain_industry(make_player):
    """Grain was an industry option pre-2026-05; now it's a food only."""
    with pytest.raises(psycopg2.errors.RaiseException):
        make_player(industry='grain')


def test_rejects_short_display_name(make_player):
    with pytest.raises(psycopg2.errors.RaiseException):
        make_player(display_name='x')
