# City Builder — Game Design

This is the canonical reference for how the game is intended to work. It describes the **target state** as of the current planned milestones (district scaffolding + distance-based resource collection). Where target state diverges from current code, that's called out explicitly.

For implementation/file layout details see `city-builder-mvp/STRUCTURE.md`. This document is about *mechanics*, not file structure.

---

## Concept

A multiplayer city builder where every player specializes in one primary resource and trades with others to access the rest. The map is shared. Each player owns a contiguous **district** they build in. Districts can be expanded for a cost. Players see each other's work but can't build on it.

Tech: static frontend (no build step) + Supabase (Postgres + Auth + RPC + Realtime). Server is authoritative for game state.

---

## World model

### The map
- Single shared map across all players.
- Coordinates are **absolute signed integers** with no upper bound. The map is unbounded in principle.
- Tiles are stored in `map_tiles` (one row per tile). Key fields:
  - `x`, `y` — coordinates
  - `terrain_type` — visual/biome flavor
  - `resource_node_key` — nullable; if set, the tile contains a resource deposit of that type
  - `buildable` — terrain-level placement allowance
  - `owner_player_id` — nullable; the player who owns this tile (M1 addition)
  - `claimed_by_building_id` — nullable; the extractor currently claiming this resource tile (M2 addition)

Tiles with `owner_player_id = NULL` are **wilderness** — visible but not buildable by anyone.

### Districts
A player's **district** is the set of all tiles where `owner_player_id = me`. Districts are not stored as bounding rectangles — they're computed from per-tile ownership. This allows irregular shapes and fast lookups.

Districts can only contain matching resource tiles for the owner's industry. A timber player's district has only timber resource tiles; a stone player's has only stone, etc.

### Chunks and expansion
A **chunk** is a 15×15 block of tiles allocated as a unit. Districts grow by chunks, not by individual tiles.

**New player onboarding:**
1. Player signs up via `choose_industry`.
2. Server picks the next free slot in a **spiral allocation** order starting at origin: (0,0), (1,0), (0,1), (−1,0), (0,−1), (1,1), (−1,1), (−1,−1), (1,−1), (2,0), … ad infinitum.
3. A 15×15 chunk is created at that slot, all tiles get `owner_player_id = new player`.
4. Approximately 8% of the chunk's tiles get `resource_node_key = player's primary resource`, scattered.

**Expansion:**
1. Player calls `expand_district` RPC.
2. Cost: `base_cost × chunks_owned²` (quadratic curve — gentle early, steep late).
3. Server picks the first adjacent unowned chunk slot (or the player picks a direction; design TBD).
4. New chunk is added with the same 8% resource density.

The spiral allocation guarantees no two players ever overlap, even with concurrent signups, because the next-free pointer just advances atomically.

### Cross-player visibility
- Other players' tiles, buildings, walkers, and roads all render on the map.
- Clicking another player's building opens a limited-info inspector (name, owner, type — no economy data).
- Walkers from other players are visible but not interactable.

---

## Players

Each player has exactly one `industry_key` stored on `player_profiles`. Industries currently defined: `timber`, `stone`, `grain`, `clay`. Each maps 1:1 to a primary resource (timber industry → timber resource, etc.) via `resources.industry_key`.

Industry is **assigned randomly at signup** and never changes. (The current `choose_industry` RPC has a stale validator that only allows `('timber', 'stone')`; this is a known bug to fix as part of M1.)

**Build menu filtering:** server-side check in `place_building`:
```
IF v_bt.industry_key <> 'common' AND v_bt.industry_key <> v_player.industry_key THEN reject
```
Buildings with `industry_key = 'common'` (housing, roads, future civic) are buildable by anyone. Industry-specific buildings are filtered to matching players.

**Workers:** every player starts with 5 base workers. Housing adds workers (each house provides 6). Production buildings consume workers, allocated oldest-first. Buildings without workers go `unstaffed` and don't produce.

---

## Building taxonomy

Buildings are stored in `buildings`; their catalog is `building_types`. Categories:

- **`extractor`** (tier 1) — collects raw resources from map tiles via collector walkers. See [Resource collection](#resource-collection).
- **`food_extractor`** (tier 1) — flat-rate food production. No path math, no walker. Each industry has a paired food extractor (timber → Orchard / berries, stone → Fishing Pier / fish, clay → Garden / vegetables, iron → Grain Farm / grain). Locked to its industry via `industry_key`. Output is flagged `is_food = true` so it auto-satisfies the housing food gate. **Placement requirement**: each food extractor must be placed *on* its matching food tile (Orchard → orchard_grove, Fishing Pier → pond, Garden → garden_plot, Grain Farm → farmland). The `building_types.placement_resource_node_key` column wires this up; the trigger `reject_build_on_resource` rejects placement off-tile and rejects every other building on a food tile (which is symmetric to the existing rule for ore tiles). The food tile is *not* consumed at placement — the resource_node_key persists under the building, so demolish reveals the tile again. To turn a food tile into plain grass, use `clear_resource_tile` (which now also rejects tiles already occupied by a building).
- **`booster`** (tier 1) — AOE production multiplier. No production of its own. Each industry has two: a *resource booster* (boosts adjacent T1 extractors) and a *food booster* (boosts adjacent food extractors). When staffed, applies `boost_multiplier` (default +25%) to matching buildings within Manhattan distance `boost_range` (default 2). Multiple boosters within range take the **MAX** multiplier — not stack. Same staffing semantics as extractors (no road needed). Locked to industry via `industry_key`; per-booster behavior is configured by `boost_target` ('extractor' or 'food_extractor').
- **`processor`** (tier 2+) — consumes resources from inventory, produces another. Supports a single input (legacy: e.g. sawmill timber → lumber) or two inputs (multi-input recipe gated by the scarcer input — output is proportional to `min(avail/need)` across the inputs and both inputs drain at that proportion). Tier-3 processors (woodcarver, sculptor, bakery, distillery, etc.) live in this same category — they're just deeper in the chain. Cross-converters (charcoal_kiln, lime_kiln, glassworks, nail_forge) are also processors that produce a unique support good per industry.
- **`housing`** — provides workers, evolves through tiers t0–t8 with prerequisites; see [Housing evolution](#housing-evolution). `industry_key = 'common'`.
- **`road`** — connectivity infrastructure. Walkers move on roads. Required for staffing of processor / service / tax / housing-tier-1+ buildings. `industry_key = 'common'`.
- **`service`** — citizen-job buildings that consume resources to provide an effect. All require road access to staff and must be staffed AND fed (all inputs available for the elapsed window) to "operate". Examples: well (gates housing tier 1+ within 4), tavern (consumes bread+pottery for a worker bonus), bathhouse (consumes brick+clay, blocks housing devolve in 4 tiles), school (consumes lumber+flour, gates Townhouse within 5), temple (consumes statuary+brick, gates Villa within 6). `industry_key = 'common'`.
- **`tax`** — credits money to the player when staffed. Currently just Tax Office ($10/min, 10 workers, road-required). `industry_key = 'common'`.

Each building has:
- `(x, y)` position
- `player_id` — owner
- `status` — `active`, `inactive`, `paused`, etc.
- `created_at` — used for worker allocation order (oldest first)

Extractor-only fields:
- `target_x`, `target_y` — coordinates of the claimed resource tile
- `path_length` — number of road tiles between the extractor's adjacent road and the road tile next to the target

`building_types` columns:
- `category`, `tier`, `industry_key`, `build_cost`, `worker_cost`
- `input_resource_key`, `input_rate` — primary input (processor + service)
- `input_resource_key_2`, `input_rate_2` — second input for multi-input services (tavern, bathhouse, school, temple). Cheaper than a join table at current scale; switch to join table only if a 3-input building shows up.
- `output_resource_key`, `output_rate` — production output OR (for tax/service) the magnitude of the side-effect (e.g., tavern's `output_rate=10` is the worker-capacity bonus)
- `workers_provided` — used by housing tiers

---

## Resources

Stored in the `resources` catalog table; per-player counts in `inventories`. Each resource row carries:
- `industry_key` — links a resource to its native industry
- `kind` — `raw` (extractor output) or `processed` (processor output)
- `is_food` — used by the housing food gate (see [Housing evolution](#housing-evolution))

Today's resources:
- **Raw industry**: timber, stone, clay, iron
- **Raw food**: berries, fish, vegetables, grain (each is the paired food for one industry)
- **Processed (tier-2)**: lumber, brick, pottery, flour, iron_ingot, wine, smoked_fish, preserves
- **Processed (tier-3)**: bread, furniture, statuary, tools, tiles
- **Cross-goods (tier-2 support)**: charcoal, lime, glass, nails (one per industry; required as the second input for the T4 cross-recipe buildings of a *different* industry)
- **Luxuries (tier-3 food)**: spirits, caviar, spices, ale (one per industry; high-value trade goods)
- **T4 cross-recipe outputs (tier-4 industrial luxuries)**: cabinets, monuments, mosaics, machinery (one per industry; non-food, top of the industrial tree)

Industry trees (symmetric shape — every industry has the same depth, just with different resources):

| Tier | Timber | Stone | Clay | Iron |
|---|---|---|---|---|
| **T1 industry** | Timber Camp → timber | Stone Quarry → stone | Clay Pit → clay | Iron Mine → iron |
| **T2 processor** | Sawmill → lumber | Mason Workshop → brick | Pottery Kiln → pottery | Smelter → iron_ingot |
| **T3 processor** | Woodcarver → furniture | Sculptor → statuary | Tile Maker → tiles | Toolmaker → tools |
| **T1 food** | Orchard → berries | Fishing Pier → fish | Garden → vegetables | Grain Farm → grain |
| **T2 food** | Winery → wine | Smokehouse → smoked_fish | Cannery → preserves | Mill → flour |
| **T3 food** | — | — | — | Bakery → bread |
| **T3 luxury** | Distillery → spirits | Curing House → caviar | Spicery → spices | Brewery → ale |
| **Resource booster** | Forester's Office | Foreman's Office | Clay Master's Hut | Mine Office |
| **Food booster** | Apiary | Hatchery | Compost Heap | Irrigation Channel |
| **Cross-converter** | Charcoal Kiln → charcoal | Lime Kiln → lime | Glassworks → glass | Nail Forge → nails |
| **T4 cross-recipe** | Cabinetmaker (furniture+lime → cabinets) | Architect (statuary+glass → monuments) | Mosaic Workshop (tiles+nails → mosaics) | Engineer's Workshop (tools+charcoal → machinery) |

Foods (`is_food = true`): grain, flour, bread, berries, fish, vegetables, wine, smoked_fish, preserves. Any of these in inventory satisfies the housing food gate. Future tier-specialized gates (e.g., "Townhouse needs grain specifically") would add per-resource booleans to `housing_tier_config`.

Industry buildings are locked to their industry via `building_types.industry_key`. General buildings (housing, road, services like well / tavern / bathhouse / school / temple, tax) stay `industry_key='common'` and are buildable by everyone. Cross-industry trade is the only way to get other industries' raw or processed goods.

A player can produce **only their primary resource** directly via extractors. To get any other resource, they must trade (NPC or player-to-player).

---

## Resource collection

This is the new mechanic introduced in M2.

### Placement
Extractors can be placed on any tile in the player's district that is:
- Buildable (terrain allows building)
- Owned by the player
- Not currently occupied by another building
- Not on a resource tile (clear the resource first via `clear_resource_tile`)

Extractors do **not** require road-adjacency. The walker pathing handles off-road movement (see below).

### Pathfinding (server-side weighted Dijkstra)
On placement, the server runs weighted Dijkstra to find the nearest **unclaimed** resource tile of the player's primary resource type. Edge costs:
- Road tile (any owner): cost 1
- Off-road buildable tile: cost 3
- Resource tile / unbuildable terrain: blocked

This means walkers strongly prefer roads but will cut across grass when the road detour is too long. `path_length` records the resulting weighted distance.

- If found: server records `target_x`, `target_y`, `path_length` on the building. Marks the resource tile via `claimed_by_building_id = building.id`.
- If not found: extractor stays placed but produces nothing. Will auto-retry whenever roads change or the district expands.

### Re-targeting (hybrid sticky)
An extractor keeps its claimed tile **until the path becomes invalid** (e.g., a road on the path is demolished, breaking connectivity). When that happens:
1. The claim is released (`claimed_by_building_id = NULL` on the old tile).
2. BFS reruns to find a new target.
3. If a closer unclaimed tile is now reachable, the extractor takes it.
4. If nothing is reachable, the extractor goes idle.

New roads do **not** trigger re-targeting on already-claimed extractors. This keeps gameplay predictable — the player stays in control of their economy.

### Production rate (server-side)
`process_production` reads `path_length` for each extractor and computes:

```
effective_rate = output_rate × min(1, canonical_path_length / max(path_length, 1))
canonical_path_length = 4
```

So an extractor with `path_length ≤ 4` produces at full `output_rate`. Beyond 4 tiles, the rate falls off linearly: a 5-tile path produces at 80%, an 8-tile path at 50%, a 16-tile path at 25%.

Idle (no path) extractors produce nothing.

The 30-second `process_production` tick remains; it just multiplies the per-extractor rate by elapsed time and credits inventory.

### One walker per extractor
Each active extractor owns one **collector walker** that animates the round trip:
1. Spawns at the extractor.
2. Walks the BFS path tile-by-tile (constant speed, linear easing) to the road tile adjacent to the resource.
3. Steps onto the resource tile.
4. Pauses ~1.5 seconds with the work animation.
5. Steps back onto the road and reverses the path home.
6. Despawns at the extractor and immediately respawns. The loop continues forever while the extractor is active.

The walker is **purely visual**. Production math is independent. If the browser tab is backgrounded and the walker animation pauses, the server still accrues the player's resources at the correct rate. When the tab foregrounds, the walker resumes.

### Idle / no-path UX
Extractors with no reachable resource tile show:
- Visual: dimmed, with a `!` indicator (same treatment as `unstaffed`).
- Inspector: "No path to resource — build roads to reach a resource tile."
- No walker spawns.
- Re-attempts BFS on every road change.

---

## Walkers

Two modes coexist:

### Collector (M2 addition)
- Spawned by active extractors.
- Has a fixed `path` array.
- `phase`: `outbound` | `pausing` | `returning`.
- One per extractor; loops indefinitely.

### Ambient (existing)
- Spawned randomly from housing and from staffed production buildings.
- Random-walks on roads.
- Despawns after `WALKER_MAX_STEPS` (default 18).
- Pure flavor.

### Visual rules (both modes)
- Constant speed: `WALKER_MOVE_MS` (default 1.4s per tile), linear CSS easing.
- Per-walker phase offsets: each walker is desynced from the others on bob/waddle animations and on movement timing.
- Other players' walkers render the same way and are visible to all.

---

## Housing evolution

Houses begin as Tier 0 (Shanty) and evolve up through Tier 8 (Palace) when their prerequisites are met for at least `upgrade_secs` (per-tier; see `housing_tier_config`). They devolve when prerequisites lapse for at least `devolve_secs`. Both checks are per-house and run inside `process_production`.

Each upgrade adds **exactly one** new prerequisite — slow steady ladder. Lower tiers ignore higher-tier services even if present.

| Tier | Name | Workers | Road | Well | Food | School | Temple | Luxury food | Industrial luxury | All 4 industrial |
|---|---|---|---|---|---|---|---|---|---|---|
| 0 | Shanty | 2 | — | — | — | — | — | — | — | — |
| 1 | Mud Hut | 6 | — | ✓ | — | — | — | — | — | — |
| 2 | Cottage | 10 | — | ✓ | ✓ | — | — | — | — | — |
| 3 | Townhouse | 16 | ✓ | ✓ | ✓ | — | — | — | — | — |
| 4 | Villa | 24 | ✓ | ✓ | ✓ | ✓ | — | — | — | — |
| 5 | Manor Estate | 34 | ✓ | ✓ | ✓ | ✓ | ✓ | — | — | — |
| 6 | Mansion | 50 | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | — | — |
| 7 | Estate | 70 | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | — |
| 8 | Palace | 100 | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |

Per-prereq mechanics:
- **Road**: any orthogonal neighbor is an active road building. Highways count.
- **Well**: any active well within Manhattan distance 4. Wells don't need to be staffed or fed for this gate — placement is enough.
- **Food**: any resource flagged `is_food = true` has quantity > 0 in inventory. Presence-only check today; consumption-per-tick is planned once the food-pairing item lands so non-grain industries have a local food source.
- **School**: any school within Manhattan distance 5 that is currently *operating* — staffed AND has both inputs (lumber + flour) available for the elapsed window. Built but unfed schools don't gate.
- **Temple**: any temple within distance 6 that is operating (statuary + brick).
- **Luxury food** (tier 6+): any resource flagged `is_luxury_food = true` (spirits, caviar, spices, ale) has quantity > 0 in inventory. Each luxury food is the T4 capstone of one industry's chain (timber / stone / clay / iron respectively), so satisfying this gate requires either running a distillery / curing house / spicery / brewery yourself or buying from a trade partner.
- **Industrial luxury** (tier 7+): any resource flagged `is_industrial_luxury = true` (cabinets, monuments, mosaics, machinery) has quantity > 0 in inventory. Each is a T4 cross-recipe processor's output and ties into the round-robin trade cycle.
- **All four industrial luxuries** (tier 8 only): cabinets AND monuments AND mosaics AND machinery all simultaneously > 0. Computed by counting distinct `is_industrial_luxury` resources in stock vs total defined — generalizes if more industrial luxuries are added later. Effectively forces a fully-traded city across all four industries.

Devolve override: an *operating bathhouse* (consumes brick + clay) within distance 4 blocks devolve regardless of which prereq lapsed. Useful as a buffer against a temporary food / road / service interruption.

Tier 0 (Shanty) is the subsistence floor — no road, well, or food needed. A player without trade access can always run a Shanty for 2 workers, so progression is throttled but never fully blocked.

---

## Trading

### NPC traders (working)
- `traders` table holds NPC catalog. `trader_prices` sets per-resource buy/sell rates.
- `resolve_trader_visit(trader_key)` RPC: lazy resolution. When the player opens the panel or the visit interval elapses, the server processes outstanding sell-surplus and buy-to-reserve policies per `trade_policies`.
- Visit interval (default 10 minutes) and capacity (default 20 goods) tunable on `traders`.
- Players use trade panel UI to set `trade_policies` per resource (mode + reserve target).

### Player-to-player (planned, untested)
Schema exists from `phase2b_trade_partners_migration.sql` but the flow has not been exercised in production with multiple real players. Future work.

---

## Server authority

### Authoritative on server
- All inventory mutations (production, trade, demolition refunds)
- Building placement validation (industry, district ownership, road connectivity, terrain buildability)
- District allocation and expansion
- BFS pathfinding and `path_length` storage
- Resource tile claims
- Worker allocation across player's buildings
- Trader visit resolution
- Production rate computation (per extractor)

### Client only
- Walker animation timing and visual state
- Map rendering, zoom, pan
- UI panels and inspector
- Click handlers (which then invoke server RPCs)
- Local form state and selection

The trust model: **the server is the source of truth**. The client never submits delta amounts (e.g., "credit me 5 timber"). It calls RPCs that produce server-computed results.

---

## Server RPCs

### Existing
- `place_building(x, y, building_type_key)` — creates a building; validates ownership, industry, terrain, road connectivity. Will gain BFS-and-claim logic in M2.
- `demolish_building(building_id)` — removes building, may refund cost. Will gain claim-release logic in M2.
- `process_production()` — production tick; advances output for each producing building based on `output_rate` and (M2) `path_length`.
- `choose_industry(display_name, industry_key)` — signup; creates `player_profiles` row. Gains district-allocation logic in M1.
- `resolve_trader_visit(trader_key)` — runs NPC trade based on player's policies.
- `save_trade_policy(resource_key, mode, reserve_target)` — upserts a trade policy.

### New (M1)
- `expand_district()` — allocates the next adjacent chunk to the calling player. Costs money proportional to `chunks_owned²`.

### New (M2)
- BFS recompute is folded into `place_building` (on placement), `demolish_building` (when a road is removed, recompute paths for all extractors whose path touched it), and `expand_district` (idle extractors retry).
- Optional: `recompute_extractor_paths()` — admin/debug RPC to nuke and rebuild all path data.

---

## Database schema (high level)

| Table | Purpose |
|---|---|
| `player_profiles` | One row per player: industry, money, workers, display name, home anchor |
| `map_tiles` | Per-tile data: position, terrain, resource node, owner, extractor claim |
| `buildings` | Placed buildings: position, type, owner, status, target + path_length (extractors), housing_tier (housing) |
| `building_types` | Catalog of buildable types: industry, category, costs, rates, **two-input columns for multi-input services** |
| `resources` | Catalog: name, industry, kind, **`is_food` flag for the housing food gate** |
| `housing_tier_config` | Per-tier name/labels/worker count + prereq booleans (`needs_road`, `needs_well`, `needs_food`, `needs_school`, `needs_temple`) + upgrade/devolve timings |
| `inventories` | Per-player resource counts |
| `traders`, `trader_prices`, `trader_visits` | NPC trade plumbing |
| `trade_policies` | Per-resource sell-surplus / buy-to-reserve automation |

Migrations live in `city-builder-mvp/migration_patches/*.sql` and apply chronologically. `baseline_schema.sql` is a snapshot that drifts behind the migrations; for fresh deploys, run baseline + every migration in order.

---

## Tunable values

These are the dials that affect game feel. Defaults shown.

| Knob | Default | Where |
|---|---|---|
| Chunk size | 15×15 | District allocation RPC |
| Ore clusters per new chunk | 4 random-walk blobs (6-15 walks each) of player's industry resource | `cluster_resources_in_chunks.sql` |
| Food clusters per new chunk | 2 random-walk blobs (4-8 walks each) of player's matching food tile | `food_tiles.sql` |
| Highway: horizontal strip y-offset | 7 | `allocate_district_chunk` |
| Highway: vertical strip x-offset | 7 | `allocate_district_chunk` |
| Canonical path length (full rate) | 4 tiles | `process_production` |
| Walker step duration | 1.4s | `WALKER_MOVE_MS` in `walkers.js` |
| Walker pause at resource | 1.5s | collector walker |
| Walker max ambient count | 7 | `WALKER_MAX_COUNT` in `walkers.js` |
| Production tick interval | 30s | `game.js` setInterval |
| NPC trader visit interval | 10–18 min (per trader) | `traders.visit_interval_minutes` |
| Trader visit capacity | 14–26 (per trader) | `traders.visit_capacity` |
| Base workers per player | 5 | constant in `process_production` |
| Workers per house | 2/6/10/16/24/34/50/70/100 by tier (0–8) | `housing_tier_config.workers` |
| Extractor / processor worker_cost | 10 | `building_types.worker_cost` |
| Service worker_cost | well 3, tavern/bathhouse 5, school/temple 10 | `building_types.worker_cost` |
| Tax Office revenue | $10/min when staffed | Tax building's `output_rate` |
| Tavern worker bonus | +10 capacity when fed | Tavern's `output_rate` |
| Well housing range | 4 tiles | `has_well_access` |
| School housing range | 5 tiles | `process_production` housing eval |
| Temple housing range | 6 tiles | `process_production` housing eval |
| Bathhouse devolve-block range | 4 tiles | `process_production` housing eval |
| Expansion cost | `500 × chunks_owned²` | `expand_district` |

---

## Glossary

- **Ambient walker** — a cosmetic walker spawned by housing or staffed production. Random-walks. No game state.
- **Canonical path length** — 4 tiles. The path length at which an extractor produces at full rate.
- **Chunk** — a 15×15 block of tiles allocated as a unit. Districts are made of chunks.
- **Claim** — the link from an extractor to its target resource tile. Stored as `map_tiles.claimed_by_building_id`.
- **Collector walker** — a walker tied to an extractor that animates the round trip to its claimed resource tile.
- **District** — the set of tiles owned by a player. Computed from `map_tiles.owner_player_id`.
- **Effective rate** — the actual production rate of an extractor: `output_rate × min(1, 4/path_length)`.
- **Extractor** — tier-1 building that collects raw resources from a map tile via a collector walker.
- **Food** — any resource flagged `is_food = true`. Today: grain, flour, bread. Required to be present in inventory for housing tier 1+.
- **Industry** — a player's specialization. Maps 1:1 to a primary resource. Currently `timber | stone | iron | clay`.
- **Operating service** — a service building that is currently staffed AND has all inputs available for the elapsed window. Tracked as an in-memory `v_operating_services` array each tick of `process_production`. The school/temple/bathhouse housing-tier checks query against this set; merely placing the building isn't enough.
- **Path length** — the number of road tiles between an extractor's adjacent road tile and the road tile orthogonally adjacent to its claimed resource tile.
- **Primary resource** — the resource type a player can extract directly.
- **Processor** — building category for any input → output transform. Includes both tier-2 (sawmill, mill, mason workshop, pottery kiln) and tier-3 (woodcarver, sculptor, bakery) chain steps.
- **Service** — building category for citizen-job buildings (well, tavern, bathhouse, school, temple). Each consumes inputs and provides an effect when staffed AND fed.
- **Specialty resource** — any resource not native to the player's industry. Acquired via trade.
- **Subsistence floor** — Tier 0 Shanty. Always available, no prerequisites; protects players without trade access from being fully blocked on housing.
- **Tax building** — building category for revenue-generating buildings. Currently just Tax Office.
- **Wilderness** — a tile with `owner_player_id = NULL`. Visible but not buildable.

---

## Future / out of scope

These are explicit non-goals for the current milestones, listed so they don't get conflated with planned work. Items that *are* planned live in `TODO.md`.

- **Player-to-player trade** — schema exists, untested. Deferred until multiple real players are using the game.
- **Resource depletion or regeneration** — resources are infinite; tiles are never consumed.
- **Multiplayer presence indicators** — no "active now" markers, no chat.
- **Combat / conflict** — non-goal. Districts cannot be contested or invaded.
- **Path visualization on hover** — possible future polish.
- **Pipeline of multiple walkers per extractor** — one walker per extractor for v1; richer animations later if desired.
- **Adaptive re-targeting** — current rule is sticky. Adaptive (auto-swap to closer tile when roads change) is a future tuning option.

---

## Document conventions

This doc describes the **target state** of the game's mechanics. M1 (district scaffolding) and M2 (distance-based collection) are shipped. Subsequent additions — services, tax, multi-input feeding, housing prereq stack, food gate — are also shipped. Where current code differs from this doc, treat the doc as authoritative and update reality, OR update the doc if the code's behavior is the right one. Don't let the two drift.

When mechanics change, update:
1. This document (`GAME_DESIGN.md`)
2. The affected migration file(s) under `city-builder-mvp/*.sql`
3. The relevant client module under `city-builder-mvp/js/`
4. `STRUCTURE.md` only if file layout changes

For implementation context (file dependencies, RPC names, deployment), see `city-builder-mvp/STRUCTURE.md`.
