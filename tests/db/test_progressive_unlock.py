"""Tests for progressive building unlock by housing tier.

Coverage:
- Building_types are seeded with the expected `unlocks_at_housing_tier`
  values for the gate buildings (school / temple / luxury foods /
  industrial-luxury T4 cross-recipes).
- A player with highest_housing_tier_ever below the threshold cannot
  place a gated building — server raises an exception.
- Bumping the watermark unlocks placement.
"""
import pytest
import psycopg2


def test_unlock_thresholds_seeded(cur):
    """Migration sets the right thresholds for known gate buildings."""
    expected = {
        'school': 3,
        'temple': 4,
        'distillery': 5, 'curing_house': 5, 'spicery': 5, 'brewery': 5,
        'cabinetmaker': 6, 'architect': 6, 'mosaic_workshop': 6, 'engineer_workshop': 6,
    }
    keys = list(expected.keys())
    cur.execute("""
        SELECT key, unlocks_at_housing_tier
        FROM public.building_types
        WHERE key = ANY(%s)
        ORDER BY key
    """, (keys,))
    rows = dict(cur.fetchall())
    for k, tier in expected.items():
        assert rows.get(k) == tier, f'expected {k} unlocks at {tier}, got {rows.get(k)}'


def test_well_remains_always_available(cur):
    """Well, food extractors, road shouldn't be gated — they're early-game basics."""
    cur.execute("""
        SELECT unlocks_at_housing_tier FROM public.building_types
        WHERE key IN ('well', 'road', 'house', 'orchard', 'fishing_pier', 'garden', 'grain_farm')
        ORDER BY key
    """)
    for (tier,) in cur.fetchall():
        assert tier is None, f'expected always-available, got tier={tier}'


def test_player_starts_with_zero_watermark(make_player, cur):
    p = make_player(industry='timber', unlock_all=False)
    cur.execute("SELECT highest_housing_tier_ever FROM public.player_profiles WHERE id = %s",
                (str(p['id']),))
    assert cur.fetchone()[0] == 0


def test_school_locked_at_game_start(make_player, place, cur, clear_resources):
    """A fresh player can't place a school — they need a tier-3 house first."""
    p = make_player(unlock_all=False)
    clear_resources(p['id'])
    hx, hy = p['home_x'], p['home_y']
    place('road', hx + 1, hy + 1)
    with pytest.raises(psycopg2.errors.RaiseException, match='Locked'):
        place('school', hx + 2, hy + 1)


def test_school_unlocks_after_watermark_reaches_3(make_player, place, cur, clear_resources):
    """Once the player's highest_housing_tier_ever reaches 3, school can be placed."""
    p = make_player()
    clear_resources(p['id'])
    cur.execute("""
        UPDATE public.player_profiles
        SET highest_housing_tier_ever = 3, money = 5000
        WHERE id = %s
    """, (str(p['id']),))
    hx, hy = p['home_x'], p['home_y']
    place('road', hx + 1, hy + 1)
    result = place('school', hx + 2, hy + 1)
    assert 'building_id' in result


def test_temple_still_locked_when_school_unlocked(make_player, place, cur, clear_resources):
    """Watermark of 3 unlocks school but not temple — granular gates."""
    p = make_player(unlock_all=False)
    clear_resources(p['id'])
    cur.execute("""
        UPDATE public.player_profiles
        SET highest_housing_tier_ever = 3, money = 5000
        WHERE id = %s
    """, (str(p['id']),))
    hx, hy = p['home_x'], p['home_y']
    place('road', hx + 1, hy + 1)
    with pytest.raises(psycopg2.errors.RaiseException, match='Locked'):
        place('temple', hx + 3, hy + 1)
