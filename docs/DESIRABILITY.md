# Desirability

Per-tile attractiveness score. Collapses pollution + crime + tax + service coverage into one 0–100 number that determines (eventually) what tier of housing a tile can support.

Status: **shipped 2026-05-06 as visible-but-toothless.** Score is computed, shown in the housing inspector, and rendered as a heatmap. The actual gate on `_pp_evolve_housing` is populated in `housing_tier_config.min_desirability` but **not yet flipped on**.

## Formula

```
city_base   = 50
            + min(10, food_variety_count × 2)        ; +2 per distinct food in stock
            - min(20, max(0, floor((crime - 30)/10) × 2))   ; -2 per 10 crime above 30
            - min(15, tax_count × 3)                 ; -3 per Tax Office

per_tile    = city_base
            - min(30, pollution_on_this_tile)        ; pollution penalty per-tile
            + sum of services within range           ; well/school/temple/bathhouse +5
                                                       tavern +3, stacks per instance

desirability = clamp(per_tile, 0..100)
```

Service ranges (Manhattan distance, must be `is_staffed`):
- well: 4
- bathhouse: 4
- school: 5
- temple: 6
- tavern: 4

## Tier thresholds

`housing_tier_config.min_desirability` (column populated, gate not flipped):

| Tier | Name | min_desirability |
|---|---|---|
| 0 | Shanty | 0 |
| 1 | Mud Hut | 25 |
| 2 | Cottage | 40 |
| 3 | Townhouse | 50 |
| 4 | Villa | 60 |
| 5 | Manor | 70 |
| 6 | Mansion | 80 |
| 7 | Estate | 88 |
| 8 | Palace | 94 |

Calibration (post-migration, 2026-05-06): Atlas's tier 3-4 housing scored 50–54 desirability — would just qualify for current tiers when v2 gate fires, can't yet upgrade to Manor without more services or fewer polluting buildings nearby.

## v2: the housing gate (deferred)

Designed but not flipped:
- **Upgrade gate**: house can only evolve to tier T+1 if `desirability ≥ housing_tier_config[T+1].min_desirability`.
- **Devolve gate**: house devolves toward tier T-1 when `desirability < housing_tier_config[T].min_desirability − 15` (15-point hysteresis to avoid flapping).
- Existing service/road/food gates stay — desirability is an ADDITIONAL constraint, not a replacement.

Why deferred: Atlas's tier-4 houses average 54 desirability today. Flipping the gate with `min_desirability = 60` would mass-devolve them on the first tick. The score needs to be visible long enough for players to react (build parks, more services, lower pollution) before the gate fires.

## Visibility

- **Inspector row** on housing buildings: "Desirability: 72/100" plus a hint line — "qualifies for Villa — Manor needs 70".
- **Heatmap mode "Desirability"** — green-to-red gradient on every owned tile. Two stacked box-shadow tints:
  ```css
  body.heatmap-desirability .cell {
    box-shadow:
      inset 0 0 0 9999px rgba(94, 196, 158, calc(var(--desirability, 50) * 0.0035)),
      inset 0 0 0 9999px rgba(224, 80, 80, calc((100 - var(--desirability, 50)) * 0.0028));
  }
  ```
- Live refresh via `refreshTileMetrics()` after each production tick.

## Tunables

If thresholds feel wrong:
- Edit `housing_tier_config.min_desirability` rows directly (no migration needed).
- Or rebalance the formula in `_pp_update_desirability` — service weights, pollution penalty cap, food variety bonus.

## Related

- `migration_patches/desirability_v1.sql`
- `_pp_update_desirability(uid)` — compute helper
- `docs/POLLUTION.md` — biggest input
- `docs/CRIME.md` — second-biggest input
- `memory/project_metric_stack.md` — how the four metrics interact
