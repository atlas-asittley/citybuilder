"""Named balance scenarios. Each one builds a specific city configuration,
runs N minutes, and reports key metrics.

Usage:
    python3 -m sandbox.scenarios            # run all scenarios
    python3 -m sandbox.scenarios <name>     # run one
"""
from __future__ import annotations
import sys
import copy

from sandbox.balance_sim import (
    City, run, BUILDING_DB, HOUSING_TIER_CFG,
    POP_FLOOR_NORMAL, IMMIGRATION_MAX_RATE,
)


# ─────────────────────────────────────────────────────────────
# Scenario helpers
# ─────────────────────────────────────────────────────────────

def starter_clay_city() -> City:
    """The standard tutorial output: 4 huts, 1 well, 1 garden, 1 clay_pit,
    clay set to sell_surplus, 24 starting workers."""
    c = City(industry='clay', start_money=1000) if False else City(industry='clay')
    c.money = 1000
    c.build('house', 4)         # tutorial advances to step 1
    c.build('well')             # step 2
    c.build('garden')           # step 3
    c.build('clay_pit')         # step 4 + trade_unlocked
    c.set_policy('clay', 'sell_surplus', reserve=0)
    return c


# ─────────────────────────────────────────────────────────────
# Scenarios
# ─────────────────────────────────────────────────────────────

def scenario_baseline_30min():
    """Baseline: standard tutorial output, run 30 minutes. Establishes
    'where does a default new player end up after their first half-hour'."""
    c = starter_clay_city()
    print(f"=== Baseline 30-min run ===")
    print(f"Starting state: pop={c.population}, money=${c.money}, step={c.tutorial_step}")
    result = run(c, minutes=30)
    print()
    print(result.summary())
    print()
    print(result.chart(('money', 'population', 'happiness', 'avg_tier', 'food_stock')))
    # Time-to-milestones
    t_50pop = result.time_to(lambda s: s['population'] >= 50)
    t_cottage = result.time_to(lambda s: s['avg_tier'] >= 2)
    t_first_trade = result.time_to(lambda s: s['trade_earned'] > 0)
    print()
    print(f"Time to 50 population:  {t_50pop} min" if t_50pop else "Did not reach 50 pop in 30min")
    print(f"Time to avg-Cottage:    {t_cottage} min" if t_cottage else "Did not reach Cottage in 30min")
    print(f"Time to first trade:    {t_first_trade} min" if t_first_trade else "No trade fired")


def scenario_time_to_watch_house():
    """How long from tutorial completion until the player has $300 + spare workers
    to staff a Watch House? Watch House costs $300 build + 5 workers + $15/min upkeep."""
    c = starter_clay_city()
    # Need $300 in money + 5 spare workers (capacity − used).
    print(f"=== Time-to-Watch-House (need $300 + 5 idle workers) ===")
    result = run(c, minutes=60)
    t = result.time_to(lambda s: s['money'] >= 300
                       and (s['workers_used'] + 5 <= s['workers_used'] + max(0, c.population - s['workers_used'])))
    if t is not None:
        print(f"Watch House becomes affordable at: {t} min")
    else:
        print(f"Did not reach in 60 min. Final state: ${result.city.money}, pop {result.city.population:.0f}")
    print()
    print(result.chart(('money', 'population', 'workers_used', 'trade_earned')))


def scenario_double_immigration():
    """How does doubling the immigration cap change the curve?"""
    import sandbox.balance_sim as bs
    print(f"=== Effect of doubling immigration rate ===")
    print(f"(default IMMIGRATION_MAX_RATE = {IMMIGRATION_MAX_RATE})")
    print()
    c1 = starter_clay_city()
    r1 = run(c1, minutes=30)
    print(f"Default rate: pop after 30min = {c1.population:.1f}")

    bs.IMMIGRATION_MAX_RATE = 8.0
    try:
        c2 = starter_clay_city()
        r2 = run(c2, minutes=30)
        print(f"2x rate:      pop after 30min = {c2.population:.1f}")
    finally:
        bs.IMMIGRATION_MAX_RATE = 4.0


def scenario_food_drain_high_tier():
    """A pop-100 city of 6 Cottages (tier 2) — does food production keep up?"""
    print(f"=== Food drain at higher housing tiers ===")
    c = City(industry='clay')
    c.money = 5000
    # Set tutorial done, big housing pool
    c.tutorial_step = 4
    c.trade_unlocked = True
    c.population = 100
    c.build('house', 6, tier=2, tutorial_force_tier=False)  # 6 Cottages
    c.build('well')
    c.build('garden', 2)
    c.build('clay_pit', 4)
    # Stock some food to start
    c.inventory['vegetables'] = 50
    c.set_policy('clay', 'sell_surplus', reserve=0)

    result = run(c, minutes=30)
    print(result.summary())
    print()
    print(result.chart(('money', 'population', 'food_stock', 'food_drained')))
    # Per-minute drain at 6 Cottages = 6 * 0.06 = 0.36/min.
    # 2 gardens producing 1.0/min each = 2.0/min.
    # Should be in surplus.


def scenario_pop_to_first_clay_pit_unstaffable():
    """For a player who builds many clay pits before housing scales,
    when do their later pits actually get staffed?"""
    print(f"=== Many clay pits, slow housing scale ===")
    c = starter_clay_city()
    # Player aggressively builds 4 more clay pits, 3 paused initially
    c.build('clay_pit', 3, status='paused')
    print(f"After scale-out: 4 active clay pits, 3 paused. Workers needed: 23 active.")
    result = run(c, minutes=60)
    print(result.summary())
    print()
    print(result.chart(('money', 'population', 'workers_used', 'workers_needed')))


# ─────────────────────────────────────────────────────────────
# Registry + runner
# ─────────────────────────────────────────────────────────────

SCENARIOS = {
    'baseline_30min':            scenario_baseline_30min,
    'time_to_watch_house':       scenario_time_to_watch_house,
    'double_immigration':        scenario_double_immigration,
    'food_drain_high_tier':      scenario_food_drain_high_tier,
    'pop_clay_pits':             scenario_pop_to_first_clay_pit_unstaffable,
}


def main():
    args = sys.argv[1:]
    if not args:
        for name, fn in SCENARIOS.items():
            print(f"\n{'='*65}\n{name}\n{'='*65}")
            fn()
        return
    for name in args:
        if name not in SCENARIOS:
            print(f"unknown scenario: {name!r}. Available: {list(SCENARIOS)}")
            continue
        SCENARIOS[name]()


if __name__ == '__main__':
    main()
