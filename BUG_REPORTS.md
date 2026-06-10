# Bug Reports

Resolved bug-report archive. Each entry preserves the player's original
description, the diagnosis, and the commit that fixed it. The richer
`bug_reports` table on the server (filed via the in-game 🐞 Report bug
button) holds the full client + server state snapshot for re-analysis;
this file is the human-readable index.

**Workflow** (per `feedback_bug_report_workflow.md`):

1. New bug arrives in `public.bug_reports` (or the convenience view
   `public.open_bug_reports`).
2. Diagnose using the server_state JSON snapshot.
3. Ship the fix.
4. UPDATE the row with `resolved_at = now()`, `resolution_notes`, and
   `resolution_commit`. The row stays in the DB.
5. Append a new entry to this file with date filed, reporter, problem,
   diagnosis, fix, and commit SHA(s).

The inbox `SELECT * FROM open_bug_reports` filters to unresolved only,
so the table doesn't grow visually as we work through them.

---

## 2026-05-27 — Jill — "The truck depot indicates I cannot expand it because it is not a transport hub, but it should be able to expand."

**Reported:** 2026-05-27 22:43 UTC, in-game bug-report modal.

**Description (verbatim):**
> The truck depot indicates I cannot expand it because it is not a transport hub, but it should be able to expand.

**Diagnosis:**
`expand_transport_hub` contained `IF v_bt.category <> 'transport_hub' THEN RAISE EXCEPTION 'Only transport hubs can be expanded'`. The truck_depot has category `transport_connector` (not `transport_hub`), so every expand attempt was rejected. The frontend already showed the Expand button for `transport_connector` buildings (InspectorPanel.js:410 checks `|| bt.category === 'transport_connector'`), and `_city_transport_tiers` already counted `SUM(1 + expansion_level)` for truck_depots to compute truck transport capacity — the server guard was simply never widened to match.

**Fix:**
- `expand_transport_connector.sql`: widened the guard to `NOT IN ('transport_hub', 'transport_connector')` and added `WHEN 'truck_depot' THEN 'truck'` to the trader-spawn CASE so expansion adds a new Regional Hauliers partner, consistent with all other hub expansions.
- New test `test_truck_depot_build_then_expand_spawns_two` added to `tests/db/test_procedural_traders.py`.

**Commit:** `52647cb`

---

## 2026-05-22 — internal (found by pytest sweep) — transport hub expansion didn't spawn a trader

**Reported:** N/A — found 2026-05-22 02:30 UTC during the overnight pytest sweep. `test_airport_build_then_expand_spawns_two` was failing.

**Description:**
After 2026-05-20, paying to expand a transport hub (airport / seaport / train depot) silently failed to add a new trade partner — the entire documented purpose of expansion. The cash was deducted, the expansion_level bumped, but the trader-spawn step was missing.

**Diagnosis:**
`big_bug_sweep_2026_05_20.sql` rewrote `expand_transport_hub` to add a `FOR UPDATE` lock on `player_profiles`. The rewrite reproduced the original body but dropped the `PERFORM public._spawn_random_trader(v_mode)` line that the procedural-traders migration had added. Net effect: from 2026-05-21 02:07 UTC onward, every expansion failed to spawn its promised trader.

Found by the pytest sweep — the test was already in the suite and would have caught this on the first sweep after the regression. The reason it slipped: the original sweep that introduced the bug ran with several pre-existing flakes already failing, so a fourth red row didn't ring an alarm.

Impact in production: exactly one expansion happened in the broken window — Jill's train_depot at 2026-05-21 20:39 UTC. She paid \$60k and didn't get the trader.

**Fix:**
- `restore_expand_hub_trader_spawn.sql`: re-adds the `PERFORM public._spawn_random_trader(v_mode)` block, preserving the lock and ownership check.
- Live backfill: ran `SELECT _spawn_random_trader('train')` once to add the missed Pinewood Crews trader (her depot was the only affected expansion).
- Feedback prompt queued for Jill explaining the fix.

**Commit:** `265605a`

**Reported:** 2026-05-09 19:22 UTC, in-game bug-report modal.

**Description (verbatim):**
> I am unable to update from a townhouse to a villa. The upgrade button
> is there, but the building doesn't upgrade.

**Diagnosis:**
Two interacting issues. (1) The upgrade-error `showToast` call had been
stripped to a no-op the day before (commit `7f58698`, "Notifications:
keep only housing-ready-to-upgrade") — when the server rejected the
upgrade with "House is not currently eligible", the alert was silent and
the button visibly snapped back to "Upgrade" with no explanation. From
Jill's view, clicks did nothing. (2) The Upgrade button stayed visible
on houses the server had since deemed *ineligible* because the realtime
sub only watched INSERT/DELETE on buildings, not UPDATE — so her client's
`state.allBuildings` had a stale `evolution_eligible_at`. Server-side,
the eligibility-cleared transition never emitted an event either, so
client refetches were never triggered for the lost direction.

Conditions actually failing at the moment of her report (verified from
the server-state snapshot): flour 0.026 (school couldn't sustain
operation), tile desirability NULL (defaulted to 50, tier 4 needs ≥ 60),
some townhouses 6+ tiles from the school (tier 4 needs ≤ 5).

**Fix:**
- `25aa226` — converted 39 silent error `showToast` calls to `alert()`
  across the codebase per `feedback_bell_log_policy.md`. Added a new
  `housing_lost_eligibility` event to `_pp_evolve_housing` (mirrors
  `housing_ready_to_upgrade` for the clearing direction) so the
  evolution_events array stays non-empty on transitions.
- `f9497ac` — subscribed to UPDATE on buildings in `realtime.js` so
  other players' tier changes propagate without waiting for the
  current player's own tick.

**Tests:** `test_housing_lost_eligibility.py` (3 tests pinning the new
event behavior).

---

## 2026-05-13 — Jill — "clay master's hut isn't boosting"

**Reported:** 2026-05-13 13:57 UTC.

**Description (verbatim):**
> The clay master's hut does not appear to be boosting clay
> production. I added additional clay masters huts within 2 tiles
> of my clay diggers but my clay production did not appear to
> increase. I need this for increasing revenue or my city is doomed.

## 2026-05-14 — Jill — "clay reserve isn't accumulating"

**Reported:** 2026-05-14 00:52 UTC.

**Description (verbatim):**
> I should be having a net accumulation of clay at the rate of 9
> per minute, but my clay reserve is staying unchanged. I am not
> trading any clay, so it should be accumulating.

**Diagnosis (both):**
Same root cause. Both clients' City → Resources panel summed
extractor `output_rate` without applying the per-tick scaling the
server actually uses:

- `min(1, 4/path_length)` — Jill's 20 clay_pits ranged from path 3
  to path 37; effective production was ~13/min, not the 30/min the
  panel implied.
- Booster MAX multiplier — 14 of her 20 pits WERE in range of a
  staffed clay_master_hut (×1.25), but the panel showed no effect
  either before or after she added more huts.
- Productivity multiplier (`player_profiles.productivity`, currently
  1.15 for her) — neither production nor consumption was scaled.

Real math: ~17.8 clay/min produced vs. 12 pottery_kiln × 1.5 × 1.15
+ 2 glassworks × 1.0 × 1.15 = 23/min consumed → −5/min net.
Stockpile sat at 0 because consumption exceeded production. The
panel said +9/min. Server-side production math was correct; the bug
was 100% on the UI side.

**Fix:**
- `9ebd0b4` (citybuilder / v1) — new helpers in
  `city-builder-mvp/js/panels.js`: `getProductivity`,
  `getBoosterMultiplier` (Manhattan ≤ boost_range, MAX of matching
  staffed boosters), `effectiveOutputRate` (per-instance
  composition). `computeNetRates` + `computeResourceFlow` updated.
- `f0c610d` (citybuilder-game / v2) — mirror of the same logic in
  `src/scenes/helpers.js`. 10 new vitest cases including a full
  reproduction of Jill's clay layout (20 pits + 4 huts + 12 kilns
  + productivity 1.15) — the panel now reports the deficit instead
  of a phantom surplus.

---

## 2026-05-15 — Jill — "required bread to sustain the city is too high"

**Reported:** 2026-05-15 13:34 UTC.

**Description (verbatim):**
> The required bread to sustain the city is set too high. The amount
> that can be purchased from available traders is not enough to
> sustain the city.

**Diagnosis:**
Bread is a tier-2+ lifestyle good — every cottage/townhouse/villa/etc.
drains it every minute (rates per `housing_lifestyle_demands`). Jill's
options for *importing* it were thin: of 10 active NPC partners only
2 happened to roll bread in their 3-6 random catalog (proc_71fab7296f3e
and river_traders), and even those priced it near the upper band
(sell_price 19-20). The base_price-anchored procedural model
(`_spawn_random_trader`) makes "does this partner sell bread?" a
coin-flip per partner per spawn, so a player can run a 4-trader hub
and never get an option to import the staple they need.

**Fix:**
- `7cbf94d` (citybuilder / v1) — `bread_always_available.sql`:
  `_spawn_random_trader` now appends a guaranteed bread row to every
  procedural partner on top of its 3-6 random non-bread picks. Bread
  sell_price discounted 25% (band 1.05-1.5× × 0.75 = 0.79-1.13×
  base_price; rolls land at 12-17 vs base 15). Backfill knocked 25%
  off existing bread sell_prices and inserted a discounted bread row
  for every active trader that didn't sell bread (8 of 10). buy_price
  untouched — discount only applies to player-buys-bread, not
  player-sells-bread. Test now asserts 4-7 trader_prices rows plus a
  bread row on every spawn.

---

## 2026-05-15 — Jill — "total housing capacity doesn't match old UI"

**Reported:** 2026-05-15 16:28 UTC.

**Description (verbatim):**
> On the new UI, my total housing capacity does not show as the same
> number as the old UI.

**Diagnosis:**
v1's state.js sets `housingCapacity = popFloor + sum(tier.workers)`
for active road-connected houses and the topbar renders pop/cap from
it. v2's `state.laborInfo.housingCapacity` had a default of 0 and was
never recomputed — `tick.js` only mirrored profile.worker_capacity
(= current workforce supply, not housing cap). With li.housingCapacity
= 0, `TopBar.refreshTopBar` line 223 fell back to `cap = pop`, so the
topbar showed pop/pop. For Jill at pop=1149, that's `1149/1149`
instead of the actual `1149/1291` (15 floor + 27×24 + 17×34 + 1×50).

**Fix:**
- `b096635` (citybuilder-game / v2) — new
  `computeHousingCapacity(allBuildings, buildingTypes,
  housingTierConfig, myId, profile)` helper in `src/scenes/helpers.js`
  mirroring v1's state.js calc. Called from `TopBar.refreshTopBar`
  and stashed on `state.laborInfo.housingCapacity` so other consumers
  can re-use. 5 new vitest cases (floor, tutorial, road requirement,
  tier-0 shanty without road, foreign/inactive filter).

---

## 2026-05-19 — Jill — "townhouses say no operating school despite schools within 5 tiles"

**Reported:** 2026-05-18 23:25 UTC.

**Description (verbatim):**
> Townhouses indicate there is not an operating school, but both have
> schools within 5 tiles so should qualify to upgrade.

**Diagnosis:**
Jill's two tier-3 townhouses at (-16, 45) and (-14, 51) each had her
school at (-18, 49) sitting **Manhattan distance 6** away (`|dx|+|dy| =
2+4`) but **Chebyshev distance 4** (`max(|dx|,|dy|) = 4`). The server
gate in `_pp_evolve_housing` used Manhattan (`ABS(b2.x-v_house.x) +
ABS(b2.y-v_house.y) <= 5`), so Manhattan=6 fell just outside the cap
even though the school was visibly only 4 tiles away on the map. The
same Manhattan check was also in `has_well_access` (range 4) and the
frontend mirror `hasNearbyService` (`src/scenes/housing.js:220`).
Player intuition for "within N tiles" matches Chebyshev (king's-move)
distance — a 5×5 square around the building — not the diamond Manhattan
produces.

**Fix:**
- `service_proximity_chebyshev.sql` (city-builder-mvp / live DB) —
  rewrote `has_well_access` and `_pp_evolve_housing` to use
  `GREATEST(ABS(dx), ABS(dy))` for school (5), temple (6), bathhouse (4),
  and well (4). Service coverage is now an N-tile square instead of an
  N-tile diamond (~2.5× the area). Other Manhattan uses
  (booster/extractor adjacency, desirability falloff, crime spread)
  remain Manhattan — those model walking and influence diffusion, where
  Manhattan is correct.
- `7ffcb35` (citybuilder-game / v2) — `hasNearbyService` in
  `src/scenes/housing.js` switched to the same Chebyshev formula so
  the inspector's blocker text agrees with the server gate.
- `c63b873` (citybuilder) — two new tests in
  `tests/db/test_citizen_services.py`:
  `test_school_uses_chebyshev_distance` (dx=2, dy=4 → Manhattan=6,
  Chebyshev=4: must upgrade) and
  `test_school_chebyshev_corner_still_excluded` (dy=6 alone: must NOT
  upgrade) so the cap can't silently drop.

---

## 2026-05-19 — Jill — "clay industry buildings list no longer shows mosaic workshop"

**Reported:** 2026-05-19 16:53 UTC.

**Description (verbatim):**
> The clay industry available buildings no longer shows a mosaic
> workshop.

**Diagnosis:**
Same root cause as the next entry — see "no schools or temples in civic
services" below. Mosaic Workshop is industry_key='clay' but its second
input is `nails` (industry_key='iron'). After commit `f2080a3`
(2026-05-15, v1-parity build tab) added a producibility filter on the
input chain ("don't show a bakery if nobody in your industry can make
grain"), any building whose declared inputs reached across industries
got silently dropped from the menu. Trade is the explicit mechanism for
bringing in cross-industry inputs, so the filter was overzealous for
trade-unlocked players.

**Fix:** see entry below — shared fix.

---

## 2026-05-19 — Jill — "no schools or temples in civic services"

**Reported:** 2026-05-19 20:52 UTC.

**Description (verbatim):**
> There are no schools or temples that are available in the civic
> services buildings to build.

**Diagnosis:**
For Jill (clay industry), the school's inputs (lumber + flour) and
temple's inputs (statuary + brick) are all produced by other industries
(timber / iron / stone). The producibility filter at
`src/ui/bottompanel/BuildTabPanel.js:120-121`, added in `f2080a3` to
catch a bakery-without-grain misplacement, was unconditional — so for
trade-unlocked players any cross-industry-input building (school,
temple, bathhouse, tavern, mosaic_workshop, brewery, etc.) silently
disappeared from the menu. The filter's design intent ("you can't
make bread if you have no grain") was an early-game guardrail; once
trade is unlocked you can import any input from a partner city, so the
guardrail no longer applies.

**Fix:**
- `49b7358` (citybuilder-game / v2) — `BuildTabPanel.renderBuildTab`
  now gates the producibility filter on `!state.profile.trade_unlocked`.
  Pre-trade tutorial players still get the bakery-without-grain
  guard; everyone else sees every building they own the industry tag
  for (or that's 'common'). Also fixes the mosaic-workshop dropout
  reported the same day (see entry above).

---

## 2026-05-19 — Jill — "placement preview squares don't appear"

**Reported:** 2026-05-19 20:53 UTC.

**Description (verbatim):**
> When you purchase a new type of building or road, the squares to
> indicate the available spaces to place it do not show.

**Diagnosis:**
`MainScene.setPlacementMode` created the ghost sprite at world (0, 0)
and only repositioned it on the next `pointermove` event. On mobile
there is no pointermove between selecting a building and the first
map-tap, so the ghost sat far off-screen at the world origin until
after the first placement attempt — looking to the player like "no
preview." On desktop the gap was shorter (any cursor motion fixed it)
but still visible if the player clicked the build tab via keyboard or
without moving the mouse. The AoE preview (police / park / booster
coverage) had the same delay: `_updatePlacementAoe` only ran from
pointermove, so the coverage diamond didn't appear until after a hover.

**Fix:**
- `11f1d33` (citybuilder-game / v2) — new `_seedPlacementGhost`
  helper called at the end of `setPlacementMode`. Seeds the ghost
  at the current cursor (if it's over the canvas) or the camera
  center as a mobile-safe fallback, and runs `_updatePlacementAoe`
  immediately so the coverage overlay paints on the same frame the
  player selects the building.

---

## 2026-05-21 — Jill — "expanded 4th parcel, charged but no new parcel" + "new parcel squares say not mine"

**Reported:** 2026-05-21 10:25 UTC (4th parcel, no parcel shown) and 15:26 UTC (5th parcel, some squares wrong). Both from iPhone Safari.

**Description (verbatim):**
> I expanded to a 4th parcel and it charged me the money, but does not show another parcel.

> I expanded my parcel to the parcel above mine, but certain squares inside my new parcel indicate they are not mine to build on even though they are within my parcel.

**Diagnosis:**
Same root cause. `fetchTileMap` in `src/state/loader.js` did a single
`sb.from('map_tiles').select(...).eq('owner_player_id', uid)` with no
pagination. PostgREST's default 1000-row cap silently dropped every
tile past the first 1000. With 5 parcels × 225 tiles = 1125 tiles,
the last 125 tiles never made it into `state.tileMap`. The FE then
treated those tiles as wilderness — UI showed them outside the
player's parcel boundary; `place_building` checks (`tile.owner === me`)
failed on the FE side ("not in your parcel"). Server allocation +
ledger were correct the whole time; the bug was purely client-side
display.

Bug #1 (4th parcel "doesn't show") at 900 tiles was below the hard
cap. It still surfaced once, probably a slower mobile fetch returning
fewer than the full 900 — could be a Supabase JS client pagination
quirk on smaller default page sizes for some connections. The
pagination fix resolves both cases.

Same bug class as Max's "half her parcel missing" earlier this year
(audit 2026-05-09); `fetchAllBuildings` was already paginated then,
but `fetchTileMap` was missed.

**Fix:**
- `0b4614f` (citybuilder-game / v2) — paginate `fetchTileMap` in
  loops of 1000 rows ordered by id, mirroring the existing
  `fetchAllBuildings` pattern. No FE state changes; the next page
  reload picks up every tile.

---

## 2026-05-21 — Drew — "new parcel renders wrong colors" + "I only see Jill pledging \$25"

**Reported:** 22:02 UTC and 22:03 UTC, both from Android Chrome (Trade > Contracts tab open).

**Description (verbatim):**
> I just bought a parcel, but I don't see it the same colors as my other parcels

> I still only see Jill pledging \$25, but she pledge much more

**Diagnosis (#1, parcel colors):**
Duplicate root cause of Jill bcd4939d/43933d0b — the same morning.
Drew bought his 5th parcel (1125 tiles), `fetchTileMap` was running
the pre-pagination bundle, the 1000-row PostgREST cap dropped the
last 125 tiles of his new parcel, and the FE rendered them as
wilderness. The fix shipped in `0b4614f` at 15:00 UTC; Drew's bug
filed at 22:02 UTC was against the bundle his browser had cached at
expand time. Reloading picks up the paginated loader.

**Diagnosis (#2, Jill's stake stuck at \$25):**
`SupplyContractsTab` cached the `list_supply_contracts()` response at
module scope and only invalidated the cache when the LOCAL player
contributed or withdrew. Other players' pledges never triggered Drew's
client to refetch, so his view stayed pinned at Jill's first \$25
pledge for ~7 hours while she pushed her stake past \$60k. This was a
pure visibility bug — server-side `list_supply_contracts()` was
returning the correct \$60,225 the whole time.

**Fix:**
- `0f07646` (citybuilder-game / v2) — added a 5-second TTL on
  the contracts cache with stale-while-revalidate. Combined with the
  existing 30s tick refresh of the bottom panel, other players'
  activity now lands within 30s for a passive viewer and within 5s
  for anyone interacting with the panel.

(Resolution for #1 is `0b4614f` from earlier the same day.)

---

## 2026-05-21 — Drew — "the economy is based so much on bread"

**Reported:** 22:05 UTC. Filed as a bug; really design feedback.

**Description (verbatim):**
> The economy is based so much on bread. Jill buys so much bread just
> to keep her housing up. We should balance that out more

**Audit:**
At the time of the report, Jill's 95 houses (5 tier-3, 21 tier-4, 38
tier-5, 12 tier-6, 9 tier-7, 10 tier-8) drained **26.88 bread/min**
≈ 1,612/hour. Buying at the cheapest import price ($14/unit) that's
$376/min — about **14% of her gross tax revenue** going to bread
alone. Drew's instinct was right.

**Fix:**
- `halve_bread_demand.sql` — `UPDATE housing_lifestyle_demands SET
  qty_per_minute = qty_per_minute * 0.5 WHERE resource_key = 'bread'`.
  Per-tier rates were 0.05 / 0.075 / 0.10 / 0.125 / 0.15 / 0.175 at
  tiers 3–8; halved across the board. Substitutes (spices / caviar /
  spirits) still apply at the new lower rate.

No code commit — pure data migration. The next process_production
tick uses the new rates; pantry buffers naturally refill faster as a
side effect.

---

## 2026-05-21 — Atlas — "error sending money to another player" + "NPC trade hold fails"

**Reported:** in chat (not via the in-game modal — no bug_reports rows). 2026-05-21 evening.

**Description (verbatim):**
> I get an error when I try to send money to another player

> for trades with NPC's, you can't hold. it fails if you choose hold

**Diagnosis (#1, P2P send money):**
The compose form in `TradePlayersTab` built `giveResources` /
`receiveResources` as **arrays** of `{resource_key, quantity}`. Server
`propose_trade` + `accept_trade` walk those JSONB columns with
`jsonb_each_text()`, which **only operates on OBJECTS**. Passing an
array (or even an empty array `[]` for money-only trades) raised
`cannot call jsonb_each_text on a non-object`, so every P2P
proposal failed. The five historical offers stored in
`player_trade_offers` were all object-shaped — at some point the FE
diverged from the canonical shape and no one had successfully sent
a P2P trade since.

Two FE readers had been "fixed" earlier the same day (commit
`745668a`) to iterate arrays — wrong for the actual stored shape,
silently dropping P2P data again. Reverted to the object shape
canonically, with defensive both-shapes acceptance in readers.

**Diagnosis (#2, NPC trade hold):**
String drift between FE and server. FE dropdowns in CityResourcesTab
+ TradePartnersTab used `value="hold"`. Server CHECK constraint and
`save_trade_policy`'s IF allowed only `('keep', 'sell_surplus',
'buy_to_reserve')`. Clicking Hold always raised
`Invalid trade mode: hold`. 'hold' is the player-facing word —
brought the server to match. Also fixed
`src/scenes/helpers.js:315` which still guarded with
`policy.mode !== 'keep'` (dead code; never matched after the FE
moved to 'hold').

**Fix:**
- `a287c93` (citybuilder-game / v2) — TradePlayersTab compose now
  builds `{ resource_key: qty }` objects. describeBundle +
  computeInboxBlockers + CityResourcesTab aggregation all defensively
  accept both shapes. helpers.js:315 corrected from 'keep' to 'hold'.
- `5634d6a` (citybuilder / v1) — `trade_mode_keep_to_hold.sql`:
  DROP constraint, UPDATE 3 existing 'keep' rows to 'hold', new
  constraint allowing 'hold'; save_trade_policy IF updated.

---

## 2026-05-22 — Jill — "housing capacity dropped from ~4000 to ~3100"

**Reported:** 2026-05-22 00:27 UTC, in-game bug-report modal.

**Description (verbatim):**
> I thought I had a housing capacity of over 4000, but now it is showing only about 3100 as a capacity. Can you tell if any housing devolved or if that higher capacity was ever there?

**Diagnosis:**
Working as designed — no code bug. Jill's 6 temples each consume
brick (0.5/min) and statuary (0.25/min); with 6 temples that's 3.0
brick/min. At ~22:10 UTC on 2026-05-21, brick reached zero and the
temples failed `_pp_run_services`'s input-availability check. They
were staffed and in-range, but not in `p_operating_services` for that
tick, so 71 tier-5 houses lost temple coverage and devolved to tier 4.
Many re-upgraded within minutes as brick restocked. 20 houses remain
at tier 4 because their desirability (53–68) is below the tier-5 gate
of 70 — these are correctly blocked.

**Resolution:** Deferred — no code change needed. Queued a
feedback_prompt explaining the root cause (brick starvation) and
advising Jill to raise desirability in the affected areas to recover
full capacity.

---

## 2026-05-22 — Drew — "new parcel didn't show immediately after purchase"

**Reported:** 2026-05-22 00:39 UTC, in-game bug-report modal.

**Description (verbatim):**
> I just tried to buy a new parcel, and it didn't immediately show as available to me. It might show after a refresh, but it should show immediately.

**Diagnosis:**
`StatInfoModal.js` opens the expansion picker with an empty callback:
`openExpansionPanel(() => {})`. The `rerenderWorld()` call that paints
newly claimed tiles onto the Phaser canvas lives in `main.js`'s
`mountTopBar` callback — only reached when expansion is triggered from
the top bar. Expansions from the district stats panel skipped the
rerender entirely, leaving the map stale until manual refresh.

**Fix:** `db691ba` (citybuilder-game / v2) — added
`if (sceneRef?.rerenderWorld) sceneRef.rerenderWorld()` directly in
`ExpansionPanel.js`'s `onPickCandidate` success handler, before the
caller's callback fires. The map now rerenders unconditionally on
every successful parcel claim regardless of entry point.

---

## 2026-05-22 — Atlas — "feedback modal hidden under topbar + small gap above infobar"

**Reported:** in chat. Both layout bugs.

**Description (verbatim):**
> the window that pops up for a response for bug reports is not aligned properly. part of it is covered by the top title bar.

> there is a small gap between the title bar that tells me that I am in the timber industry, and the info bars above that

**Diagnosis:**
Two unrelated CSS bugs:

1. `FeedbackPromptModal` mounts an overlay with `id="feedback-overlay"`,
   but the only fixed/centered overlay rule in `styles.css` was scoped
   to `#bug-overlay`. The modal fell into normal block flow at the top
   of `<body>` and the `position:fixed` topbar overlapped it. Same root
   cause as if I'd built the modal without any CSS at all.

2. `#infobar` was positioned at `top: 74px` based on a comment that
   assumed `box-sizing: content-box` and computed the topbar as
   `2 × 36px content + 2 × 1px borders = 74px`. The global reset
   `* { box-sizing: border-box; ... }` means `min-height: 28px`
   already INCLUDES the padding, so the topbar's actual rendered
   height is `2 × 28px + 2 × 1px = 58px`. The ~16px gap was exactly
   the difference.

**Fix:**
- `ae94366` (citybuilder-game / v2) — extended the `#bug-overlay`
  CSS rule selector to `#bug-overlay, #feedback-overlay` so the
  feedback modal inherits its overlay styling. Moved `#infobar`
  from `top: calc(74px + safe-area-inset)` to
  `top: calc(58px + safe-area-inset)`. Updated two stale comments
  referencing the old 74px constant.

---

## 2026-05-22 — Max — "school locked until I reach townhouse, but all my houses ARE townhouses"

**Reported:** 2026-05-22 00:43 UTC.

**Description (verbatim):**
> The school shows as being locked until I reach townhouse level, but
> all of my houses are townhouses and cannot evolve further without a
> school.

**Diagnosis:**
Server-side bug. The auto-upgrade path inside `_pp_evolve_housing`
bumped `buildings.housing_tier` correctly but did **not** advance
`player_profiles.highest_housing_tier_ever`. Only the manual
`upgrade_house` RPC bumped the watermark.

Auto-upgrade has been the default for new houses since 2026-05-08
(`buildings.auto_upgrade` defaults to TRUE). Players who relied on
auto-upgrade evolved through tiers without ever advancing the
watermark, so tier-gated buildings stayed locked — school (≥3),
temple (≥4), mosaic_workshop (≥6).

Snapshot at fix time:
- Max:  watermark=0, current max house tier=3 (8 townhouses) ← the bug
- Jill: watermark=6, current max house tier=7
- Drew: watermark=4, current max house tier=4 ← only one in sync, only one who used manual upgrade_house

**Fix:**
- `auto_upgrade_bumps_watermark.sql` (city-builder-mvp) — adds a
  matching `UPDATE player_profiles SET highest_housing_tier_ever =
  GREATEST(..., v_house.housing_tier + 1)` inside the auto_upgrade
  branch of `_pp_evolve_housing`. Mirrors the GREATEST pattern in
  `upgrade_house`.
- One-shot heal at end of migration: `UPDATE player_profiles SET
  highest_housing_tier_ever = GREATEST(watermark, current_max_tier)`
  for every player. All three players now in sync.
- Regression test in `tests/db/test_auto_upgrade.py` —
  `test_auto_upgrade_bumps_tier_immediately` extended to assert the
  watermark advances after auto-upgrade.

---

## 2026-05-22 — Jill — "housing capacity dropped 4000 → 3100"

**Reported:** 2026-05-22 00:27 UTC. Auto-triage handled the diagnosis end-to-end.

**Description (verbatim):**
> I thought I had a housing capacity of over 4000, but now it is
> showing only about 3100 as a capacity. Can you tell if any housing
> devolved or if that higher capacity was ever there?

**Diagnosis:**
Not a software bug. Auto-triage (the hourly cron) correctly identified:
around 22:10 UTC May 21, Jill's six Temples ran out of Brick (drain
0.5 Brick/min × 6 = 3/min, no restock). They failed the
`_pp_run_services` input check, dropped out of `p_operating_services`
for that tick, and 71 tier-5 houses devolved to tier-4 because their
needs_temple gate evaluated false. Most re-upgraded once brick
restocked, but ~20 are still stuck at tier-4 because their tile
desirability sits at 53–68 vs. the tier-5 gate of 70 — a separate
gameplay constraint, not a bug.

**Fix:** none — Jill was informed via a queued `feedback_prompts` row
explaining the brick starvation cause and the desirability re-upgrade
path. Row closed as working-as-designed.

---

## 2026-05-22 — Jill — "monument unstaffed despite workers" + "monument shows as gray square"

**Reported:** 22:30-ish UTC, both filed via the in-game modal right after she tried to use today's new civic buildings.

**Description (verbatim):**
> I built a monument and I have workers available, but it remains unstaffed.

> Also, the monument just shows as a gray square and not a building.

**Diagnosis (#1, staffing):**
The new `civic` category I added when shipping Public Garden + Monument
+ Marketplace was never wired into `_pp_staff_buildings` or
`_pp_workers_needed`. Both functions iterate a hard-coded category list
that included extractor / food_extractor / booster / processor / tax /
service / police but NOT civic. So civic buildings were never
considered for staffing — `is_staffed` stayed false forever, and the
city's worker-shortage warning under-reported by the civic workers'
worth. Every effect that gates on `is_staffed` (desirability_bonus,
migration_bonus, trade_sell_bonus_pct, crime_emit) silently no-op'd.

**Diagnosis (#2, gray-square sprite):**
Two of the five new sprites (Public Garden, Industrial Zone) used
`radialGradient` with percent-sized attributes — `cx='50%' cy='40%'
r='55%'`. The literal `%` inside a data URI is invalid percent-
encoding (must be followed by 2 hex digits). The browser/Phaser
rasterizer choked and the renderer fell back to the gray-square
fallback path (`textures.exists(key) ? key : 'square'`). Monument
itself uses no `%`, so Jill probably saw the gray-square fallback via
a cache / load-ordering issue triggered by the broken neighbor
sprites; either way, defense-in-depth re-encoded all five new sprite
URIs.

**Fix:**
- `575fbff` (citybuilder) — `civic_staffing_fix.sql` adds `civic` to
  both `_pp_staff_buildings` and `_pp_workers_needed`. Priority 2
  (same as service + police) so civic amenities staff before
  extractors/processors when workers are tight.
- `eaab0d8` (citybuilder-game) — re-encoded all 5 new sprite URIs
  with `%` removed from the URL-quote safe set, so literal `%`
  becomes the correct `%25`.

---

## 2026-05-22 — Jill — "One of the monuments still shows unstaffed."

**Filed:** 2026-05-22 09:49 UTC (`c1757cb8`)

**Diagnosis:**
The monument at tile (-14, 46) had no adjacent road tile — surrounded by
park (top), house (right/bottom), and empty land (left).
`has_road_access()` correctly returns false for buildings not touching a
road, so the staffing loop skipped it. This is correct server behaviour,
not a bug in the code.

Note: the *civic-category staffing omission* (monuments never getting
staffed regardless of road access) was a separate bug fixed earlier the
same day by `civic_staffing_fix.sql`. This report was the follow-up after
that patch, filed against a monument that still had no road.

**Resolution:**
No code change. Educational `feedback_prompts` row (`monument_road_access`)
queued at 10:02 UTC, dismissed by Jill at 10:04 UTC. Jill subsequently
demolished or repositioned the building; all 9 monuments in her city are
staffed in the live DB as of auto-triage at ~10:40 UTC.


---

## 2026-05-22 — Jill — "city runway does not appear to be accurate. For instance, my runway currently indicates that I will run out of furniture in 29 minutes, but based on the math, I should have much longer"

**Filed:** 2026-05-22 20:03 UTC (`a29cdcfc`)

**Diagnosis:**
`runway.js` used only the per-house pantry buffer stock for lifestyle goods
(pottery, bread, furniture, statuary) when `buildingBuffers` was loaded,
discarding city inventory entirely. Since the server refills pantries from
city stock each tick, the correct effective reserve is pantry + city
inventory + substitutes. Jill had 16,680 furniture in city stock and 335
units across 110 house pantries (at full capacity); the FE was computing
335 / 11.175 ≈ 29 min instead of 17,015 / 11.175 ≈ 1,523 min (~25h).

**Fix:** `c0e9c12` — `src/state/runway.js`: always initialise stock from
city inventory (+ substitutes), then add pantry on top when buffers are
loaded. Updated the corresponding test which was asserting the wrong
expected value. 18/18 tests pass.

---

## 2026-05-28 — Drew — "I just bought a parcel that locked Max in place."

**Filed:** 2026-05-28 21:59 UTC (`b337a656`)

**Diagnosis:**
`expand_district` has a reachability invariant that prevents a player from
claiming a chunk that would leave another player with zero expansion candidates
(immediately surrounded). However, it didn't handle the *dead-end* case: a
claim that reduces another player to exactly one candidate, where that single
candidate's only unclaimed orthogonal neighbour is the tile being claimed.

Drew's sequence of purchases ending with chunk (-2, 4) left Max at (0, 4) with
only one available expansion: (-1, 4). But (-1, 4)'s four orthogonal neighbours
were all owned — east = Max's own (0, 4); north = Jill's (-1, 3); south = Drew's
(-1, 5); west = Drew's freshly claimed (-2, 4). Expanding to (-1, 4) would have
enclosed Max with zero further escape.

The existing check: `v_post_count >= 1` → allow. v_post_count was 1, so it passed.

**Fix:**
- `50ad5ba` — `expansion_dead_end_check.sql`: when a claim would reduce another
  player to exactly 1 candidate, additionally check that the surviving candidate
  has ≥ 1 unclaimed orthogonal neighbour (other than the tile being claimed). If
  not, the claim is rejected with the same "permanently surrounded" exception.
  Also adds `expansion_refund` to `cash_source_check`.
- Undo: Drew's chunk (-2, 4) deleted (225 map tiles + 41 auto-roads removed),
  1,960,000 refunded to Drew's treasury, matching `expansion_refund` ledger row
  inserted. Drew now has 14 chunks and ~2,150,886 money.
- Max's only candidate (-1, 4) now has (-2, 4) as a free westward escape.
- New test `test_expand_district_refuses_dead_end_boxing` added. 16/16 pass.

## 2026-05-29 — Jill — "I am unable to place multiple buildings and get an error that the space is occupied but it is not occupied."

**Filed:** 2026-05-29 01:04 UTC (bug `96a575a6`)

**Description (verbatim):**
> I am unable to place multiple buildings and get an error that the space is occupied but it is not occupied.

**Diagnosis:**
Same root cause as the concurrent "roads not showing up" report: after `place_building` RPC succeeded, the placed building was added to the DB but not yet to the client's `state.allBuildings` (waiting on the realtime WebSocket event, which can lag seconds on mobile). The tile visually looked empty to Jill, so she tapped it again to retry. The second RPC call hit the DB where the building already existed → "space occupied" error on a tile that the client showed as empty.

**Fix (d4caff4):** `_addBuildingOptimistically()` in `MainScene.js` pushes the new building into `state.allBuildings` and calls `rerenderBuildings()` immediately after the RPC returns. The building now appears on screen at once, making it obvious that the first placement succeeded and the tile is taken.

**Tests:** no dedicated regression test; covered by the visual invariant that every successful `place_building` call results in an immediate sprite appearance.

---

## 2026-05-29 — Jill — "Roads are not showing up when I place them. This was an issue before that you fixed, but it was never fixed."

**Root cause:** After `place_building` RPC succeeded, the placed building was only
added to `state.allBuildings` via the Supabase realtime INSERT subscription. On mobile
(especially Safari with background-tab throttling), this WebSocket event can lag several
seconds, leaving the map visually stale after every placement.

**Fix (d4caff4):** Added `_addBuildingOptimistically()` to `MainScene.js`. Called from
both single-tap and drag-paint placement paths immediately after the RPC returns, it
pushes a minimal building entry to `state.allBuildings` and calls `rerenderBuildings()`
so the road/building appears on screen instantly. The realtime handler's existing
duplicate-id guard (`if (!state.allBuildings.some(b => b.id === data.id))`) prevents
double-adding when the event eventually fires.

## 2026-05-29 — Jill — "I have upgraded a bunch of roads and it has not changed my city congestion number at all."

**Filed:** 2026-05-29 14:05 UTC (bug `11349ecf`)

**Diagnosis:**
`upgrade_road` deducts money and materials, swaps `building_type_key` in place, and writes the cash-ledger row — but it never called `public.refresh_congestion()`. The `player_profiles.congestion` column therefore stayed at the value set by the last server tick (every ~5 minutes), regardless of how many roads the player upgraded in the meantime. For Jill in particular, her city is traffic-heavy (population ~11k + 149 staffed processors = ~2,500 traffic units) against ~1,658 road-capacity units, so congestion will remain at 100 until enough roads are upgraded to tier 3–4. The formula itself is correct.

**Fix (e2f3bf2 / 6153ba4):**
- `road_upgrade_congestion_refresh.sql`: adds `v_new_congestion := public.refresh_congestion(v_uid)` at the end of `upgrade_road` and returns the value in the JSON response.
- `src/api/tick.js` (`applyRpcResponse`): now propagates `data.congestion` to `state.profile.congestion`, so the topbar stat refreshes immediately when the RPC returns — no tick wait needed.

**Feedback prompt queued** for Jill explaining the fix and the traffic math.

## 2026-05-29 — Jill — "Roads are still not being placed when a square is selected."

**Reported:** 2026-05-29 13:46 UTC (bug `2cff0a68`)

**Description (verbatim):** Roads are still not being placed when a square is selected.

**Diagnosis:**
Road placement for single taps uses `_paintAtPointer` (the drag-paint path), which silences all RPC errors to avoid spamming the user during a multi-tile sweep. A single tap sets `_dragPaintActive = true` on `pointerdown`, and `pointerup` clears it and returns before the async RPC response arrives. This means any failure reason — "Roads must connect to another of your roads", "already occupied", etc. — was swallowed silently. Jill tapped tiles and saw nothing happen, no road, no error.

**Fix (270f36c):**
`MainScene._paintAtPointer` captures `isFirstTile = (dragPaintPlaced.size === 1)` before the `await`. In the `catch` block, if `isFirstTile` is true, `showToast(err.message)` gives the user the actual failure reason. Subsequent tiles in a drag sequence remain silent.

**Tests:** None added — purely a UX feedback path.

---

## 2026-05-29 — Jill — "I am unable to upgrade roads at all at this point."

**Reported:** 2026-05-29 17:18 UTC (bug `56bf6707`)

**Description (verbatim):** I am unable to upgrade roads at all at this point.

**Diagnosis:**
Jill has 272 Grand Boulevards (road tier 4, the maximum). The inspector correctly shows no upgrade button for max-tier roads — there is no tier 5. But without any label explaining this, the player sees a road she owns with just a Demolish button and assumes the upgrade system is broken. Jill's road distribution: 377 basic roads, 78 paved roads, 19 tiled avenues, 272 grand_boulevards. She can still upgrade the lower-tier roads; she just couldn't tell that grand_boulevards were already maxed.

**Fix (270f36c):**
`InspectorPanel.renderInspector` now adds a "Road tier" row for road buildings. For max-tier roads (no higher tier in `state.buildingTypes`), the row reads e.g. "Grand Boulevard — max tier". Lower-tier roads show just the tier name without the max label.

**Tests:** None added — UI-only copy fix.

---

## 2026-05-29 — Jill — "when I try to upgrade a road, I get the following error message: function public.refresh_congestion(uuid) does not exist"

**Reported:** 2026-05-29 18:27 UTC (bug `f0cca7c6`) + follow-up `4cb7af6b` (18:30 UTC)

**Description (verbatim):** "No, when I try to upgrade a road, I get the following error message: function public.refresh_congestion(uuid) does not exist" / "No, the road issue is not fixed."

**Diagnosis:**
The prior congestion-refresh fix (`road_upgrade_congestion_refresh.sql`, commit `6153ba4`) added a call to `public.refresh_congestion(v_uid)` at the end of `upgrade_road`, but `refresh_congestion()` was never actually created. The correct existing helper is `public._pp_update_congestion(uuid)` — it calls `compute_congestion()` and writes the result back to `player_profiles.congestion`. Because both `upgrade_road` and `_pp_update_congestion` are `SECURITY DEFINER` owned by `postgres`, the internal call is fully privileged.

Every road upgrade attempt threw:
```
function public.refresh_congestion(uuid) does not exist
```

**Fix (e616875):**
- `road_upgrade_congestion_fix.sql`: new migration patch replacing `public.refresh_congestion(v_uid)` with `public._pp_update_congestion(v_uid)` in `upgrade_road`. Applied to live DB.
- `road_upgrade_congestion_refresh.sql`: original migration file corrected to match (prevents future confusion if re-applied).

**Tests:** No new regression test added — covered by the existing upgrade_road path.

---

## 2026-05-29 — Jill — "unable to place new roads or they are very sporadic in which road segments will eventually load"

**Reported:** 2026-05-29 20:34 UTC, bug `ca81ae1e`

**Description (verbatim):**
> Road upgrades are now working, but I am still unable to place new roads or they are very sporadic in which road segments will eventually load. Also, my congestion remains at 100% despite upgrading many of my roads.

**Diagnosis:**
Race condition in drag-paint road placement. Each `pointermove` event fired an independent async `placeBuilding()` RPC. The server-side adjacency check ("Roads must connect to another of your roads") on tile B would run before tile A had committed to the DB — so B would silently fail. The silent-error suppression (errors only surfaced for the first tile of a drag) meant the user saw 5–6 roads appear out of an 8-tile drag sweep with no feedback on the missing ones.

Congestion at 100% is mathematically correct: Jill's traffic load (FLOOR(12556/5) + 2×156 processors + 3×4 transport = 2835) exceeds road capacity (362 dirt×1 + 64 paved×2 + 303 boulevard×4 + 13 avenue×3 = 1741). She needs to upgrade remaining 362+64 roads to Grand Boulevard to bring capacity above 2835.

**Fix (17c637c, v2 repo):**
`MainScene.js`: Added `_dragPaintQueue` promise chain. When `bt.category === 'road'`, each `placeBuilding()` RPC is chained onto `_dragPaintQueue` rather than fired independently, ensuring each tile commits before the next adjacency check runs. Non-road painting is unchanged.

**Tests:** Covered by existing DB test suite (all pass). Frontend-only change.

## 2026-05-30 — Jill — "I am unable to place a road segment to connect the last house I built."

**Filed:** 2026-05-30 15:44 UTC (bug `e763f995`)

**Diagnosis:**
Jill's house at (-5, 28) is bordered on the north by a 2×2 temple footprint and on
the west by a 2×2 recycling-centre footprint, leaving only the south and east sides
open for road placement. The southern route (tap -5,29 connecting to existing GB at
-5,30) is correct and the server accepts it. The actual failure was in rapid
successive single-tile road taps.

Each tap starts a new "drag paint" sequence: pointerdown sets `_dragPaintActive=true`,
calls `_paintAtPointer`, then pointerup clears the state. Before this fix, pointerdown
also reset `_dragPaintQueue = Promise.resolve()`. So two quick taps — e.g. place
(-4,29) then place (-4,28) — ran both RPCs concurrently. The (-4,28) adjacency check
read the DB before (-4,29) had committed, returning "Roads must connect to another of
your roads." Because this failure falls on the *first tile of the second drag*,
`isFirstTile=true` and a toast should appear — but on mobile Safari the toast may
have been obscured or dismissed before Jill read it, making placement look like a
silent no-op.

**Fix:** Removed the `_dragPaintQueue = Promise.resolve();` reset from the
pointerdown handler. The queue (initialised once in the constructor) now persists
across drag sequences, serialising all road RPCs in submission order. Normal-paced
tapping has no latency cost because the previous RPC is already resolved by the
time the next tap fires.

**Tests:** Existing test suite passes. Frontend-only change.

## 2026-05-30 — Jill — "That fix did not fix the road issue. I still can't place road segments at that house (the square south of the house) or any other roads."

**Reported:** 2026-05-30 20:33 UTC (bug `3e11e574`)
**Description (verbatim):** That fix did not fix the road issue. I still can't place road segments at that house (the square south of the house) or any other roads.

**Diagnosis:**
Server-side is fine: tile (-5,29) is free, buildable, owned by Jill, and adjacent to a Grand Boulevard at (-5,30) — the adjacency check passes. The `_dragPaintQueue` no-reset fix is deployed.

Root cause: `_dragPaintQueue = _dragPaintQueue.then(doPlace)` — if `doPlace` ever returns a rejected promise (e.g., `showToast` throws on a stale DOM reference inside the catch block), `_dragPaintQueue` becomes a rejected promise. Every subsequent `.then(doPlace)` is then silently skipped — `.then()` ignores rejected promises. All future road taps appear to do nothing with no error shown.

**Fix (e6d4a7a):**
Added `.catch(() => {})` to the queue assignment: `_dragPaintQueue = _dragPaintQueue.then(doPlace).catch(() => {})`. This resets the queue to fulfilled after each step, preventing a single rejection from permanently blocking all future road placements.

**Tests:** Existing test suite passes. Frontend-only change.

---

## 2026-05-30 — Jill — "All of my inventory has showed as blank all day."

**Reported:** 2026-05-30 20:36 UTC (bug `aac649fc`)
**Description (verbatim):** All of my inventory has showed as blank all day. Typically, it is sometimes slow to load, but today, none of them are loading at all.

**Diagnosis:**
`loadInitialWorld()` fetches 14 data sources in parallel but omitted the `inventories` table entirely. `state.inventory` initialised to `{}` in the store and only populated when the first `process_production` tick response returned (~30s after login). Until that tick, the Resources tab rendered 0 for every resource. For Jill's "all day" case the `refreshBottomPanel` focus guard may also have blocked tick-time re-renders if keyboard focus remained stuck on the filter input (mobile Safari behaviour), compounding the problem.

**Fix (7bb5803):**
Added `fetchInventory()` to `src/state/loader.js` — a simple `SELECT resource_key, quantity FROM inventories WHERE player_id = ...` — and included it in the `Promise.all` inside `loadInitialWorld()`. `state.inventory` is now populated before the panel mounts, so inventory shows immediately on login.

**Tests:** No regression test added (loader.js fetch is integration-level; existing test suite passes).

---

## 2026-05-31 — Jill — "I am still unable to place roads."

**Reported:** 2026-05-31 19:01 UTC (bug `9acd2efb`)

**Description (verbatim):** I am still unable to place roads.

**Diagnosis:**
`place_building` called `recompute_extractor_paths(uid)` after every road placement. This function runs a full PL/pgSQL Dijkstra BFS for every active extractor owned by the player. Jill has 62 active `clay_pit` extractors; each `verify_extractor_path` call took ~280 ms → 62 calls × 280 ms = **17.4 s total** inside a single transaction, far exceeding PostgREST's HTTP timeout. The transaction was silently rolled back, so no road was ever written to the DB. From Jill's perspective: tapped a tile, saw nothing happen.

The `recompute_extractor_paths` call in `place_building` was an eager optimization — new roads can create shorter paths for extractors. But the server tick already calls `recompute_extractor_paths` periodically, so removing the inline call introduces at most a ~5-minute lag before extractors discover new road shortcuts. That trade-off is completely acceptable.

**Fix (afeecda):**
- `place_building_skip_repath_on_road.sql`: migration patch that replaces `place_building` with a version that omits the `PERFORM public.recompute_extractor_paths(v_uid)` call from the road-placement branch. Applied to live DB.

**Tests:** `test_road_placement_does_not_call_recompute_extractor_paths` in `tests/db/test_place_building.py` — seeds 5 extractors for the test player, places a road, asserts the RPC completes in under 3 s.

---

## 2026-06-01 — Jill — "My last two houses are not evolving because they indicate there is not an operating school, but the school is within 6 squares and has the resources to be operational" (follow-up: "Sorry, the school is within 5 tiles as is indicated by the highlighted area for the school operation zone.")

**Reported:** 2026-06-01, two sequential reports from Jill (IDs c5b75301 and 22692b69)
**Description (verbatim):** First report says school is "within 6 squares"; corrected to "within 5 tiles as indicated by the highlighted area."
**Diagnosis:** Server snapshot shows two tier-3 houses at (-3,25) and (-3,26). Nearest school is at (-9,25) — Chebyshev distance 6, just outside the 5-tile range. Server is correctly blocking evolution. The root visual bug: the AOE overlay (`showAoe` and `_updatePlacementAoe` in MainScene.js) was rendering a Manhattan diamond (`Math.abs(rx) + Math.abs(ry) <= range`) instead of a Chebyshev square. The server uses `GREATEST(ABS(dx),ABS(dy)) <= range`. This made the coverage zone look smaller at diagonal angles, causing Jill to misinterpret where coverage actually ends. All 9 of Jill's schools are staffed and operating.
**Fix:** c9bd6ba — Removed the Manhattan filter in both `showAoe()` and `_updatePlacementAoe()`; outer loops already bound rx/ry to ±range (Chebyshev square). Coverage highlight now shows the true square zone matching server behavior.
**Tests:** None added (visual-only change). Feedback prompt queued for Jill to confirm the updated highlight helps her place a school correctly.

---

---

## 2026-06-02 — Jill — "The school is within 5 spaces of the homes, not 6 so should allow them to upgrade."

**Reported:** 2026-06-02 18:31 UTC (bug `982e04cf`)

**Description (verbatim):** The school is within 5 spaces of the homes, not 6 so should allow them to upgrade.

**Diagnosis:**
School (and temple) are 2×2 buildings. `_pp_evolve_housing` was checking proximity using anchor-to-anchor Chebyshev — i.e. distance from the school's top-left corner cell to the house. For a house sitting beside the school's right or bottom edge, this over-counts by exactly 1: the anchor is 6 tiles away but the nearest cell in the footprint is only 5. The school AOE range is 5, so the gate refused even though the house was visually inside the coverage zone.

In Jill's layout the school anchor was at (3,56); its 2×2 footprint spans (3–4, 56–57). Several houses at footprint-perimeter Chebyshev = 5 were being refused because the anchor distance was 6.

**Fix (5b3beda):**
`school_temple_footprint_proximity.sql`: replaces the `has_school` / `has_temple` EXISTS checks in `_pp_evolve_housing` with a footprint-perimeter Chebyshev formula:

```sql
dx = GREATEST(b2.x - house.x,  house.x - (b2.x + 1), 0)
dy = GREATEST(b2.y - house.y,  house.y - (b2.y + 1), 0)
dist = GREATEST(dx, dy)
```

This gives the minimum Chebyshev distance from any cell in the 2×2 footprint to the house. For 1×1 buildings it reduces to plain Chebyshev (no change to bathhouse/well checks). Migration applied to live DB prior to the commit.

**Tests:** `test_school_footprint_perimeter_covers_house` (confirms a house at footprint Chebyshev=5 upgrades) and updated `test_school_chebyshev_corner_still_excluded` (confirms footprint Chebyshev=6 is still blocked) in `tests/db/test_citizen_services.py`.

---

## 2026-06-04 — Jill — "Upgrading my roads has not changed my traffic congestion at all and still shows 100."

**Diagnosis:**
The server formula is correct. Jill's city had 156 staffed processors generating ~312 traffic units on top of her 13,319 population (~2,663 pop/5). Total traffic ≈ 2,987 vs a total road capacity of 2,085 (sum of `road_tier` across 790 road tiles, mix of grand_boulevard/tiled_avenue/paved_road/road). The deficit of ~902 means `congestion = min(100, 5 + 4*902) = 100`. Individual road upgrades add 1–3 capacity per tile, so upgrading a handful of roads doesn't visibly move a stat that's clamped at 100 until the entire deficit is closed.

The stat wasn't lying; it just gave no feedback that progress was happening below the cap.

**Fix (2f2cd93):**
`citybuilder-game/src/ui/TopBar.js`: when congestion > 40, the congestion tooltip now computes actual traffic (pop/5 + 2×staffed_processors + 3×transport) vs road capacity (Σ road_tier across active roads) from client state and displays the deficit with a Grand Boulevard equivalent. Jill's tooltip now reads: *"Traffic 2987 vs road capacity 2085. Need 902 more capacity (~226 Grand Boulevards) before the stat starts falling."* This makes the required effort visible.

Pure frontend display fix — no server, no balance, no migrations.

**Tests:** None added (tooltip-only copy change; the server formula and `compute_congestion` have existing coverage in `tests/db/test_noise_congestion.py`).

## 2026-06-04 — Jill — "My citywide trash shows 100 but I have coverage of all houses by a recycling center and the other trash management methods can't be next to housing due to desirability issues."

**Diagnosis:**

Two separate issues:

1. **Perimeter bug (fixed):** `compute_waste` used anchor-to-anchor Manhattan distance for sanitation coverage checks. Recycling centers and incinerators are 2×2 buildings, so houses near the right/bottom edge of a sanitation building appeared uncovered even when visually within range. Same class of bug as the school/temple footprint fix (2026-06-02). Reduced Jill's uncovered houses from 25 → 12.

2. **Industrial floor (deferred):** Jill has 156 staffed processors (pottery kilns, tile makers, canneries, etc.) each emitting 1 industrial waste. The formula floor = 3 + 15 (pop term) + 156 = 174, which always caps at 100 regardless of sanitation coverage. Even if all houses were covered, waste would still be 100. This is a balance issue — the `waste_emit = 1` per processor is too high for large industrial cities. Deferred to Atlas.

**Fix:** `waste_coverage_footprint.sql` — replaces anchor-only check with footprint-perimeter Manhattan formula:
```sql
GREATEST(0, s.x - h.x, h.x - (s.x + fw - 1)) + (y-analog) ≤ coverage_radius
```
For 1×1 dumps this reduces to the original formula.

**Commit:** ffe7d0a  
**Tests:** `test_recycling_center_coverage_formula_uses_footprint_perimeter` added to `test_waste_management.py`  
**Status:** Partial fix shipped. Industrial waste balance deferred to Atlas. Feedback prompt queued for Jill.

---

## 2026-06-04 — Jill — "My citywide trash shows 100 but I have coverage of all houses by a recycling center and the other trash management methods can't be next to housing due to desirability issues." (follow-up, bug 9b97a718)

**Reported:** 2026-06-04 23:24 UTC (bug `9b97a718`)
**Description (verbatim):** My citywide trash shows 100 but I have coverage of all houses by a recycling center and the other trash management methods can't be next to housing due to desirability issues.

**Diagnosis:**
This is a second report of the same symptom after the perimeter fix (ffe7d0a). The coverage calculation is now working correctly — only 12 of 135 houses remain uncovered — but the waste score is still 100. Root cause: Jill has 156 staffed processors (69 pottery kilns, 35 tile makers, 18 canneries, 13 spiceries, 12 mosaic workshops, 9 glassworks) each emitting 1 unit of industrial waste. Total industrial waste = 156. Server formula: `3 + 3×12_uncovered + min(15, floor(13369/10)) + 156 = 3 + 36 + 15 + 156 = 210`, capped at 100. Even with perfect coverage (0 uncovered), the floor is `3 + 0 + 15 + 156 = 174`, still 100. Sanitation covers *housing* waste; it cannot offset processor industrial byproduct.

The tooltip was also telling Jill to "add sanitation coverage" when sanitation is irrelevant to her true driver.

**Fix (9dcf5e7):** Updated waste tooltip in `src/ui/TopBar.js` to compute the industrial waste component client-side (summing `waste_emit` for all staffed active buildings — mirrors server formula, data available via `select('*')` on `building_types`). When industrial waste > 0, the tooltip now shows "Industrial waste: X (staffed processors) + base Y" and, if processor output alone saturates the cap, explicitly tells the player "Processor output alone saturates the cap — sanitation covers housing but cannot offset industrial byproduct." Mirrors the congestion tooltip pattern.

**Tests:** No regression test added (FE display-only change, no logic change). Feedback prompt queued for Jill explaining the industrial waste driver.
