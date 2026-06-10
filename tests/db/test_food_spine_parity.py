"""Parity invariants for the industry building tree.

These pin the design-codex rule that every industry fills the same slots.
Added 2026-06-10 alongside the food-spine symmetry fix (db/migrations/
food_spine_symmetry.sql), which gave timber/stone/clay a staple-food
building (Cookhouse/Galley/Pottage House) parallel to iron's Bakery.
"""

INDUSTRIES = ('timber', 'stone', 'clay', 'iron')


def test_all_industries_have_equal_building_count(cur):
    cur.execute(
        """SELECT industry_key, COUNT(*) FROM building_types
           WHERE is_active AND industry_key = ANY(%s)
           GROUP BY industry_key""",
        (list(INDUSTRIES),),
    )
    counts = dict(cur.fetchall())
    assert set(counts) == set(INDUSTRIES), f"missing an industry: {counts}"
    assert len(set(counts.values())) == 1, f"industry building counts differ: {counts}"


def test_each_industry_has_a_staple_food_building(cur):
    # A tier-3 processor whose output is a basic (non-luxury) food — i.e.
    # iron's Bakery and its three new parallels.
    cur.execute(
        """SELECT bt.industry_key
           FROM building_types bt
           JOIN resources r ON r.key = bt.output_resource_key
           WHERE bt.is_active AND bt.category = 'processor' AND bt.tier = 3
             AND r.is_food AND NOT r.is_luxury_food
             AND bt.industry_key = ANY(%s)""",
        (list(INDUSTRIES),),
    )
    found = {row[0] for row in cur.fetchall()}
    assert found == set(INDUSTRIES), f"industries missing a staple-food building: {set(INDUSTRIES) - found}"


def test_new_staple_foods_are_basic_foods(cur):
    cur.execute(
        """SELECT key FROM resources
           WHERE key = ANY(%s) AND is_active AND is_food AND NOT is_luxury_food""",
        (['stew', 'chowder', 'pottage'],),
    )
    assert {row[0] for row in cur.fetchall()} == {'stew', 'chowder', 'pottage'}


def test_each_industry_has_exactly_one_luxury_food(cur):
    cur.execute(
        """SELECT bt.industry_key, COUNT(*)
           FROM building_types bt
           JOIN resources r ON r.key = bt.output_resource_key
           WHERE bt.is_active AND r.is_luxury_food AND bt.industry_key = ANY(%s)
           GROUP BY bt.industry_key""",
        (list(INDUSTRIES),),
    )
    counts = dict(cur.fetchall())
    assert counts == {k: 1 for k in INDUSTRIES}, f"luxury-food building count off: {counts}"


def test_each_industry_can_self_satisfy_the_staple_demand(cur):
    # The universal housing "staple" lifestyle demand is keyed as 'bread';
    # lifestyle_substitutes lists the other acceptable goods. Every industry
    # must be able to produce at least one acceptable staple itself — so no
    # one depends on another industry just to feed its own housing.
    cur.execute("SELECT substitute_key FROM lifestyle_substitutes WHERE primary_key = 'bread'")
    acceptable = {row[0] for row in cur.fetchall()} | {'bread'}
    cur.execute(
        """SELECT DISTINCT industry_key FROM building_types
           WHERE is_active AND output_resource_key = ANY(%s) AND industry_key = ANY(%s)""",
        (list(acceptable), list(INDUSTRIES)),
    )
    self_sufficient = {row[0] for row in cur.fetchall()}
    assert self_sufficient == set(INDUSTRIES), \
        f"industries that can't self-satisfy the staple demand: {set(INDUSTRIES) - self_sufficient}"
