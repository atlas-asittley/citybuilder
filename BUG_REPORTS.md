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

## 2026-05-29 — Civic Metrics Expansion follow-ups (Jill ×3, Drew ×1)

Four reports landed right after the expansion went live — three from Jill
playing with it, one from Drew. All four resolved.

**Jill — "let me upgrade a road in place instead of demolish + rebuild"** (e2b47efb).
A feature gap I'd flagged in the design doc ("no upgrade RPC"). Fix: added
`upgrade_road(building_id, target_key)` (charges the target tier's cash +
materials, writes the cash-ledger row, swaps `building_type_key` in place,
keeps connectivity) + an inspector "Upgrade → <tier>" button with optimistic
repaint. Commits v1 `27a9e7c`, v2 `5554397`. Tests `test_road_upgrade.py` (4).

**Jill — "can't place multiple buildings, 'occupied' but it isn't"** (96a575a6).
Diagnosis: no server-side phantom occupancy (0 stale tiles). Root cause was the
place→render lag — a just-placed building hadn't rendered yet (realtime event
lags on mobile Safari), so the tile looked empty while the server knew it was
taken. Same cause as the "roads not showing after placement" report; fixed by
the optimistic render-on-place commit `d4caff4` (Sonnet 4.6, parallel session).

**Jill — "incinerator doesn't show its radius when clicked"** (0f6e4178).
Not a code bug — the deployed `getBuildingAoeRange` handles the `sanitation`
category and `showAoe` fires on inspect. It was the DB-ahead-of-frontend window
at go-live (migrations applied before the frontend deployed), so her cached
client was pre-expansion. Resolves on hard reload. **Lesson: deploy frontend
first, then migrate** — the old frontend degrades gracefully on the new DB.

**Drew — "should be able to zoom out way more"** (06038bff). Pre-existing.
Lowered the min-zoom clamp 0.25 → 0.1 (ZoomControls + both MainScene clamps).
Commit v2 `5554397`.

---

## 2026-05-09 — Jill — "unable to update from a townhouse to a villa"

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

## 2026-05-12 — Drew — "Test bug report"

**Reported:** 2026-05-12 18:09 UTC, in-game bug-report modal.

**Description (verbatim):**
> Test bug report

**Diagnosis:**
Intentional test ping. Submitted to verify commit 47's RPC switch
(`submit_bug_report` instead of direct INSERT) is actually capturing
the rich server-side forensic snapshot end-to-end.

End-to-end check: snapshot included profile, 261 buildings, 50
recent cash transactions, full inventory, trader_visits, trade_
policies, agreements, snapshot_at. Client_state had viewport
(432×820 dpr 2.5 → Android phone), active panel = "build", v2
version tag, recent_notifications array. Everything wired up.

**Fix:** None — not a real bug. Marked resolved with the commit
that originally landed the RPC switch.

**Resolution commit:** `d38f32b` (already in main).

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
- `f0c610d` (citybuilder-game / v2) — new helpers in
  `scenes/helpers.js`: `getProductivity`, `getBoosterMultiplier`
  (Manhattan ≤ boost_range, MAX of matching staffed boosters),
  `effectiveOutputRate` (per-instance composition).
  `computeResourceProdCons` + `computeResourceFlow` updated;
  `CityResourcesTab` passes `state.profile` through ctx.
- `9ebd0b4` (citybuilder / v1) — mirror of the same logic in
  `city-builder-mvp/js/panels.js` (`computeNetRates` + the byType
  groupings in `computeResourceFlow`).

**Tests:** 10 new vitest cases in `src/scenes/helpers.test.js`
including a full reproduction of Jill's clay layout (20 pits + 4
huts + 12 kilns + productivity 1.15) — the panel now reports the
deficit instead of a phantom surplus.
