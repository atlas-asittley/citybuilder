# Crime & Police — Design

Status: **proposed**, in active implementation.
Last updated: 2026-05-05.

## Goals

1. **A real spatial mechanic.** Unlike happiness (which reads a per-player rollup), crime depends on whether each housing tile is *physically covered* by police. A sprawling district can have terrible crime even if every per-player metric is fine.
2. **Tiered police**. Three buildings: a cheap Watch House for early game, a mid Police Station, a top-tier Constabulary. Higher tier = wider coverage radius + more workers + more upkeep.
3. **Recurring upkeep.** Police buildings cost money *per tick* while active, not just at placement. Forces the player to actually maintain them.
4. **Crime softly degrades happiness.** v1 effect: high crime subtracts from happiness, which is already an emigration force. So a crime-ridden city slowly loses citizens. (Productivity / theft-event effects deferred.)

## Mechanics

### Crime number
Per-player `crime` numeric (0-100), stored on `player_profiles.crime`. Recomputed each tick by `_pp_update_crime`.

### Crime formula
```
crime = clamp(0, 100,
  10                                                  -- base
  + 4 × num_uncovered_active_houses                   -- main driver
  + LEAST(20, FLOOR(population / 10))                 -- size pressure
  + 1 × num_active_taverns                            -- crime-genre flavor
)
```

Notes:

- An "uncovered" house is one whose (x, y) is *not* within `coverage_radius` (Manhattan) of any active staffed police building. Pause / unstaff a PD and it stops covering.
- Taverns add a tiny pressure (1 each). City-builder genre trope; nudges the player to consider where they place them.
- The base of 10 keeps small healthy cities at low-but-not-zero crime so the meter is always visible.

### Police buildings

| Key | Display | $ build | Workers | Coverage | Upkeep $/min |
|---|---|---|---|---|---|
| `watch_house` | Watch House | 300 | 5 | 4 tiles | 5 |
| `police_station` | Police Station | 700 | 10 | 6 tiles | 12 |
| `constabulary` | Constabulary | 1500 | 15 | 8 tiles | 25 |

- New `police` category in `building_types`. Added to `_pp_workers_needed` and `_pp_staff_buildings` worker pools.
- All three need road access to staff (same rule as `service` / `tax`).
- Higher tiers gated by progressive housing unlock: Watch House always available, Police Station requires reaching housing tier 3, Constabulary tier 5.

### Upkeep
Every tick, `_pp_run_upkeep(uid, staffed_ids)` walks active staffed buildings whose `building_types.upkeep_per_minute > 0` and deducts `upkeep_per_minute × elapsed_minutes`. Logged as `cash_transactions` rows with `source = 'upkeep'`. Money can go negative — the player has to demolish or pause to stop the bleed.

For v1 only police have upkeep. Future buildings can opt in via the same column.

### Happiness integration
`compute_happiness` adds a single new term:

```
- FLOOR(crime / 5)         -- crime 50 → −10 happiness, crime 100 → −20
```

So crime indirectly drives emigration (the asymmetric population model only emigrates when happiness < 50).

### What's *deferred* (intentionally out of v1)
- Theft events (random tile gets robbed, money/inventory loss).
- Productivity effect (extractor/processor output × crime-multiplier).
- Crime per-house heatmap on the map.
- Police walkers on patrol routes.

## Schema

```sql
ALTER TABLE building_types
  ADD COLUMN coverage_radius integer NOT NULL DEFAULT 0,
  ADD COLUMN upkeep_per_minute integer NOT NULL DEFAULT 0;

ALTER TABLE player_profiles
  ADD COLUMN crime numeric NOT NULL DEFAULT 10;

-- Drop and recreate the category check to add 'police'.
ALTER TABLE building_types DROP CONSTRAINT building_types_category_check;
ALTER TABLE building_types ADD CONSTRAINT building_types_category_check
  CHECK (category IN ('extractor','processor','housing','road','service','tax',
                      'food_extractor','booster','police'));

-- Source check on cash_transactions extends to include 'upkeep'.
ALTER TABLE cash_transactions DROP CONSTRAINT cash_source_check;
ALTER TABLE cash_transactions ADD CONSTRAINT cash_source_check
  CHECK (source IN ('tax_revenue','build_cost','expansion_cost',
                    'starting_grant','demolish_refund','upkeep'));
```

Three new rows seeded into `building_types` for the police buildings.

## RPCs

- `compute_crime(uid)` → numeric (0..100). Stable, recomputes from current state.
- `_pp_update_crime(uid)` → void. Writes the new crime value to `player_profiles.crime`.
- `_pp_run_upkeep(uid, staffed_ids)` → integer (total deducted). Walks active staffed upkeep-bearing buildings.
- Updated `compute_happiness` includes the `−FLOOR(crime/5)` penalty.
- Updated `_pp_workers_needed` and `_pp_staff_buildings` add `'police'` to their category list.
- Updated `process_production` orchestrator calls `_pp_update_crime` and `_pp_run_upkeep` in their right places.

## UI

- New topbar indicator: small badge `🚨 N` showing crime number. Color-coded (green ≤ 25, amber 26..50, red > 50).
- Build panel: police buildings get a `🚨` icon fallback color and a description of their coverage radius + upkeep.
- Inspector: police buildings show their coverage + upkeep facts.

For v1 sprites are letter labels (WH / PS / CB) with a navy color tile — proper SVG sprites will follow in graphics polish.

## Tests

1. Crime starts at base (10) for a fresh player.
2. Adding an uncovered house raises crime by 4.
3. Adding a Watch House adjacent drops the house out of "uncovered" → crime goes back down.
4. Police Station has wider coverage than Watch House (6 vs 4 tiles).
5. Population scales the size-pressure term.
6. High crime reduces happiness via the integration term.
7. Active police building deducts `upkeep_per_minute` per tick and logs an `upkeep` row in cash_transactions.
8. Police building gets shut out of staffing when worker_capacity < total worker_cost (proves it's in the worker pool).
