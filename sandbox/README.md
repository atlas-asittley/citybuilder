# Balance sandbox

Tools for testing balance changes without touching the live game.

## Two flavors

### `balance_sim.py` — pure-Python formula playground

Re-implements the core game math (immigration, food drain, worker
allocation, production, happiness, auto-trade) in plain Python.
Runs in milliseconds; sweep parameter space freely.

```python
from sandbox.balance_sim import City, run

city = City(industry='clay', start_money=1000)
# Build out a starter loadout and simulate 30 minutes:
city.build('house', count=4, tier=1)
city.build('well', count=1)
city.build('garden', count=1)
city.build('clay_pit', count=1)
result = run(city, minutes=30)
print(result.summary())
```

Edit `BUILDING_DB` / `HOUSING_TIER_CFG` / immigration constants at the
top of the file to test "what if X were 2× / 0.5×" without touching
the real DB.

**Tradeoff:** This is a *model* of the rules, not the rules themselves.
If you change something in the SQL, update `balance_sim.py` to match
or the model drifts. The `balance_sim_check.py` script (run via the
test suite) compares model output to a single DB-driven tick to keep
drift visible.

### `db_sim.py` — DB-driven simulation

Spins up a synthetic player in the live DB (inside a savepoint, so
nothing persists), places a known building loadout, then loops
`process_production` for N simulated 30s ticks by advancing
`last_population_tick_at` / `last_food_tick_at` / building
`last_processed_at` so the server thinks 30 seconds passed each call.

```python
from sandbox.db_sim import DBSim

with DBSim(industry='clay') as sim:
    sim.build('house', count=4)  # tutorial trigger auto-bumps tier 1
    sim.build('well')
    sim.build('garden')
    sim.build('clay_pit')
    result = sim.run(minutes=30)
    print(result.summary())
```

All math comes from the actual server functions, so results match
production. Slower than pure-Python (each tick is a real RPC call).
Use for high-confidence checks of specific scenarios.

## Scenarios

`sandbox/scenarios/` holds named experiments. Run one with:

```
python3 -m sandbox.run <scenario_name>
```

See `sandbox/scenarios/__init__.py` for the registered list.

## Design notes

- `balance_sim.py` reads its parameters from `params.py` so you can
  hot-swap them. `params_default.py` mirrors the live DB; copy it,
  edit, and pass to `City(params=...)` to test variants.
- Each tick is 30 seconds of game time. Run for N minutes = N*2 ticks.
- Immigration formula: `rate = ((happiness-50)/50) * v_max_rate` per minute,
  applied as `rate * elapsed_minutes` to population each tick.
- Food drain proportional to each housing tier's `food_per_minute`,
  deducted pro-rata across all foods in inventory.
- Trade auto-resolves on tick if cooldown elapsed; respects each
  resource's policy (keep / sell_surplus + reserve / buy_to_reserve).
