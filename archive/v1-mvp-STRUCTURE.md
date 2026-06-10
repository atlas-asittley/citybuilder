# City Builder MVP — File Structure

## Layout

```
city-builder-mvp/
├── index.html              HTML structure (no inline CSS or JS)
├── css/
│   └── styles.css          All styles
├── js/
│   ├── main.js             Entry point — bootstraps the app, restores session
│   ├── version.js          APP_VERSION constant (single source of truth)
│   ├── config.js           Supabase URL/key, creates the client
│   ├── state.js            Shared mutable game state + helpers
│   ├── ui.js               Screen switching, toast notifications
│   ├── auth.js             Login, register, logout, industry selection
│   ├── game.js             Game entry, data loading, production loop
│   ├── map.js              Map rendering, placement, district expansion
│   ├── map_roads.js        Road autotile SVGs + placement-time connectivity cache
│   ├── panels.js           Build/Inventory/Trade panel rendering and events
│   ├── walkers.js          Ambient + collector walker spawning and movement
│   ├── inspector.js        Building inspector overlay
│   └── realtime.js         Supabase realtime subscription for multiplayer
│
├── baseline_schema.sql     Single canonical schema (run on fresh projects)
├── migrations-archive/     Layered migrations that built up to baseline; reference only
├── migration_patches/      Small standalone bugfix SQLs for in-place fixes
├── graphics/               Art direction, sprite plans, asset tracking
│   └── archive/            Completed initiative plans (e.g. BUILDING_POLISH_PLAN)
└── STRUCTURE.md            This file
```

Outside `city-builder-mvp/`:

```
citybuilder/
├── GAME_DESIGN.md           Canonical game mechanics (target state)
├── TODO.md                  Running task list — Up next + Done with dates
├── docs/
│   ├── ONBOARDING.md        Getting up and running locally
│   ├── TRADE_PROGRESSION.md Trade gate + missions + city reputation design
│   └── HAPPINESS.md         Per-player happiness + population dynamics design
└── archive/                 Historical operational runbooks
    └── M1_M2_deployment_runbook.md
```

## Schema deployment

A **fresh Supabase project** runs only `baseline_schema.sql` once. That's the entire schema: tables, indexes, RLS, policies, functions, triggers, and catalog seed data, generated from the live production DB.

The **existing live DB** was built from the layered migrations under `migrations-archive/`. Don't run `baseline_schema.sql` against it — that would `DROP SCHEMA public CASCADE` and wipe everything.

When new features ship, new migration files land at `city-builder-mvp/*.sql` alongside the baseline and run on top of it. The first such migration after this consolidation will reset the layering trap by being a single file with a single redefinition.

## How to update the app version

Edit `js/version.js` — change the `PAGE_BUILD` string. This is the only place the
version is defined; it is displayed automatically in the upper-left badge.

## Cache-buster

The version badge in the upper-left doubles as a cache-buster. Tapping it clears
any service-worker / Cache-API entries and reloads with `?_cb=<timestamp>` in
the URL. A small inline bootstrap at the top of `index.html` reads that query,
injects an import map that remaps every `js/<name>.js` to `js/<name>.js?_cb=<n>`,
and applies the same query to the CSS link and the main module script — forcing
fresh fetches for HTML, CSS, and every JS module without waiting for the
GH-Pages cache TTL.

**If you add a new ES module under `js/`**, also add its bare name to the
`modules` array in the bootstrap (`index.html`, near the top of `<head>`),
or it won't be cache-bustable.

## Module system

The frontend uses native ES modules (`<script type="module">`). No bundler or build
step is needed. All modern browsers (including mobile Safari/Chrome) support this.

The dependency graph is:

```
main.js
 ├── version.js
 ├── config.js
 ├── ui.js
 ├── auth.js ──► config, state, ui, game
 └── game.js ──► config, state, ui, map, panels, realtime
      ├── map.js ──► config, state, ui, panels, map_roads
      ├── map_roads.js ──► state
      ├── panels.js ──► config, state, ui, map, players
      ├── players.js ──► config, state, ui
      └── realtime.js ──► config, state, ui, map
```

## Trade

NPC trade is gated behind a per-player progression milestone (≥1 active
extractor + ≥1 food extractor + ≥1 tier-1 housing). Once unlocked the
player sees the city-level trader pool — "city" here means all districts
in the world combined. Each trader periodically posts an open mission;
players donate from inventory, faster fulfillment + larger contribution
= more reputation, and a population-weighted city rep drives the trader's
inventory expansion.

Player-to-player trade is unchanged and not gated.

Black market is always available but intentionally a worse deal (sell
prices are ~35% below the original to amplify the gate's value).

The Trade tab is split into 5 sub-tabs: Partners, Missions, Players,
Resources (per-resource table + drilldown), Treasury (income/expenditure).

See `docs/TRADE_PROGRESSION.md` for the full design + schema + RPCs.

## Housing, population & happiness

### Overview
Workers come from a stored `population` on `player_profiles`. Each tick the
target population = 5 (base) + Σ housing-tier worker yields. Population
drifts toward that target, gated asymmetrically by happiness:

- Population **below target** (housing > current pop) → snaps up immediately.
  Empty homes fill with new arrivals on the next tick — there's no
  build-house-then-wait friction.
- Population **above target** (housing demolished / devolved) → clamps down.
- Population **at target** with happiness **< 50** → slowly drifts down at
  `((50 − happiness)/50) × 1` citizen/min. So the lower the happiness, the
  faster citizens leave.

worker_capacity = `floor(population) + tavern_bonus`. Tavern still adds its
+10 service bonus on top.

### Happiness inputs (compute_happiness)
Six weighted components, summed and clamped to 0..100:

- 30 base
- +3 per operational service type (well + tavern + bathhouse + school + temple, each counted once if active + road-connected + (for fed services) inputs in stock)
- +2 × avg active housing tier
- +min(15, distinct in-stock foods × 2)
- −3 per active tax office
- +20 × min(1, worker_capacity / workers_needed) — staffing health

Visible in the topbar smiley (☹ / 😐 / 🙂 / 😊). Atlas's separate
"productivity modifier" lives on TODO.md as a follow-up — distinct
metric that affects per-building output, vs happiness which affects
*who lives in the district*.

### See also
- `docs/HAPPINESS.md` — full design + math
- `docs/TRADE_PROGRESSION.md` — NPC trade unlock gate + city-rep + missions

## Deployment

Serve the directory as static files at the same path it currently occupies.
No build step required. The Supabase JS library is loaded from CDN in index.html.
