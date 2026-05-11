# Transport Network — design spec (2026-05-08)

Atlas-driven feature: cooperative-flavored infrastructure that
unlocks new NPC trade routes for the whole city.

## Concept

Four new building types — three "transport hubs" and one "connector":

| Building | Role | Build cost | Footprint | Workers |
|---|---|---|---|---|
| **Airport** | Premium fast-trade hub | $50,000 | 2×2 | 10 |
| **Seaport** | Bulk exotic hub | $40,000 | 2×2 | 10 |
| **Train Depot** | Continental raw-resource hub | $30,000 | 2×1 | 8 |
| **Truck Depot** | Connector — opt-in to network | $8,000 | 1×1 | 5 |

## Access rules

- **Owning a hub (airport / seaport / train depot) grants you direct access** to that hub's traders. No truck depot required for the owner.
- **Owning a truck depot grants you access to every hub in the city** that you can reach via the road network. The truck depot is the cheap "I want in" entry-point.
- **No transport infrastructure → no transport traders.** The default visit pool stays as-is (river / desert / mountain).
- **Expansion of a hub adds another trader to that hub's pool.** The expansion benefits everyone with access (owners + truck-connected players).

So the per-mode trader count for the city is:
```
city_mode_traders = SUM(1 + expansion_level)
                    over all buildings of that mode in the city
```
And per-player visibility is:
```
visible(player, mode) = player owns hub of mode (with road access)
                      OR player owns truck depot (road-connected) AND
                         city has any hub of mode (road-connected)
```

For MVP we use a simplified "road-connected" check at the player level: a player is "in the network" if they own *any* road-connected transport building (hub or depot). Strict per-pair pathfinding deferred.

## Trader pools (initial)

Each hub type has its own NPC trader pool, themed thematically:

### Airport (fast premium)
- **air_1 — Sky Caravans:** lifestyle goods (pottery / bread / furniture / statuary), premium prices, small daily caps, short visit interval.
- **air_2 — Cloud Couriers:** luxury foods (caviar / spirits / spices / ale), high prices, mid caps.

### Seaport (bulk exotic)
- **sea_1 — Coastal Merchants:** raw materials in volume (clay / stone / timber / iron), large caps.
- **sea_2 — Distant Isles:** finished lifestyle goods + cross-industry (pottery / statuary / furniture / glass).

### Train Depot (continental staples)
- **train_1 — Inland Caravans:** grain / flour / bread / vegetables, massive daily caps, slower interval.
- **train_2 — Mountain Express:** processed industrials (lumber / brick / iron_ingot / nails).

Each hub starts with **trader 1** unlocked. **Expanding** the hub one tier unlocks **trader 2** (and so on if we add more tiers later — MVP caps at 2 traders per hub).

## Expansion mechanic

- Inspector for a transport hub shows current `expansion_level` and an **Expand** button.
- Expansion cost scales: tier 2 = 2× build cost. (For MVP only this single tier of expansion exists.)
- Expansion is paid by whoever clicks; one player owns the upgrade.
- When `expansion_level` changes, the city's mode count updates → new trader unlocks for everyone with access.

## Schema additions

### New columns
- `traders.transport_mode text` — one of (airport / seaport / train / null). Null = legacy traders (river / desert / mountain).
- `traders.tier int` — which trader-slot within the mode this represents (1-indexed).
- `buildings.expansion_level int default 0` — how many expansions have been applied to a transport hub.

### New trader rows
6 new rows in `traders` (2 per hub mode), each with full `trader_prices` entries for the relevant resources.

### New building_types rows
4 rows: airport, seaport, train_depot, truck_depot.

### Updated `_trader_is_unlocked`
Read the trader's `transport_mode` column. If null → existing logic. If set:
```
city_tier = SUM(1 + expansion_level) for buildings of mode in city
IF trader.tier > city_tier: locked
ELSE IF player has direct hub of mode (road-connected): unlocked
ELSE IF player has truck depot (road-connected) AND city has any hub of mode (road-connected): unlocked
ELSE: locked
```

## Client changes

- `recipe_format.js` and recipe-display already abstract the "no input/output" shape → minimal touchups.
- New build-panel descriptions for the 4 buildings.
- Inspector for transport hubs shows expansion level + Expand button → calls `expand_transport_hub(building_id)` RPC.
- Help menu housing-style tier breakdown for transport mechanic.

## What the player will experience

Two-player example city:
1. Drew builds an airport ($50k) → Drew gets Sky Caravans.
2. Jill builds a truck depot ($8k) → Jill gets Sky Caravans too (via Drew's airport).
3. Jill builds a seaport ($40k) → Jill gets Coastal Merchants directly. Drew gets Coastal Merchants via his already-built (or newly-built) truck depot.
4. Either player pays $80k+ to expand the airport → Cloud Couriers unlocks for everyone.

Total trader pool grows from 3 (the legacy traders) to 9 with full transport investment.

## Out of scope for MVP

- Per-tile pathfinding (using simplified player-network check).
- Tier 3+ expansions.
- Visual differentiation between hubs (placeholder sprites with simple colors).
- Trader missions / reputation tied to transport.
- Demolish-rollback warnings ("you'll lose access to N traders if you tear this down").

## Estimate
3 commits: (1) schema + traders, (2) server unlock logic + expand RPC, (3) client UI.
