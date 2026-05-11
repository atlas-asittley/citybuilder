# Trade Progression — Design

Status: **proposed**, in active implementation.
Last updated: 2026-05-05.

## Goals

1. **Force early-game self-sufficiency.** New players have no NPC partners until they hit a basic production milestone — they have to learn the core loop (extract → process → house → feed) on their own.
2. **Trade with the city, not the district.** NPC traders deal with the *city as a whole* (sum of all districts in the world). Player-to-player trade is unchanged — that's per-district.
3. **Progression through missions.** Once the unlock gate is met, all city-level NPC traders become accessible. Each trader periodically posts a request for goods. Players in the city donate from their inventory; faster fulfillment + larger contribution → more reputation. The city's weighted-average reputation drives what the trader will buy/sell and at what scale.
4. **Generic, expandable trader pool.** Trader names + specialties are sampled from pools, not hardcoded. New traders join the city as it grows / hits reputation tiers.
5. **Imports/exports visibility.** Players can see daily/weekly/all-time trade balance per resource and per partner.

## Vocabulary

- **District**: one player's tiles + buildings.
- **City**: every player in the world combined. (Single-world today.)
- **Solo player**: city size = 1; they are 100% of the city's weight.
- **NPC trader**: an external trade partner that visits the city periodically and posts requests.
- **Mission / request**: a city-level request from one trader for a specified resource quantity.
- **Reputation (rep)**: numeric track per (player, trader). City rep with that trader = weighted average across all players.

## The unlock gate

Until a player meets all three:

- ≥1 active **extractor** in their district
- ≥1 active **food_extractor** in their district
- ≥1 active **housing tier ≥ 1** in their district

…their NPC trade panel shows a "Develop your district to unlock trade" hint and the existing trader list is hidden.

The gate is per-player (each player unlocks individually), but once unlocked, the player sees the full city-level trader pool. A new player joining a city that already has unlocked traders sees those traders the moment they hit the gate themselves — they ride the city's coattails on what's *unlocked*, but they start at personal rep 0 with each.

The black market is **always available** — it doesn't gate behind anything.

## City weighting (population)

Every district has a *weight* = sum of housing workers (from `housing_tier_config.workers`) of all active housing in that district. Solo player → weight = sum of their housing → 100% of city.

We weight by population because:

- It's already computed for worker capacity; no new state.
- It's thematic — a bigger city has more clout.
- It can't be gamed by spamming roads or expanding aimlessly.

## Reputation

### Personal (per-player) rep

Stored in `trader_relationships(player_id, trader_key, reputation, last_decay_at)`. Earned by donating to missions. Weighted into the city rep average, and shown to the player so they can track their own contribution.

### City rep

Computed on demand from the players' personal reps:

```
city_rep(trader_key) =
  Σ (player.weight × player_rep[player_id, trader_key])
  / Σ (player.weight)
```

If no players have any rep with that trader yet, city rep = 0.

### Reputation tiers

| Tier | Threshold | Effect |
|---|---|---|
| 0  | 0       | Trader exists in pool. 1-2 base goods at small capacity. |
| 1  | 50      | +1 good. +25% capacity. |
| 2  | 150     | +1 good. +50% capacity. Slight price improvement. |
| 3  | 400     | +1 good. +100% capacity. |
| 4  | 1000    | All offered goods available. Max capacity. |

Each new trader spawns at tier 0. Tier-up unlocks more goods; the trader's `trader_prices` pool grows over time.

### Decay

Every player's personal rep decays slowly when they go inactive on missions:

- Tick: every UTC midnight (or on the first session each day).
- Rate: −2% of current rep, floor 0.
- A donation in the last 7 days pauses decay for that trader.

This means a city that stops engaging slowly drifts back down, but a single fulfilled mission resets the clock.

## Missions

### Lifecycle

1. **Spawn.** A trader has a mission cooldown (default 30 min). When the cooldown expires AND the trader has no active mission, the system rolls a new mission.
2. **Open.** The mission is visible to all players in the city. It says: "Trader X wants Y units of resource Z by ⟨soft deadline⟩."
3. **Donate.** Any player in the city can donate from their inventory. Donations debit inventory, credit `mission_donations`, and atomically advance the mission's `current_qty`.
4. **Resolve.**
   - **Fulfilled** (current_qty ≥ target_qty): mission closes, reputation distributed proportionally to each player's contribution × speed bonus (1.0 → 1.5 based on time-to-fill vs. soft deadline).
   - **Expired** (now > soft_deadline + grace_window): mission closes, partial reputation distributed proportionally (no speed bonus) for whatever was contributed.
5. **Cooldown** restarts; trader rolls another mission later.

### Speed bonus

A mission has `soft_deadline_minutes` (default 60). Reputation multiplier:

```
multiplier(elapsed_minutes) = clamp(1.5 - (elapsed_minutes / soft_deadline_minutes) * 0.5, 1.0, 1.5)
```

So filling the request instantly gives +50%, filling at the deadline gives +0%, anything past the deadline (until expiry) gives base.

### Mission size scaling

Target quantity scales with city population:

```
target_qty = base_request × (1 + 0.10 × ln(1 + city_population))
```

Solo small-city: target ~ base_request. Big city: target grows but logarithmically — keeps missions feasible per-capita.

### Grace window

Missions expire 6h after the soft deadline. This gives stragglers a chance to contribute partially.

### Mission types (v1)

Only `deliver_resource` for v1. Future kinds (deliver multi-resource bundle, reach housing tier, build N of X) layer in later as new `kind` values.

## Trader generation

Traders aren't hardcoded. A trader template + name pool generates instances.

### Name pool

```
Riverbend, Eastvale, Brightport, Oakhaven, Saltford, Grayhall, Fenwick, Cliffmoor,
Marshwell, Stoneglen, Highmere, Ashbrook, Westmere, Thornfield, Goldhollow,
Foxglove, Ironhall, Greycoast, Whitewater, Ravenhold, Pinecross, Windmark,
Brackenridge, Larkmoor, Holloway, Weatherton, Marrow, Tanglewood, Lochmere,
Ashvale, Haldenbrook
```

### Specialty templates

Each template defines the resource categories the trader is interested in:

- **resource_buyer** — buys raw extractor outputs (lumber, stone, clay, iron). Sells some food.
- **food_buyer** — buys food (grain, flour, bread, fish, vegetables). Sells some raw materials.
- **luxury_buyer** — buys high-tier processed goods (statuary, cabinets, monuments). Sells preserved goods.
- **balanced** — small spread across all categories. Smaller volumes.
- **specialist** — buys/sells a single industry's chain. Higher prices in their specialty.

When a new trader spawns, sample (name, template). Specific resources within the template are picked from a curated list once at spawn; the trader's offerings expand at rep tier-ups.

### Spawn cadence

- **City unlocks**: 3 starter traders spawn immediately when *any* player first hits the gate. They use distinct templates (resource_buyer, food_buyer, luxury_buyer).
- **City growth**: at city populations 50, 150, 400, the world adds another trader (capped at 8 active traders). After 8, no new spawns until one departs (which we don't implement in v1).

### Existing traders (river_traders, desert_caravan, mountain_folk)

The current 3 are renamed/migrated to fit the new templates. Their existing prices stay; they're the city's first 3 starter traders.

## Black market

The black market is the always-available fallback. It's intentionally *worse* than the cheapest NPC trader by design.

- v1 nerf: `−35% on sell prices` (what the player gets when selling to the black market). Buy prices unchanged. Quantities unchanged.
- This widens the gap between black market and NPC trade, so unlocking the gate has tangible value.

## UI changes

### Tab reshuffle

Top-level tabs shrink to: **Build / Inventory / Trade**.

Trade has 4 sub-tabs:

- **Partners** — NPC traders. Locked-state hint when gate not met. Otherwise: list of city traders, each with its own prices, capacity, city rep, and a "Visit now" / next-visit countdown.
- **Missions** — open requests. Each mission card shows trader, resource, target qty, current qty, time elapsed, your contribution, and a Donate input.
- **Players** — what's currently the Players tab (offer trade, list other players).
- **Stats** — imports/exports per period, top partners, net balance.

### Locked state

When the unlock gate isn't met, the Partners and Missions sub-tabs both show a "Develop your district" panel listing the three requirements + which are met. Visually similar to the housing-blocker UI.

### Stats

A single panel with:

- Period selector (Today / This Week / All time).
- Imports table: resource × qty × $ spent.
- Exports table: resource × qty × $ earned.
- Net balance: $ in/out, resources delta.
- Top partners by total volume (NPC + player mixed).

All computed from the existing `trade_transactions` table.

## Schema

### New tables

```sql
-- Personal reputation per (player, trader). Created on first donation.
CREATE TABLE trader_relationships (
  player_id     uuid REFERENCES player_profiles(id) ON DELETE CASCADE,
  trader_key    text REFERENCES traders(key) ON DELETE CASCADE,
  reputation    numeric NOT NULL DEFAULT 0,
  last_donation_at timestamptz,
  last_decay_at timestamptz NOT NULL DEFAULT now(),
  created_at    timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (player_id, trader_key)
);

-- Open + historical missions. One row per mission.
CREATE TABLE trader_missions (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  trader_key    text NOT NULL REFERENCES traders(key) ON DELETE CASCADE,
  kind          text NOT NULL DEFAULT 'deliver_resource',
  resource_key  text NOT NULL REFERENCES resources(key),
  target_qty    integer NOT NULL,
  current_qty   integer NOT NULL DEFAULT 0,
  soft_deadline timestamptz NOT NULL,
  expires_at    timestamptz NOT NULL,  -- soft_deadline + grace
  status        text NOT NULL DEFAULT 'open',  -- open / fulfilled / expired
  created_at    timestamptz NOT NULL DEFAULT now(),
  resolved_at   timestamptz,
  CONSTRAINT trader_missions_status_check
    CHECK (status IN ('open','fulfilled','expired'))
);
CREATE INDEX idx_trader_missions_trader_status
  ON trader_missions (trader_key, status, created_at DESC);

-- Per-player donations to a mission.
CREATE TABLE trader_mission_donations (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  mission_id   uuid NOT NULL REFERENCES trader_missions(id) ON DELETE CASCADE,
  player_id    uuid NOT NULL REFERENCES player_profiles(id) ON DELETE CASCADE,
  qty          integer NOT NULL,
  donated_at   timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_donations_mission_player
  ON trader_mission_donations (mission_id, player_id);
```

### New / updated RPCs

- `donate_to_mission(p_mission_id uuid, p_qty integer)` — debits inventory, inserts donation, advances mission, fires `complete_mission` if target met.
- `complete_mission(p_mission_id uuid)` — internal / cron-style; closes a mission, distributes reputation.
- `expire_old_missions()` — internal / cron-style; closes any mission past `expires_at`, distributes partial rep.
- `roll_trader_missions()` — internal / cron-style; spawns new missions for traders whose cooldown has elapsed.
- `decay_reputations()` — internal / cron-style; applies daily decay.
- `get_trade_partner_view()` — returns the unlocked NPC traders + city rep + your personal rep. Replaces the client-side `computeTraderUnlocks`.
- `get_active_missions()` — returns open missions in the city, with each player's contribution.
- `get_trade_stats(p_period text)` — returns imports/exports/balance for a period (today / week / all).
- `is_trade_unlocked(p_player_id uuid)` — boolean unlock check based on the gate criteria.

The existing `resolve_trader_visit` and `sell_to_trader` add an unlock-gate check at the start.

The existing `black_market_trade` cuts sell prices by 35%.

### Cron-style helpers

For v1 we don't need a real cron — players *visit* the trade panel, which can opportunistically call `roll_trader_missions()` and `expire_old_missions()` and `decay_reputations()` on the server. This is the same lazy-resolution pattern `resolve_trader_visit` already uses for visit timing.

## Implementation order

1. Design doc (this file).
2. Schema migration (tables + indexes).
3. Unlock-gate RPC + remove client-side `computeTraderUnlocks` indirection.
4. Mission generation + donation RPCs.
5. Reputation expansion of trader inventory (city rep tiers → which goods).
6. Black market −35% sell prices.
7. Frontend: tab reshuffle, locked state, missions UI.
8. Stats panel.
9. Decay.
10. Tests.

Each slice ships as its own commit and is revertable.

## Open / deferred

- Mission types beyond `deliver_resource` (multi-resource bundles, build/upgrade quests). Plan to add via `kind` column.
- Trader departure (a trader losing rep below threshold leaves the city). Punted from v1.
- Cross-world traders (multiple cities). Punted indefinitely; world = single city for now.
- Personal-rep price discounts (player who contributes most gets best prices). Considered, dropped for v1 simplicity.
- Real cron-job runner. Lazy resolution from player visits is fine until activity is high enough to need it.
