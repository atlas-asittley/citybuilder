# v2 Parity Audit (2026-05-12)

Comprehensive feature comparison between v1 (`~/citybuilder/city-builder-mvp/js/`) and
v2 (`~/citybuilder-game/src/`). Goal: close every meaningful gap so v1 can be retired.

**Method:** Five parallel research passes, each covering one UI surface area, comparing
file-for-file with v1. Findings consolidated and ranked here by player-facing impact.

Items checked off (`[x]`) as they ship in the `v1-parity audit, commit N/N` series.

---

## TIER 1 — Critical (silent failure modes; blocks parity)

These are surfaces where a player can't tell something is broken, or where actual
gameplay state isn't being shown. Hidden state on a city-builder is a bug.

- [x] **Building issue visuals** (`v1-parity audit, commit 40/N`) — `MainScene.js` _renderOneBuilding. v1 fades the sprite + draws `!` overlay on idle / unstaffed / no-road / paused / missing-inputs. v2 only animates "good" buildings; broken ones look identical to working ones. Player can't scan for problems on a busy map.
- [x] **Inspector "Issues" section** (`v1-parity audit, commit 41/N`) — `InspectorPanel.js`. v1 renders a consolidated bulleted list of every reason a building isn't operational ("no road — place a road adjacent", "missing 5 lumber", "no workers"). v2 has just a single `Status` row.
- [x] **Housing upgrade blocker detail** (`v1-parity audit, commit 42/N`) — `InspectorPanel.js`. v1 lists EVERY blocker joined ("needs school + temple + statuary"). v2 says only "needs more services / lifestyle goods". Player can't tell what to fix.
- [x] **Devolve risk during grace window** (`v1-parity audit, commit 42/N`) — `InspectorPanel.js`. v1 distinguishes "will devolve in ~60s" vs "bathhouse is holding it but X is slipping". v2 only shows past `last_devolve_reason`. Active risk is invisible.
- [x] **Map view persistence** (`v1-parity audit, commit 43/N`) — `MainScene.js _setupCamera`. v1 saves scroll + zoom to localStorage per player; v2 resets to parcel center on every load. Hot reloads / refreshes / device switches lose your place.
- [x] **Building animation gating: missing inputs / no road** (`v1-parity audit, commit 40/N`) — `MainScene.js _spawnBuildingAnimations`. v2 animates anything `active && is_staffed`; v1 additionally gates on `road-connected && hasInputs`. A staffed processor with no inputs currently fakes production in v2.

## TIER 2 — High (significant information density loss)

- [x] **Treasury Advisor (4-component dashboard)** (`v1-parity audit, commit 49/N`) — `CityTreasuryTab.js`. Missing burn rate + runway projection, top-source/top-sink chips, daily-net 7-bar SVG, cumulative-balance sparkline. v1's `renderTreasuryAdvisor` (reports.js ~571-707).
- [x] **Per-house pantry buffer display in inspector** (`v1-parity audit, commit 44/N`) — `InspectorPanel.js`. v1 shows per-resource fill % (food, pottery, bread, etc.) so player knows actual time-to-devolve. v2 missing.
- [x] **Per-house pantries in runway calc** (`v1-parity audit, commit 44/N`) — `state/runway.js`. v2 only models city-wide drain. v1 models per-house buffers (30-min capacity). Top-bar runway is optimistic.
- [x] **Resources drilldown** (`v1-parity audit, commits 50-51/N`) — `CityResourcesTab.js`. v1: click a row to expand "where it's going" (production sources, processor sinks, citizen drain, exports + per-partner flow). 50 shipped the flow breakdown; 51 added the per-partner trade table.
- [x] **Players compose: counterparty inventory** (`v1-parity audit, commit 45/N`) — `TradePlayersTab.js`. v1 fetches `get_player_trade_view` so receive-side shows "they have N" annotations and refuses over-asking. v2 lets you ask for stuff they don't have, fails server-side with a confusing error.
- [x] **Players inbox: pre-accept blocker check** (`v1-parity audit, commit 45/N`) — `TradePlayersTab.js`. v1 disables Accept with "Can't accept: missing 5 lumber" when you can't pay. v2 lets you click Accept then alerts on failure.
- [x] **Help / Buildings Reference: housing tier breakdown** (`v1-parity audit, commit 48/N`) — `HelpModal.js`. v1's `renderHousingTierBreakdown` (help.js ~798 LOC total) shows the full 9-tier ladder (Shanty → Palace) + per-tier prereqs + lifestyle goods drain rates + desirability floors. v2 (149 LOC) skips this entirely.
- [x] **Inspector: extractor path length + rate scaling** (`v1-parity audit, commit 46/N`) — `InspectorPanel.js`. v1 shows target coords, path_length, effective rate (scaled by canonical=4), and a hint about shorter paths.
- [x] **Bug-report workflow stays consistent** (`v1-parity audit, commit 47/N`) — verify v2's bug report writes the same `client_state` / `server_state` JSON shape v1 does. (Audit was wrong — v2 was doing direct INSERT with thin client_state, no server_state. Switched to `submit_bug_report` RPC so server pulls the rich forensic snapshot v1 captures.)

## TIER 3 — Medium (visible parity / polish)

- [ ] **Walker persona variety + overlays** — `MainScene.js` + `helpers.js pickWalkerVariant`. v1 has 11 personas + overlay accessories (cane, pet, pack, cape, umbrella, hat) + per-tier weighting. v2 picks from 5 hardcoded personas with no overlays.
- [ ] **Walker count scales with population** — `MainScene.js MAX_WALKERS`. v1: `floor(pop / 10)` capped at 80. v2: hard 50. Big cities feel quieter than they should.
- [ ] **Collector walker road pathing** — `MainScene.js _spawnCollectorWalker`. v1 uses weighted Dijkstra (road=1, off-road=3) so collectors visibly traverse the road network. v2 walks a straight line through grass.
- [ ] **Partners: daily quota usage** — `TradePartnersTab.js`. v1 shows `b 5/10`, `s 3/7` per resource per trader. v2 shows `/day N` (the cap) but not how much you've used.
- [ ] **Partners: meets/misses gate visual** — `TradePartnersTab.js`. v1 colors each trader row with `tg-meets` or `tg-misses` based on policy gates. v2 has the "Best deals" banner but no per-row indicators.
- [ ] **Partners: trader card collapse state** — `TradePartnersTab.js`. v1 lets you collapse trader cards; state persists across panel refreshes. v2 always expands.
- [ ] **Black Market: inline quantity stepper** — `TradeBlackMarketTab.js`. v1 has -, qty, + buttons before commit. v2 uses `prompt()` modal.
- [ ] **Build menu: integer-ratio recipes with period labels** — `BuildTabPanel.js describeBuilding`. v1's `recipe_format.js` shows "5 timber / 2 min" (integer × period). v2 shows raw decimal rates.
- [ ] **Build menu: rich service input descriptions** — `BuildTabPanel.js describeBuilding`. v1: "Gates Townhouse (tier 3) within 5 tiles — consumes lumber + flour while staffed". v2: just the gating sentence.
- [ ] **Build menu: housing tier evolution hint** — `BuildTabPanel.js describeBuilding`. v1: "Shanty → Mud Hut → ... → Palace. Workers 2–100. Prereqs: T1 well, T2 food, ...". v2: "Citizens live here. Upgrades unlock as you provide services + food."
- [x] **Settings: rename district + rename city** (`v1-parity audit, commit 52/N`) — `SettingsPanel.js`. v1 has both; v2 missing. RPCs `rename_district(p_name)` + `rename_city(p_name)` exist on the server.
- [ ] **Inspector: service input requirements with period clarity** — `InspectorPanel.js`. v1: "Consumes 2 lumber + 2 flour per 2 min" (integer recipe). v2: rate only.
- [ ] **Inspector: refund amount pre-demolish** — `InspectorPanel.js`. v1 shows the refund $ in the confirm prompt; v2 just says "partial refund".

## TIER 4 — Low (polish / nice-to-haves)

- [ ] **Walker visual jitter** — `MainScene.js`. v1 per-walker scale (0.85-1.15) + hue (±18°) + bob period + waddle period.
- [ ] **Immigrant/emigrant overlays** — `MainScene.js spawnImmigrantWalker`. v1 rolls luggage/backpack/bindle/plain on each.
- [ ] **Paused building badge** — `MainScene.js`. v1 shows ⏸ overlay; v2 has no badge (suppresses animation correctly but no visual cue).
- [ ] **Resources: search/filter** — `CityResourcesTab.js`. v1 has prefix-match filter with live DOM hide.
- [ ] **Resources: category collapse persistence** — `CityResourcesTab.js`. v1 localStorage `city_resources_collapsed`.
- [ ] **Resources: per-category stock summaries** — `CityResourcesTab.js`. v1: "7 resources · 250 total" on category header.
- [ ] **Period toggle on Treasury + Resources** — `CityTreasuryTab.js` / `CityResourcesTab.js`. v1 has Today / Week / All-time. v2 hardcodes 24h.
- [ ] **Partners: trader description + transport mode badge + next-visit countdown** — `TradePartnersTab.js`. v1 surfaces all three on each card.
- [ ] **Bell log: 1.5s dedup window** — `BellLog.js`. v1 collapses identical events fired in rapid succession.
- [ ] **Inspector: trade-value row** — `InspectorPanel.js`. v1 shows "Trade value: $X/min" using best unlocked trader price.
- [ ] **Inspector: walker info card** — currently no walker tap → info flow.
- [ ] **Inspector: pollution + desirability tier qualification** — v1 shows "qualifies for Villa (needs ≥60, you're 72)".
- [ ] **Build menu: no-workers warning** — `BuildTabPanel.js`. v1 warns if placing this would exceed worker capacity.
- [ ] **Build menu: transport hub expansion context on first build** — v1 first-build copy.
- [ ] **Help: per-building Benefit one-liner + click-to-expand rows + recipe period labels** — `HelpModal.js`. v1 has rich interactive cards; v2 shows everything always.
- [ ] **Zoom-at-point preservation** — `MainScene.js _setupCamera`. v1 keeps world point under cursor stable during zoom. v2's `cam.setZoom` drifts.
- [ ] **Pinch-zoom prevention on iOS Safari** — `main.js`. v1 has explicit multi-touch handlers. v2 has gesturestart/change/end preventDefault but may need verification on Safari.

---

## Out of scope (or already-decided design changes)

- Trade policies moved from per-resource drilldown to Trade > Partners — keep v2's location.
- Treasury 24h-only window for transactions — v2's tighter scope is a feature.
- Tutorial-gated build menu — v2 has this; v1 doesn't. Keep v2.
- Tier-required field — v2's cleaner data model. Keep.

## Notes

- 89 vitest tests pass before this audit begins.
- Each Tier-1 / Tier-2 fix should ship with a regression test where reasonable.
- Use the existing commit prefix: `v1-parity audit, commit N+1/N: <description>`.
- Auto-push to origin/main after each commit per `feedback_auto_push.md`.
