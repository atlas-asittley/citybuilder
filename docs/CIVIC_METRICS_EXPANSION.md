# Civic Metrics Expansion — Design Doc

**Status:** Design + phased implementation in progress (started 2026-05-28).
**Owner:** Atlas (decisions delegated to Claude; "go to town, we can modify later").
**Scope:** A coherent expansion that (a) adds new civic-metric dimensions, (b) fixes the
dead-resource problem, and (c) equalizes the four industries — all interlocking.

This is the source of truth for the expansion. If reality drifts from it, update the doc.
Cross-references: `memory/project_metric_stack.md`, v1 `GAME_DESIGN.md`,
`docs/POLLUTION.md` / `docs/DESIRABILITY.md` / `docs/CRIME.md`, and
`feedback_new_building_category_checklist` (the 7+-touch-point checklist).

---

## 1. Why this exists (the three problems)

Confirmed against the live DB on 2026-05-28:

1. **Dead resources.** The four tier-4 capstone goods — `machinery` (iron),
   `monuments` (stone), `cabinets` (timber), `mosaics` (clay) — have **no consumption
   sink**. They are only a *token "have ≥1 in stock"* gate for housing tiers 7–8
   (`housing_tier_config.needs_industrial_luxury` / `needs_all_industrial_luxuries`).
   You build an entire T4 processor chain to make a good you can only sell.

2. **Unequal industries.** Demand is asymmetric:
   - Lifestyle goods kick in at different tiers: `pottery`@T2, `bread`@T3,
     `furniture`@T4, `statuary`@T5 — so clay/iron goods are broadly demanded while
     timber/stone goods matter only to mature cities.
   - **Iron is the king-maker**: it feeds `bread` (staple food + Tavern), `flour`
     (School), `ale` (Hospital), `tools` (the universal productivity booster).
   - **Timber is weakest**: `lumber` feeds two services, but its food chain
     (berries→wine→spirits) is barely demanded and its capstone is dead.

3. **Too few civic dimensions.** Today there are four: happiness, crime, pollution,
   desirability. We want more *managed* dimensions that create gameplay loops.

## 2. The unifying principle

> **Every civic metric is suppressed/raised by a building category whose construction
> or ongoing operation consumes a *different industry's* capstone or signature good.**

This single rule kills problems #1 and #2 at once:
- Dead tier-4 goods become **capital / infrastructure goods** (the Anno / Factorio /
  Tropico pattern: top-tier outputs feed into *building the city*, not just a sell button).
- Because each new metric leans on a different industry, demand spreads evenly and no
  single industry is dispensable.

## 3. Terminology & taxonomy (canonical)

We call the whole category **Civic Metrics**. Two layers, plus utilities:

| Layer | Metrics | Direction | Storage |
|---|---|---|---|
| **Pressures** | pollution, crime, **waste**, **congestion**, **noise** | lower is better | per-tile (`map_tiles`) or per-player (`player_profiles`) |
| **Standings** | desirability, happiness, **health**, **education** | higher is better | per-tile or per-player |
| **Utilities** | **power/energy**, water (Well, existing) | supply must meet demand | per-player capacity vs demand |

- **Pressures** are emitted by buildings and suppressed by coverage/treatment buildings.
- **Standings** are derived scores; the master standing is **happiness → migration → population**.
- **Utilities** are balance metrics: a shortage applies a penalty (brownout / dehydration).

Naming for UI copy: use "Civic Metrics" as the umbrella; within it say "pressures" and
"standings" sparingly. Player-facing chip labels are just the metric name (Waste, Power, …).

## 4. Resource sink map (equalization target)

Each new system is fed by a deliberate industry so demand spreads. Target end-state:

| System / building | Consumes (industry) | Notes |
|---|---|---|
| Incinerator / Recycling (sanitation) | **machinery** (iron) to build | machinery = capital good |
| Powerhouse (power) | **charcoal** (timber) to operate | gives timber a load-bearing role |
| Watermill / Windmill (power) | brick/lumber to build | early, fuel-free, low output |
| Fancy roads — paved | **brick** (stone) | tier 1 upgrade |
| Fancy roads — tiled avenue | **tiles / mosaics** (clay) | mid |
| Fancy roads — grand boulevard | **cabinets / monuments** (timber/stone) | top, +desirability +shade |
| Clinic / Hospital upgrades (health) | **lumber + glass** (timber/clay) | health buildings |
| Library / School upgrades (education) | **lumber + paper?** (timber) | education buildings |
| Civic landmarks (desirability) | **monuments / mosaics** (stone/clay) | beautification |

Net effect by industry:
- **Iron** → machinery powers waste/incineration + high-tier infrastructure.
- **Stone** → monuments + brick drive beauty/roads.
- **Clay** → tiles/mosaics pave fancy roads; glass feeds health.
- **Timber** → charcoal powers the city; lumber/furniture feed health + education.

Plus a structural fix for the food skew (see §10): make the housing food requirement a
**variety** requirement so every industry's food staple is needed.

---

## 5. Mechanical conventions to follow

From the server map (verified 2026-05-28):

- The tick is `process_production()` → `_pp_for_uid(uid)` (SECURITY DEFINER), which calls
  ordered phase helpers `_pp_*`. New metrics add a `_pp_update_<metric>(uid)` helper
  inserted at the right point (pressures before desirability; desirability before housing
  evolution).
- **Per-player score** metrics (like crime) follow `compute_<metric>(uid)` STABLE +
  `_pp_update_<metric>(uid)` persisting to `player_profiles`.
- **Per-tile** metrics (like pollution) follow `_pp_update_<metric>(uid)` that writes
  `map_tiles.<col>` via a building↔tile distance JOIN. Pollution uses **Manhattan**
  distance and crosses parcel borders (no player filter on the emitter). Coverage/service
  effects use **Chebyshev** distance.
- Building emit/effect columns live on `building_types`. Pattern: `<metric>_emit`,
  `<metric>_radius`, `<metric>_reduction`, `coverage_radius`.
- Multi-tile adjacency/coverage must walk the **footprint perimeter**, not just the anchor
  (see `feedback_multitile_perimeter`). Most current coverage checks use the anchor; new
  coverage radii are generous enough that this is acceptable short-term, but prefer
  perimeter-correct distance for new code.
- All multiplicative numeric updates `ROUND(…, 6)` (see `feedback_numeric_precision`).
- Every money UPDATE needs a matching `cash_transactions` row (see
  `feedback_cash_ledger_invariant`); continuous rates need `period_start`.
- New `category` values require updating the `building_types` CHECK constraint AND the
  staffing/worker helpers AND every frontend touch point (see §11 checklist).
- **Ship visible-but-toothless first** when a new metric could devolve existing housing.
  Pollution & desirability shipped this way. Flip the gate after playtesting.

## 6. Feature: Waste Management *(Phase 1 — flagship)*

**Model:** per-player **pressure** score, mirroring crime (simpler + safer than per-tile).

- **Generation:** active housing and processors emit waste. Score:
  `waste = base + Σ(house waste by tier) + Σ(processor waste) − Σ(sanitation reduction)`,
  clamped 0–100. Stored on `player_profiles.waste`.
- **Suppression:** new `category='sanitation'` buildings with a `coverage_radius` reduce
  waste for housing in range (Manhattan, like police). Must be **staffed** to count.
- **Effect (bounded, safe):** waste drags desirability via the city-base term, capped:
  `desirability_city_base -= LEAST(8, FLOOR(waste / 12))` (max −8, reached at waste≥96).
  Bounded so it cannot trigger mass devolution. (Later: also feed Health in Phase 5.)
- **Worker-hungry** per Atlas's ask — sanitation buildings need many workers.

**Buildings (`category='sanitation'`, industry_key='common'):**

| key | name | tier | build cost | workers | coverage_r | upkeep | notes |
|---|---|---|---|---|---|---|---|
| `dump` | Refuse Dump | 1 | $400 | 6 | 5 | 4 | cheap; emits pollution + small local desirability hit (NIMBY) |
| `recycling_center` | Recycling Center | 2 | $900 | 12 | 7 | 8 | converts waste → a trickle of scrap (low-grade clay/stone/iron) |
| `incinerator` | Incinerator | 3 | $1800 + **2 machinery** | 16 | 9 | 15 | high throughput; emits pollution; **machinery sink** |

- Recycling Center's "scrap" output is a soft economic loop (small `output_rate` of a raw
  good); keep it small so it doesn't undercut extractors.
- Incinerator's machinery cost goes in `building_type_resource_costs` (the existing
  build-material table) — this is the proof-of-concept for the capstone→sink pattern.

**Heatmap:** new `waste` overlay mode (player-level value tinted uniformly over owned
housing tiles, or per-tile if we later go per-tile).

## 7. Feature: Power / Energy *(Phase 2)*

**Model:** city-wide **utility** — capacity vs demand.

- `power_capacity = Σ(staffed power-building output)`.
- `power_demand = Σ(power_load of staffed consumers)` — processors/high-tier buildings
  draw load; extractors/housing draw little or none.
- `power_ratio = capacity / max(1, demand)`. If `< 1` → **brownout**: multiply
  productivity by `power_ratio` (bounded floor, e.g. 0.6) so undersupplied cities slow but
  don't halt. Store `power_capacity` + `power_demand` on `player_profiles` for the chip.
- Era fit: this is an *industrial-tier* system (the game already has machinery, trains,
  airports). Gate power-demanding buildings to higher tiers so early game is unaffected.

**Buildings (`category='power'`, industry_key='common'):**

| key | name | tier | build cost | workers | output (cap) | operating input | notes |
|---|---|---|---|---|---|---|---|
| `watermill` | Watermill | 2 | $700 | 4 | 20 | none | fuel-free, low output, early |
| `windmill` | Windmill | 2 | $700 | 4 | 20 | none | cosmetic variant of watermill |
| `powerhouse` | Powerhouse | 3 | $1600 + 1 machinery | 10 | 80 | **charcoal** (timber) | the **charcoal sink** |

- `power_load` is a new `building_types` column; set on processors/transport hubs (the
  power-hungry buildings) and 0 elsewhere.
- Ship visible-but-toothless: compute and display capacity/demand first, flip the brownout
  penalty after we confirm balance (otherwise existing cities suddenly slow down).

**Built (Phase 2, on branch — `power_energy.sql` + `test_power_energy.py`, 7 tests):** exactly
as above, with these concrete values: consumers draw `power_load` = 3 (processor) / 8
(transport_hub) / 4 (transport_connector); plants supply `power_output` = 20 (Watermill/Windmill,
fuel-free) / 80 (Powerhouse). The Powerhouse burns `0.5 charcoal`/tick (via its
`input_resource_key`) and costs **1 machinery** to build. `_pp_update_power` runs after waste in
the tick, writing `player_profiles.power_capacity` / `power_demand`. **Brownout is deliberately
NOT wired** — to flip it on, multiply `_pp_compute_productivity`'s result by
`clamp(power_capacity / GREATEST(1, power_demand), 0.6, 1.0)` (one spot, no schema change).
Frontend: ⚡ demand/capacity chip + StatInfoModal + Inspector rows + sprites. **Era decision
(resolves §13):** pre-industrial flavour — Watermill/Windmill + a charcoal-fired Powerhouse —
not full industrial.

## 8. Feature: Fancier Roads *(Phase 3)*

Roads today are pure connectivity (`category='road'`, no metric effect). Add tiers, each
consuming a different industry's goods and emitting a **desirability aura** (radius).

| key | name | build cost | desirability_bonus / radius | notes |
|---|---|---|---|---|
| `road` | Dirt Road | $ (existing) | 0 | connectivity only (unchanged) |
| `paved_road` | Paved Road | brick (stone) | +2 / r2 | upgrade in place |
| `tiled_avenue` | Tiled Avenue | tiles or mosaics (clay) | +4 / r2 | prettier sprite |
| `grand_boulevard` | Grand Boulevard | cabinets + monuments | +6 / r3 | tree-lined; small pollution dampen |

- Implementation: either separate building keys (simplest given the category machinery) or
  a `road_tier` column upgraded via a new RPC. **Recommendation:** separate keys, all
  `category='road'`, distinguished by a `road_tier` smallint for rendering + connectivity
  equivalence (all road tiers count as road for staffing/walkers).
- Desirability already gates housing (`min_desirability` 25→94). Fancy roads become the
  primary lever to push housing to top tiers — beautification gets teeth.
- This is the sink for **mosaics + monuments + cabinets + tiles** → fixes most of problem #1.

**Built (Phase 3, on branch — `fancier_roads.sql` + `test_fancier_roads.py`, 6 tests):**
Three tiers as separate `category='road'` keys (so they inherit connectivity, paving,
autotiling, walker pathing, extractor-path recompute for free) distinguished by a `road_tier`
smallint: `paved_road` (1 brick → +2 desir r1), `tiled_avenue` (1 tiles → +4 r2),
`grand_boulevard` (1 **monuments** + 1 **cabinets** + 1 **mosaics** → +6 r3-ish [r2 shipped],
−3 pollution r2, tree-lined). The Grand Boulevard sinks all three *art* capstones at once; with
machinery sunk by sanitation/power, **all four dead capstones now have sinks.** Implementation:
`_pp_update_desirability` rebuilt on the waste version with one change — the amenity subquery
condition becomes `(b.is_staffed OR bt.category = 'road')` so never-staffed roads still project
their aura. No new tick phase, no `_pp_for_uid` change. Frontend: roads render via the shared
autotile texture, so tiers are distinguished by a **map tint** (`ROAD_TIER_TINTS`) + distinct
build-menu sprites; AOE ring (`kind:'road'`), inspector/help/describe copy updated. **No upgrade
RPC** — you build the fancier tier directly (placement obeys the normal road connectivity rule).
**Balance watch:** desirability auras SUM across overlapping roads (consistent with civic
amenities). Radii were kept small (1/2/2) to limit cheap-paved-road stacking; revisit if players
trivially max desirability with brick.

## 9. Feature: New standings/pressures *(Phase 4–5)*

Add as real stored metrics, each with an industry-spread sink:

- **Health** *(standing)* — driven by Hospital/Clinic coverage + waste management + clean
  water. Low health caps population growth or saps productivity. Sink: lumber + glass
  (timber/clay). Closes the waste↔pollution↔health loop. Health buildings: `clinic` (T2,
  coverage), Hospital already exists (upgrade its role).
- **Education** *(standing)* — make the School's effect a *stored* metric that gates T4
  industry ("educated workforce required") and boosts productivity. Sink: lumber + a new
  `paper`/`books` good (timber). Gives timber a second load-bearing role. Buildings:
  `library` (T2/3).
- **Congestion** *(pressure)* — ties into roads + transport network: cheap roads congest,
  fancy/wide roads relieve; congestion drags productivity + happiness. (Cities:Skylines'
  core loop; we already have a transport network to hang it on.)
- **Noise** *(pressure)* — clone the pollution mechanic but short-range; emitted by
  industry/transport, dampened by tree groves. Cheapest to add (mirror `_pp_update_pollution`).

Cheapest high-impact pair: **Health** (loops with waste) and **Congestion** (loops with
roads), because they reinforce Phases 1 & 3.

## 10. Industry equalization *(cross-cutting)*

Beyond the sink map (§4), one structural lever:

- **Food variety gate.** Today `bread` (iron) reads as the universal staple. Make the
  housing food requirement a *variety* requirement: higher tiers need foods from multiple
  industries (grain/bread=iron, fish=stone, berries=timber, vegetables=clay). Add
  per-tier `food_variety_required` to `housing_tier_config` and enforce in
  `_pp_evolve_housing` / the food drain. This directly de-thrones iron and makes every
  industry's food staple necessary. (Ship carefully — affects every existing city's
  upgrade path; visible-but-toothless first.)

## 11. New-building-category checklist (apply for `sanitation`, `power`)

Per `feedback_new_building_category_checklist`, each new category touches:

**Server**
1. `building_types.category` CHECK constraint — add the value.
2. `_pp_staff_buildings` — include category in the staffing loop (worker-consuming).
3. `_pp_workers_needed` / worker accounting — include it.
4. Any production/effect phase helper for its mechanic (e.g. `_pp_update_waste`).

**Frontend** (`/home/atlas/citybuilder-game/src/`)
5. `ui/bottompanel/BuildTabPanel.js` — `CATEGORY_RANK`, `sectionFor(bt)`, `describeBuilding(bt)`.
6. `scenes/helpers.js` — `getBuildingAoeRange(b, bt)` (so its coverage ring draws),
   and the `heatmapTintFor` case if it has an overlay.
7. `scenes/MainScene.js` — `AOE_TINTS` (the ring color for the new `kind`), `CATEGORY_TINTS`.
8. `ui/InspectorPanel.js` — surface its effect rows (`<metric>_emit`, coverage, etc.).
9. `ui/HelpModal.js` — `benefitText(bt)` branch + section.
10. `sprites.js` — building sprite (**encode literal `%` as `%25`**, see
    `feedback_svg_data_uri_pct_encoding`).
11. For a new player-level metric: `ui/TopBar.js` chip + `wireStat`, `ui/StatInfoModal.js`
    STAT_INFO entry, and `state/loader.js` select (tile metrics only — profile uses `*`).

## 12. Phasing & deployment

| Phase | Content | Risk | State |
|---|---|---|---|
| 0 | This design doc | none | ✅ |
| 1 | Waste management (server + tests + frontend) | low (bounded effect) | ✅ built (branch) |
| 2 | Power/Energy (visible-but-toothless) | low | ✅ built (branch) |
| 3 | Fancier roads + capstone sinks | medium (sprites, RPC) | ✅ built (branch) |
| 4 | Congestion + Noise | medium | queued |
| 5 | Health + Education + food-variety gate | higher (touches upgrade paths) | queued |

**Deployment policy for this work:** built on branch `civic-metrics-expansion`, tested via
savepoint-isolated pytest (no live commit). The DB migration is **not applied to live**
until the matching frontend merges to `main` — otherwise the live site (old frontend) sees
unknown categories. Atlas merges + applies when ready; the go-live steps are listed in the
session summary and TODO.md. Rationale: a large unreviewed feature shouldn't risk the live
game for the two real players while unattended, even though the normal cadence is
ship-to-main.

## 13. Open questions (for Atlas, non-blocking)

- Power era: keep "energy" pre-industrial-flavored (watermill/windmill/charcoal powerhouse)
  or lean fully industrial at high tiers? Doc assumes the former.
- Recycling scrap output: which raw goods, and how small to avoid undercutting extractors?
- Food-variety gate aggressiveness: how many distinct foods per tier? Doc leaves it tunable.
- Should waste be per-player (current plan) or per-tile (richer heatmap, more compute)?
