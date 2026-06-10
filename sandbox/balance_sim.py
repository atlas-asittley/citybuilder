"""Pure-Python game simulator for fast balance experiments.

Models the core economy at 30-second tick resolution. Mirrors the
server's process_production phase order: population → staffing →
production → services → tax → upkeep → food drain → housing
evolution → trade resolution → happiness recompute.

This is a MODEL, not the rules themselves. When in doubt, the SQL
in /city-builder-mvp/migration_patches/*.sql is authoritative; this
file should track those changes. The companion `db_sim.py` runs the
real RPCs against a sandbox player for high-fidelity validation.
"""
from __future__ import annotations
from dataclasses import dataclass, field
from typing import Optional
import copy
import math

# ─────────────────────────────────────────────────────────────
# Game constants — edit these to experiment with rebalancing.
# ─────────────────────────────────────────────────────────────

POP_FLOOR_TUTORIAL = 0     # population floor while tutorial_step < 4
POP_FLOOR_NORMAL = 15      # post-tutorial floor
IMMIGRATION_MAX_RATE = 4.0  # citizens / minute at max happiness curve
HAPPINESS_GROWTH_THRESHOLD = 50

TICK_SECONDS = 30
TICKS_PER_MINUTE = 60 / TICK_SECONDS

# Trader visit interval (river_traders) and capacity. Other traders
# are similar; see params.py for the full set.
RIVER_TRADER_INTERVAL_MIN = 10
RIVER_TRADER_CAPACITY = 20

# Housing tier config: workers, food_per_minute, prereqs.
HOUSING_TIER_CFG = {
    0: {'name': 'Shanty',       'workers': 2,  'food_per_minute': 0,    'upgrade_secs': 30,
        'needs_road': False, 'needs_well': False, 'needs_food': False},
    1: {'name': 'Mud Hut',      'workers': 6,  'food_per_minute': 0,    'upgrade_secs': 30,
        'needs_road': False, 'needs_well': True,  'needs_food': False},
    2: {'name': 'Cottage',      'workers': 10, 'food_per_minute': 0.06, 'upgrade_secs': 60,
        'needs_road': False, 'needs_well': True,  'needs_food': True},
    3: {'name': 'Townhouse',    'workers': 16, 'food_per_minute': 0.10, 'upgrade_secs': 120,
        'needs_road': True,  'needs_well': True,  'needs_food': True},
    4: {'name': 'Villa',        'workers': 24, 'food_per_minute': 0.15, 'upgrade_secs': 180,
        'needs_road': True,  'needs_well': True,  'needs_food': True},
    5: {'name': 'Manor Estate', 'workers': 34, 'food_per_minute': 0.25, 'upgrade_secs': 300,
        'needs_road': True,  'needs_well': True,  'needs_food': True},
    6: {'name': 'Mansion',      'workers': 50, 'food_per_minute': 0.40, 'upgrade_secs': 480,
        'needs_road': True,  'needs_well': True,  'needs_food': True},
    7: {'name': 'Estate',       'workers': 70, 'food_per_minute': 0.60, 'upgrade_secs': 720,
        'needs_road': True,  'needs_well': True,  'needs_food': True},
    8: {'name': 'Palace',       'workers': 100, 'food_per_minute': 0.90,'upgrade_secs': 1200,
        'needs_road': True,  'needs_well': True,  'needs_food': True},
}

# Building catalog — only the early-game subset that matters for the
# core balance scenarios. Add more as needed.
BUILDING_DB = {
    # (key): (build_cost, worker_cost, category, output_resource, output_rate, notes)
    'house':        {'cost': 60,   'worker_cost': 0,  'category': 'housing'},
    'road':         {'cost': 5,    'worker_cost': 0,  'category': 'road'},
    'well':         {'cost': 50,   'worker_cost': 3,  'category': 'service'},
    # Food extractors (industry-paired)
    'orchard':      {'cost': 150,  'worker_cost': 10, 'category': 'food_extractor', 'output': 'berries',    'rate': 1.0, 'industry': 'timber'},
    'fishing_pier': {'cost': 150,  'worker_cost': 10, 'category': 'food_extractor', 'output': 'fish',       'rate': 1.0, 'industry': 'stone'},
    'garden':       {'cost': 150,  'worker_cost': 10, 'category': 'food_extractor', 'output': 'vegetables', 'rate': 1.0, 'industry': 'clay'},
    'grain_farm':   {'cost': 150,  'worker_cost': 10, 'category': 'food_extractor', 'output': 'grain',      'rate': 1.0, 'industry': 'iron'},
    # Resource extractors
    'timber_camp':  {'cost': 100,  'worker_cost': 10, 'category': 'extractor', 'output': 'timber', 'rate': 1.0, 'industry': 'timber'},
    'stone_quarry': {'cost': 100,  'worker_cost': 10, 'category': 'extractor', 'output': 'stone',  'rate': 1.0, 'industry': 'stone'},
    'clay_pit':     {'cost': 120,  'worker_cost': 10, 'category': 'extractor', 'output': 'clay',   'rate': 1.5, 'industry': 'clay'},
    'iron_mine':    {'cost': 100,  'worker_cost': 10, 'category': 'extractor', 'output': 'iron',   'rate': 1.0, 'industry': 'iron'},
    # Police (upkeep example)
    'watch_house':  {'cost': 300,  'worker_cost': 5,  'category': 'police',   'upkeep': 15},
    # Tax
    'tax_man':      {'cost': 300,  'worker_cost': 10, 'category': 'tax',      'rate': 10},
}

# River_Traders price table for sell_surplus auto-trade.
RIVER_TRADER_PRICES = {
    'timber':    {'buy': 4},   # they BUY (player sells) at this price
    'stone':     {'buy': 5},
    'clay':      {'buy': 3},
    'grain':     {'buy': 3},
    'bread':     {'buy': 12},
    'furniture': {'buy': 14},
    'statuary':  {'buy': 14},
}

FOODS = {'berries', 'fish', 'vegetables', 'grain', 'flour', 'bread', 'wine',
         'smoked_fish', 'preserves', 'spirits', 'caviar', 'spices', 'ale'}

# ─────────────────────────────────────────────────────────────


@dataclass
class Building:
    key: str
    tier: int = 0          # only used for housing
    status: str = 'active'  # 'active' or 'paused'
    is_staffed: bool = False
    last_processed_min: float = 0  # sim time of last tier change (for upgrade_secs gate)


@dataclass
class TradePolicy:
    mode: str = 'keep'       # 'keep' | 'sell_surplus' | 'buy_to_reserve'
    reserve: int = 0


@dataclass
class City:
    """Mutable game state for one player. Mirrors the per-player
    fields that process_production reads + writes."""
    industry: str = 'timber'
    money: int = 1000
    population: float = 0.0
    happiness: float = 50.0
    crime: float = 10.0
    tutorial_step: int = 0
    trade_unlocked: bool = False
    buildings: list[Building] = field(default_factory=list)
    inventory: dict[str, float] = field(default_factory=dict)
    policies: dict[str, TradePolicy] = field(default_factory=dict)
    # Trader cooldowns: minutes elapsed since last visit per trader.
    trader_last_visit_min: dict[str, float] = field(default_factory=dict)
    # Telemetry — populated by run().
    history: list[dict] = field(default_factory=list)

    # ── Build helpers ──
    def build(self, key: str, count: int = 1, tier: int = 0,
              status: str = 'active', tutorial_force_tier: bool = True):
        """Place `count` buildings of `key`. For housing during tutorial
        step 0, auto-bumps tier to 1 (same as the SQL trigger)."""
        spec = BUILDING_DB[key]
        for _ in range(count):
            actual_tier = tier
            if (spec['category'] == 'housing'
                    and tutorial_force_tier
                    and self.tutorial_step == 0):
                actual_tier = 1
            self.buildings.append(Building(
                key=key, tier=actual_tier, status=status))
            self.money -= spec['cost']
        # Tutorial advancement (mirrors the SQL trigger).
        cat = spec['category']
        if self.tutorial_step == 0 and cat == 'housing':
            n_houses = sum(1 for b in self.buildings
                           if BUILDING_DB[b.key]['category'] == 'housing'
                           and b.status == 'active')
            if n_houses >= 4:
                self.tutorial_step = 1
            # Snap pop to housing supply during tutorial step 0.
            self.population = max(self.population, self._housing_supply())
        elif self.tutorial_step == 1 and key == 'well':
            self.tutorial_step = 2
        elif self.tutorial_step == 2 and cat == 'food_extractor':
            self.tutorial_step = 3
        elif self.tutorial_step == 3 and cat == 'extractor':
            self.tutorial_step = 4
            self.trade_unlocked = True
        return self

    def set_policy(self, resource: str, mode: str, reserve: int = 0):
        self.policies[resource] = TradePolicy(mode=mode, reserve=reserve)
        return self

    # ── Derived state ──
    def _in_tutorial(self) -> bool:
        return self.tutorial_step < 4

    def _housing_supply(self) -> int:
        """Sum of housing capacity. Skips well requirement during tutorial."""
        total = 0
        in_tutorial = self._in_tutorial()
        for b in self.buildings:
            if BUILDING_DB[b.key]['category'] != 'housing':
                continue
            if b.status != 'active':
                continue
            cfg = HOUSING_TIER_CFG[b.tier]
            # Mirrors _pp_housing_supply: needs_road check is lenient
            # (assume road for the model — if you want to test road
            # gating, set b.tier higher and it'll surface). needs_well
            # bypass during tutorial.
            if cfg['needs_well'] and not in_tutorial:
                if not any(b2.key == 'well' and b2.status == 'active'
                           for b2 in self.buildings):
                    continue
            total += cfg['workers']
        return total

    def _worker_supply(self) -> int:
        """floor(population) + tavern_bonus. We don't model taverns yet."""
        return int(math.floor(self.population))

    def _foods_in_stock(self) -> int:
        return sum(1 for k, v in self.inventory.items() if k in FOODS and v > 0)

    def _has_food(self) -> bool:
        return any(v > 0 for k, v in self.inventory.items() if k in FOODS)

    # ── Per-tick phases ──
    def _phase_population(self, dt_min: float):
        """Mirrors _pp_update_population."""
        floor = POP_FLOOR_TUTORIAL if self._in_tutorial() else POP_FLOOR_NORMAL
        target = floor + self._housing_supply()
        if self.population > target:
            self.population = float(target)
        elif self.population < floor:
            rate = IMMIGRATION_MAX_RATE
            self.population = min(floor, self.population + rate * dt_min)
        elif self.population < target and self.happiness >= HAPPINESS_GROWTH_THRESHOLD:
            rate = ((self.happiness - 50) / 50) * IMMIGRATION_MAX_RATE
            self.population = min(target, self.population + rate * dt_min)
        elif self.happiness < HAPPINESS_GROWTH_THRESHOLD and self.population > floor:
            rate = -((50 - self.happiness) / 50) * IMMIGRATION_MAX_RATE
            self.population = max(floor, self.population + rate * dt_min)

    def _phase_staffing(self):
        """Greedy worker allocation, services first like _pp_staff_buildings.
        Sets is_staffed on each building. Returns workers_used + workers_needed."""
        supply = self._worker_supply()
        remaining = supply
        used = 0
        needed = 0
        # Reset all
        for b in self.buildings:
            b.is_staffed = False
        # Order: services + police priority bonus, then by created order.
        def category_priority(b):
            cat = BUILDING_DB[b.key]['category']
            return 2 if cat in ('service', 'police') else 1
        prod_buildings = [b for b in self.buildings
                          if BUILDING_DB[b.key]['category']
                          in ('extractor', 'food_extractor', 'processor',
                              'service', 'tax', 'booster', 'police')
                          and b.status == 'active']
        prod_buildings.sort(key=lambda b: -category_priority(b))
        for b in prod_buildings:
            cost = BUILDING_DB[b.key]['worker_cost']
            needed += cost
            if remaining >= cost:
                remaining -= cost
                used += cost
                b.is_staffed = True
        return used, needed

    def _phase_extractors(self, dt_min: float):
        """Run staffed extractors and food_extractors."""
        for b in self.buildings:
            spec = BUILDING_DB[b.key]
            if spec['category'] not in ('extractor', 'food_extractor'):
                continue
            if not b.is_staffed:
                continue
            output = spec['output']
            self.inventory[output] = self.inventory.get(output, 0) + spec['rate'] * dt_min

    def _phase_tax(self, dt_min: float):
        income = 0
        for b in self.buildings:
            spec = BUILDING_DB[b.key]
            if spec['category'] != 'tax' or not b.is_staffed:
                continue
            income += spec['rate'] * dt_min
        self.money += income
        return income

    def _phase_upkeep(self, dt_min: float):
        cost = 0
        for b in self.buildings:
            spec = BUILDING_DB[b.key]
            upkeep = spec.get('upkeep', 0)
            if upkeep == 0 or not b.is_staffed:
                continue
            cost += upkeep * dt_min
        self.money -= cost
        return cost

    def _phase_food_drain(self, dt_min: float):
        """Drain food pro-rata across all food types."""
        rate = sum(HOUSING_TIER_CFG[b.tier]['food_per_minute']
                   for b in self.buildings
                   if BUILDING_DB[b.key]['category'] == 'housing'
                   and b.status == 'active')
        needed = rate * dt_min
        if needed <= 0:
            return 0
        avail = sum(v for k, v in self.inventory.items() if k in FOODS)
        if avail <= 0:
            return 0
        drain = min(needed, avail)
        factor = 1 - (drain / avail)
        for k in list(self.inventory.keys()):
            if k in FOODS:
                self.inventory[k] *= factor
        return drain

    def _phase_evolve_housing(self, dt_min: float):
        """Housing evolves UP if prereqs met AND elapsed >= upgrade_secs
        of the CURRENT tier (mirrors _pp_evolve_housing). In tutorial
        tier-1 stays put — devolution skipped, upgrade gated by needs_food
        which won't be true at step 0/1."""
        in_tutorial = self._in_tutorial()
        now_min = self.history[-1]['total_min'] + dt_min if self.history else dt_min
        for b in self.buildings:
            if BUILDING_DB[b.key]['category'] != 'housing':
                continue
            cur_cfg = HOUSING_TIER_CFG[b.tier]
            elapsed_secs = (now_min - b.last_processed_min) * 60
            if elapsed_secs < cur_cfg.get('upgrade_secs', 60):
                continue
            next_tier = b.tier + 1
            if next_tier not in HOUSING_TIER_CFG:
                continue
            cfg_next = HOUSING_TIER_CFG[next_tier]
            has_well = any(b2.key == 'well' and b2.status == 'active'
                           for b2 in self.buildings)
            if cfg_next['needs_well'] and not has_well:
                continue
            if cfg_next['needs_food'] and not self._has_food():
                continue
            b.tier = next_tier
            b.last_processed_min = now_min

    def _phase_trade(self, dt_min: float):
        """Auto-resolve River Traders if cooldown elapsed. Sells via
        sell_surplus policies."""
        if not self.trade_unlocked:
            return 0
        last = self.trader_last_visit_min.get('river_traders', -RIVER_TRADER_INTERVAL_MIN)
        # Wall-clock time (in sim) since start; use total_min from history.
        now = self.history[-1]['total_min'] + dt_min if self.history else dt_min
        if now - last < RIVER_TRADER_INTERVAL_MIN:
            return 0
        # Visit due. Run sell phase.
        capacity = RIVER_TRADER_CAPACITY
        earned = 0
        for resource, policy in self.policies.items():
            if policy.mode != 'sell_surplus':
                continue
            price_info = RIVER_TRADER_PRICES.get(resource)
            if not price_info or 'buy' not in price_info:
                continue
            stock = self.inventory.get(resource, 0)
            available = max(0, stock - policy.reserve)
            sell_qty = int(min(available, capacity))
            if sell_qty <= 0:
                continue
            earned += sell_qty * price_info['buy']
            self.inventory[resource] = stock - sell_qty
            capacity -= sell_qty
            if capacity <= 0:
                break
        self.money += earned
        self.trader_last_visit_min['river_traders'] = now
        return earned

    def _phase_happiness(self):
        """Mirrors compute_happiness — base + services + tier + food + staffing - crime."""
        base = 30
        services = 0
        # Well counts as +1 service if road-adjacent (assume yes in model).
        if any(b.key == 'well' and b.status == 'active' for b in self.buildings):
            services += 1
        # Other services would add but we don't model their input feeding.
        food_variety = self._foods_in_stock()
        avg_tier = 0
        houses = [b for b in self.buildings
                  if BUILDING_DB[b.key]['category'] == 'housing'
                  and b.status == 'active']
        if houses:
            avg_tier = sum(b.tier for b in houses) / len(houses)
        # Staffing ratio
        used, needed = self._compute_staffing_metrics()
        staffing_ratio = min(1.0, used / needed) if needed > 0 else 1.0
        crime_penalty = math.floor(self.crime / 5)
        score = (base
                 + 3 * services
                 + 2 * avg_tier
                 + min(15, food_variety * 2)
                 + 20 * staffing_ratio
                 - crime_penalty)
        self.happiness = max(0, min(100, score))

    def _compute_staffing_metrics(self):
        used = sum(BUILDING_DB[b.key]['worker_cost']
                   for b in self.buildings
                   if b.is_staffed)
        needed = sum(BUILDING_DB[b.key]['worker_cost']
                     for b in self.buildings
                     if b.status == 'active'
                     and BUILDING_DB[b.key]['category']
                     in ('extractor', 'food_extractor', 'processor',
                         'service', 'tax', 'booster', 'police'))
        return used, needed

    # ── Per-tick driver ──
    def tick(self, dt_min: float = 0.5):
        """One tick = TICK_SECONDS (default 30s = 0.5 min)."""
        self._phase_population(dt_min)
        used, needed = self._phase_staffing()
        self._phase_extractors(dt_min)
        income = self._phase_tax(dt_min)
        upkeep = self._phase_upkeep(dt_min)
        drained = self._phase_food_drain(dt_min)
        self._phase_evolve_housing(dt_min)
        trade_earned = self._phase_trade(dt_min)
        self._phase_happiness()

        prev_total = self.history[-1]['total_min'] if self.history else 0
        self.history.append({
            'total_min': prev_total + dt_min,
            'money': self.money,
            'population': round(self.population, 2),
            'happiness': round(self.happiness, 1),
            'crime': self.crime,
            'workers_used': used,
            'workers_needed': needed,
            'food_stock': round(sum(v for k, v in self.inventory.items() if k in FOODS), 2),
            'income': round(income, 2),
            'upkeep': round(upkeep, 2),
            'food_drained': round(drained, 2),
            'trade_earned': trade_earned,
            'tutorial_step': self.tutorial_step,
            'avg_tier': round(sum(b.tier for b in self.buildings
                                  if BUILDING_DB[b.key]['category'] == 'housing'
                                  and b.status == 'active') /
                              max(1, sum(1 for b in self.buildings
                                         if BUILDING_DB[b.key]['category'] == 'housing'
                                         and b.status == 'active')), 2),
        })


def run(city: City, minutes: int = 30, dt_min: float = 0.5) -> 'Result':
    """Simulate `minutes` of game time at TICK_SECONDS (=dt_min*60) granularity."""
    n_ticks = int(minutes / dt_min)
    for _ in range(n_ticks):
        city.tick(dt_min)
    return Result(city)


@dataclass
class Result:
    city: City

    def summary(self) -> str:
        c = self.city
        h = c.history[-1] if c.history else {}
        return (f"After {h.get('total_min', 0):.1f} min:\n"
                f"  money:        ${c.money:.0f}\n"
                f"  population:   {c.population:.1f}\n"
                f"  happiness:    {c.happiness:.1f}\n"
                f"  crime:        {c.crime:.1f}\n"
                f"  workers:      {h.get('workers_used',0)}/{h.get('workers_needed',0)}\n"
                f"  food stock:   {h.get('food_stock', 0):.1f}\n"
                f"  avg tier:     {h.get('avg_tier', 0):.1f}\n"
                f"  tutorial:     step {c.tutorial_step}\n"
                f"  trade open:   {c.trade_unlocked}\n"
                f"  inventory:    {dict((k, round(v,1)) for k,v in c.inventory.items() if v >= 1)}")

    def time_to(self, predicate, default=None):
        """Find the first tick at which predicate(snapshot) is true.
        Returns the total_min of that snapshot, or `default`."""
        for snap in self.city.history:
            if predicate(snap):
                return snap['total_min']
        return default

    def chart(self, fields=('money', 'population', 'happiness', 'food_stock')):
        """Return a simple text chart for inspection."""
        if not self.city.history:
            return '(empty)'
        lines = []
        header = f"{'min':>6} | " + ' | '.join(f"{f:>10}" for f in fields)
        lines.append(header)
        lines.append('-' * len(header))
        for i, snap in enumerate(self.city.history):
            if i % max(1, len(self.city.history) // 25) != 0:
                continue  # downsample for readability
            row = f"{snap['total_min']:>6.1f} | " + ' | '.join(
                f"{snap.get(f, 0):>10.1f}" if isinstance(snap.get(f, 0), (int, float))
                else f"{snap.get(f, 0):>10}" for f in fields)
            lines.append(row)
        return '\n'.join(lines)
