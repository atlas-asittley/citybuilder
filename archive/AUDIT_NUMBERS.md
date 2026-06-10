# City Builder UI Numeric Values Audit

Comprehensive inventory of all numeric values displayed to users in the City Builder MVP.

## Topbar (Row 1: Identity & Resources)

| # | Where | What | Pass-through or Computed | Source / Formula |
|---|-------|------|---|---|
| 1 | `index.html:157; ui.js:98` | Money (topbar pill) | pass-through | `state.profile.money` |
| 2 | `index.html:159; ui.js:237-256` | Runway countdown (hours/minutes/seconds until UTC midnight) | computed (client) | `new Date()` → next UTC midnight, `msLeft / 60000` for minutes, `msLeft / 1000` for seconds |
| 3 | `index.html:155; ui.js:104-108` | Parcels claimed | pass-through | `state.profile.chunks_owned` (default 1) |
| 4 | `index.html:159` | Trader reset countdown (e.g., "3h 25m") | computed (client) | Time until UTC midnight; `Math.floor(totalMin / 60)` for hours, `totalMin % 60` for minutes |

## Topbar (Row 2: Labor & Population)

| # | Where | What | Pass-through or Computed | Source / Formula |
|---|-------|------|---|---|
| 5 | `index.html:167; ui.js:111-147` | Workers employed (e.g., "15/42") | computed (client) | `state.laborInfo.workersUsed / state.laborInfo.workersNeeded` |
| 6 | `index.html:167; ui.js:124-127` | Labor shortage badge (!) | pass-through | Show if `state.laborInfo.laborShortage` is true |
| 7 | `index.html:168; ui.js:133-147` | Population (e.g., "28/50") | computed (client) | `Math.floor(state.profile.population) / state.laborInfo.housingCapacity` |
| 8 | `index.html:170; ui.js:149-167` | Happiness (0-100) | computed (client) | `Math.round(state.profile.happiness)` |
| 9 | `index.html:171; ui.js:213-227` | Crime (0-100) | computed (client) | `Math.round(state.profile.crime)` |
| 10 | `index.html:172; ui.js:169-196` | Migration rate (e.g., "+0.45/min" or "−0.12/min") | computed (client) | `state.profile.migration_rate` → `Math.round(rate * 100) / 100` → `.toFixed(2)` |
| 11 | `index.html:173; ui.js:198-211` | Productivity (e.g., "115%") | computed (client) | `state.profile.productivity * 100` → `Math.round(p * 100)` |

## Build Panel

| # | Where | What | Pass-through or Computed | Source / Formula |
|---|-------|------|---|---|
| 12 | `panels.js:230` | Road build cost | pass-through | `bt.build_cost` (e.g., "$20") |
| 13 | `panels.js:232` | Housing worker range (e.g., "2–34 workers") | pass-through | Building type config; range varies by housing tier |
| 14 | `panels.js:234` | Non-housing build cost + worker cost | pass-through | `$' + bt.build_cost + ' | ' + bt.worker_cost + ' worker'` |
| 15 | `panels.js:240` | Ongoing upkeep cost (e.g., "$5/min") | pass-through | `$' + bt.upkeep_per_minute + '/min'` (police, future buildings) |
| 16 | `panels.js:167, 173` | Extractor output (e.g., "5 timber/min") | computed (client) | `er.output_q + ' ' + resourceName + periodSuffix` (recipeOf) |
| 17 | `panels.js:175-177` | Booster multiplier (e.g., "+15% output") | computed (client) | `Math.round(((bt.boost_multiplier - 1) * 100))` + `bt.boost_range` (e.g., "within 2 tiles") |
| 18 | `panels.js:180, 182, 186, 188` | Service building upkeep / worker requirements | pass-through | Well: 3 workers, Tavern/Bathhouse: staffed upkeep, School: lumber+flour, Temple: statuary+brick |
| 19 | `panels.js:200` | Tax revenue rate (e.g., "$12/min per 100 citizens") | pass-through | `$' + bt.output_rate + '/min per 100 citizens'` |
| 20 | `panels.js:202-203` | Police coverage radius + upkeep (e.g., "6 tiles" + "$3/min") | pass-through | `bt.coverage_radius`, `bt.upkeep_per_minute` |
| 21 | `panels.js:206-207` | Park pollution reduction + radius (e.g., "−50 pollution within 4 tiles") | pass-through | `bt.pollution_emit`, `bt.pollution_radius` |
| 22 | `panels.js:268` | Housing tier number (e.g., "Tier 3") | pass-through | `bt.tier` |
| 23 | `panels.js:271-278` | Resource cost chips (e.g., "3 stone (2 have)") | computed (client) | `rc.quantity` (required) vs `state.inventory[rc.resource_key]` (on hand) |
| 24 | `panels.js:248` | Money shortage hint (e.g., "need $120 more") | computed (client) | `bt.build_cost - state.profile.money` |
| 25 | `panels.js:826` | Next auto-trade timer (e.g., "~15 min") | computed (client) | `Math.ceil((soonest - Date.now()) / 60000)` |

## City Panel → Resources Tab

| # | Where | What | Pass-through or Computed | Source / Formula |
|---|-------|------|---|---|
| 26 | `reports.js:94` | Resources per category count (e.g., "5 · 342 total") | computed (client) | `catRows.length` items, `sum of row.stock` |
| 27 | `reports.js:109` | Resource rate (e.g., "+2.3/min") | computed (client) | `formatRate(row.rate)` → `Math.round(Number(value) * 10) / 10` with sign |
| 28 | `reports.js:110` | Resource stock | pass-through | `Math.floor(state.inventory[key])` |
| 29 | `reports.js:111` | Net trade $ (e.g., "+$45" or "−$12") | computed (client) | `flow.export_money - flow.import_money` (from trade_transactions) |
| 30 | `reports.js:298` | Resource flow: producing rate (e.g., "Producing +2.7/min") | computed (client) | `Math.round(totalIn * 10) / 10` |
| 31 | `reports.js:301-302` | Production source: count × building name + rate | computed (client) | `p.count` buildings, `fmtRate(p.rate)` |
| 32 | `reports.js:307-308` | Import source: trader + price + max rate | computed (client) | `i.trader` name, `i.price` (gold per unit), `fmtRate(i.rate)` |
| 33 | `reports.js:316` | Resource flow: consuming rate (e.g., "Consuming −1.8/min") | computed (client) | `Math.round(totalOut * 10) / 10` |
| 34 | `reports.js:321, 327, 333, 339` | Consumption sources (processors/services/citizens/exports) with rates | computed (client) | `Math.round(x.rate * 10) / 10` per item |
| 35 | `reports.js:348` | Net flow rate (e.g., "Net: +0.9/min") | computed (client) | `totalIn - totalOut`, formatted with `fmtRate` |
| 36 | `reports.js:377` | Reserve target (policy input) | pass-through | `policy.reserve_target` (0-9999) |
| 37 | `reports.js:386, 393` | Price gates: min sell price / max buy price | pass-through | `policy.min_sell_price` / `policy.max_buy_price` (null = no gate) |
| 38 | `reports.js:416-417` | Trade partner activity: sent qty + cost, received qty + cost | computed (client) | `p.export_qty + ' (+$' + p.export_money + ')'` vs import |

## City Panel → Treasury Tab

| # | Where | What | Pass-through or Computed | Source / Formula |
|---|-------|------|---|---|
| 39 | `reports.js:450` | Treasury: earned in period (e.g., "$1250") | computed (server RPC) | Sum of all income sources via `get_cash_ledger_by_source` |
| 40 | `reports.js:451` | Treasury: spent in period (e.g., "$890") | computed (server RPC) | Sum of all spending sources via `get_cash_ledger_by_source` |
| 41 | `reports.js:452` | Treasury: net in period (e.g., "+$360") | computed (client) | `totalIn - totalOut` |
| 42 | `reports.js:529` | Burn rate: 7-day average (e.g., "+$120/day") | computed (client) | `weekNet / days.length` → `Math.round(avgDailyNet)` |
| 43 | `reports.js:537-538` | Runway projection (e.g., "~4 days") | computed (client) | `Math.floor(money / burn)` |
| 44 | `reports.js:566` | Top income source + amount (e.g., "↑ Tax Revenue $450") | computed (client) | `sources[topSource]` from 7-day aggregation |
| 45 | `reports.js:569` | Top expense sink + amount (e.g., "↓ Upkeep $320") | computed (client) | `sinks[topSink]` from 7-day aggregation |
| 46 | `reports.js:616-620` | Daily net bars: height per day | computed (client) | `Math.abs(d.net) / maxAbs * maxBar` (scaled SVG) |
| 47 | `reports.js:646` | Balance line: stroke color | computed (client) | Green if `balances[end] >= balances[0]`, red otherwise |
| 48 | `reports.js:674` | Income/spending flow bars: per-source amount + width % | computed (client) | `v / max * 100` (clamped to 2% min) |
| 49 | `reports.js:731` | Transaction detail: amount per row (e.g., "+$45") | pass-through | `row.amount` from `cash_transactions` |
| 50 | `reports.js:743` | Transaction detail: total shown (e.g., "Total of these: $1200") | computed (client) | Sum of visible rows (capped to 200) |

## Trade Panel → Partners Cards

| # | Where | What | Pass-through or Computed | Source / Formula |
|---|-------|------|---|---|
| 51 | `panels.js:971` | Trader visit capacity + interval (e.g., "cap 20/visit · every 10m") | pass-through | `t.visit_capacity`, `t.visit_interval_minutes` |
| 52 | `panels.js:961, 972` | Next visit countdown (e.g., "~12 min") | computed (client) | `Math.ceil((nextVisit - Date.now()) / 60000)` |
| 53 | `panels.js:926, 935` | Best deals gates (e.g., "sell at $45+") | pass-through | `policy.min_sell_price` / `policy.max_buy_price` |
| 54 | `panels.js:930, 939` | Best deals match price (e.g., "$48" on partner) | pass-through | `state.allTraderPrices[tk][rk].buy_price` or `.sell_price` |
| 55 | `panels.js:1006, 1010` | Trader goods: buy/sell caps used today (e.g., "b 5/20") | pass-through | `buyUsed / buyCap`, `sellUsed / sellCap` from `state.traderQuotas` |
| 56 | `panels.js:1026-1027` | Trader goods: buy/sell prices (e.g., "$25" / "$30") | pass-through | `prices[rk].buy_price` / `.sell_price` from `state.allTraderPrices` |

## Trade Panel → Black Market

| # | Where | What | Pass-through or Computed | Source / Formula |
|---|-------|------|---|---|
| 57 | `panels.js:1071` | Black Market sell price (35% of base) | computed (client) | `Math.max(1, Math.floor(r.base_price * 0.35))` |
| 58 | `panels.js:1072` | Black Market buy price (200% of base) | computed (client) | `Math.ceil(r.base_price * 2.0)` |
| 59 | `panels.js:1083` | Black Market: current stock display (e.g., "Stock: 45") | pass-through | `Math.floor(state.inventory[rk])` |

## Trade Panel → Players (P2P)

| # | Where | What | Pass-through or Computed | Source / Formula |
|---|-------|------|---|---|
| 60 | `players.js:96` | Pending trade offers badge count | computed (client) | Filter `state.allOffers` where `status = 'pending'` and role matches |
| 61 | Trade offer: resource qty, unit price, total | computed (server/RPC) | From `player_trade_offers` table: `quantity`, `unit_price`, computed net |

## Inspector: Building

| # | Where | What | Pass-through or Computed | Source / Formula |
|---|-------|------|---|---|
| 62 | `inspector_building.js:90` | Worker requirement (e.g., "3 required") | pass-through | `bt.worker_cost` |
| 63 | `inspector_building.js:99-101` | Transport hub: traders unlocked (e.g., "2 unlocked") | computed (client) | `1 + b.expansion_level` |
| 64 | `inspector_building.js:105` | Transport hub: expansion level (e.g., "Level 1 / 1") | pass-through | `b.expansion_level` |
| 65 | `inspector_building.js:106` | Transport hub: expansion cost (e.g., "$800") | computed (client) | `bt.build_cost * 2 * (lvl + 1)` |
| 66 | `inspector_building.js:119-120, 129-134` | Extractor: path length + effective rate (e.g., "4 tiles" + "3 timber/min") | computed (client) | `b.path_length`, `effectiveRate = output_rate * (canonical / path_length)` |
| 67 | `inspector_building.js:146` | Housing: capacity (e.g., "Houses up to 45 people") | pass-through | `tierCfg.workers` or `bt.workers_provided` |
| 68 | `inspector_building.js:161` | Housing: next tier & workers gained (e.g., "Cottage (+6 wkrs)") | computed (client) | `nextTierCfg.workers` (delta) |
| 69 | `inspector_building.js:191, 195` | Housing pantry: item quantity / capacity (e.g., "3.5 / 10.0 (35%)") | pass-through | `entry.quantity / entry.capacity * 100` → `Math.round` |
| 70 | `inspector_building.js:68` | Building status: issue count (e.g., "3 issues") | computed (client) | Count of `computeBuildingIssues(b, bt)` array length |

## Inspector: Tile (Resource Nodes)

| # | Where | What | Pass-through or Computed | Source / Formula |
|---|-------|------|---|---|
| 71 | `inspector_tile.js:34` | Resource tile name display | pass-through | `resName(inspectedTile.resource_node_key)` |

## Inspector: Walker

| # | Where | What | Pass-through or Computed | Source / Formula |
|---|-------|------|---|---|
| 72 | `inspector_walker.js:68` | Walker steps progress (e.g., "7 / 14") | pass-through | `walkerInfo.steps / walkerInfo.maxSteps` |

## Walkers System (Ambient & Collectors)

| # | Where | What | Pass-through or Computed | Source / Formula |
|---|-------|------|---|---|
| 73 | `walkers.js:12, 16, 18` | Walker movement timing constants (1400ms, 1500ms) | hard-coded config | `WALKER_MOVE_MS`, `WALKER_SPAWN_COOLDOWN`, `COLLECTOR_PAUSE_MS` |
| 74 | `walkers.js:143` | Walker cap (e.g., "floor(pop / 10)") | computed (client) | `Math.floor((state.profile.population) / 10)` |
| 75 | `walkers.js:53-64` | Persona weights (distribution % for variety) | hard-coded config | Weights sum to ~100; affects walker type distribution |

## Notifications

| # | Where | What | Pass-through or Computed | Source / Formula |
|---|-------|------|---|---|
| 76 | `notifications.js:150` | Unread notification badge (e.g., "9+") | computed (client) | Count notifications with `read_at = null`, capped to "9+" |

## Modals & Help

| # | Where | What | Pass-through or Computed | Source / Formula |
|---|-------|------|---|---|
| 77 | `help.js` | Building tier unlock gates (e.g., "reach Tier 3 to unlock") | pass-through | `state.housingTierConfig[unlockTier].name` |
| 78 | `help.js` | Recipe reference numbers (input qty, output qty, period) | pass-through | Building type config: `input_q`, `output_q`, `period_min` |

## Hidden / Computed Server State (Not Directly UI)

| # | Where | What | Pass-through or Computed | Source / Formula |
|---|-------|------|---|---|
| 79 | (various) | Runway bottleneck determination | computed (server + client) | `computeCityRunway()` in panels.js: aggregates food + lifestyle goods, per-resource flow analysis |
| 80 | (various) | Labor allocation: staffed/unstaffed buildings | computed (client) | `computeLaborAllocation()` in state.js: simulates resource drain, worker availability, building priority |
| 81 | (various) | Production rates per building | pass-through per building | `bt.output_rate`, `bt.input_rate`, modified by path_length (extractors) and staffing |
| 82 | (various) | Migration rate | computed (server) | Driven by happiness; formula on server produces `migration_rate` field |
| 83 | (various) | Crime | computed (server) | Police coverage, upkeep deficit, and other factors; formula produces `crime` field |
| 84 | (various) | Happiness | computed (server) | Food availability, lifestyle good presence, crime; produces `happiness` field |
| 85 | (various) | Productivity multiplier | computed (server) | Tavern upkeep & placement; produces `productivity` field |

## Summary

**Total entries: 85**

- **Pass-through (render state directly): ~45**
- **Computed (client-side math/aggregation): ~35**
- **Server-computed, rendered as-is: ~5**

### Key Patterns

1. **Topbar**: Mostly pass-through from `state.profile` + one client computed countdown (trader reset)
2. **Build Panel**: Mix of pass-through (building costs/workers) and computed (shortage hints, recipe formatting)
3. **Resources/Treasury**: Heavily computed from aggregated data (flows, ledger RPC, cash transactions)
4. **Trade**: Mostly pass-through from `state.allTraderPrices` + `state.traderQuotas`; computed best-deals matching
5. **Inspector**: Pass-through building fields + computed indicators (tier unlock gates, path-length modifiers)
6. **Walkers**: Hard-coded spawn behavior; computed cap per population
7. **Server Formulas**: Happiness, crime, migration, productivity are all computed server-side; UI renders the results

