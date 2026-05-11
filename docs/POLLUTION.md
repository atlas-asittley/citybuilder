# Pollution

Per-tile environmental score. Production buildings emit, parks dampen, the score lives on `map_tiles.pollution` and is recomputed every production tick.

Status: **shipped 2026-05-06 as visible-but-toothless.** The score is computed and surfaced, but doesn't yet block housing tier evolution. Planned for a v2 follow-up.

## Sources and dampers

Per-tick emit values (server-tunable in `building_types.pollution_emit` / `pollution_radius`):

| Building | Emit | Radius |
|---|---|---|
| Smelter, Glassworks, Charcoal Kiln, Lime Kiln, Nail Forge | 10 | 4 |
| All other processors (sawmill, mason, mill, kilns, T3/T4 buildings…) | 5 | 3 |
| Raw extractors (timber_camp, stone_quarry, iron_mine, clay_pit) | 2 | 2 |
| Food extractors, services, boosters, police, tax, road, housing | 0 | — |
| **Park** | -8 | 3 |
| **Tree Grove** | -4 | 4 |

Sources only emit when `is_staffed = true`. Parks always dampen (worker_cost 0, `OR pollution_emit < 0` carve-out in the compute helper).

## Compute

`_pp_update_pollution(uid)` — runs in `process_production` after staffing, before housing eval. Resets all owned tiles to 0, then sums emit per tile via SQL CROSS JOIN with Manhattan-distance filter. Result clamped to ≥0.

```sql
UPDATE public.map_tiles mt SET pollution = GREATEST(0, agg.total)
FROM (
  SELECT mt2.id AS tile_id, SUM(bt.pollution_emit) AS total
  FROM public.map_tiles mt2
  JOIN public.buildings b ON b.player_id = p_uid AND b.status = 'active'
  JOIN public.building_types bt ON bt.key = b.building_type_key
   AND bt.pollution_emit <> 0
  WHERE mt2.owner_player_id = p_uid
    AND ABS(mt2.x - b.x) + ABS(mt2.y - b.y) <= bt.pollution_radius
    AND (b.is_staffed OR bt.pollution_emit < 0)
  GROUP BY mt2.id
) agg
WHERE mt.id = agg.tile_id;
```

## Visibility

- Heatmap mode "Pollution" — yellow tint scaled to per-tile pollution. Toggle via the 🗺 button bottom-right of the map.
- Building inspector — when an inspected building's tile has pollution > 0, a "Pollution: N (light/heavy/toxic)" row shows.
- Live refresh: after every production tick, `refreshTileMetrics()` in `js/game.js` fetches `(id, x, y, pollution, desirability)` for the player's tiles and updates DOM in place.

## v2: housing gate (deferred)

The intended gameplay effect was a three-tier cap on housing:
- 1–30 (light): tier-cap at Cottage (no upgrade past tier 2)
- 30–60 (heavy): force devolve toward Cottage
- 60+ (toxic): housing inactive (no workers / pop)

Not yet wired. Atlas's two players' districts have peak pollution 15–30 (light tier territory), so the gate would not currently force any devolve. Once parks have had time to be placed, the gate can be turned on by modifying `_pp_evolve_housing` to consult tile pollution.

## Tunables

All in `building_types`:
- `pollution_emit` — positive emits, negative dampens
- `pollution_radius` — Manhattan distance

If pollution feels too aggressive: lower the heavy-emitter values (10 → 7) or shrink radii (4 → 3). If too gentle: bump radii or amplify multi-tile sprawl. Park dampening (-8) is intentionally generous — Parks are a deliberate counter, not a token gesture.

## Related

- `migration_patches/pollution_v1.sql` — schema + buildings + compute + sprites
- `js/help.js` STAT_INFO — descriptions
- `memory/project_metric_stack.md` — how pollution fits with happiness/crime/desirability
