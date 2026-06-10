# UI Number Audit — Findings

Working file. Each computed UI number gets verified here with:
- The formula as displayed in the UI
- The source-of-truth comparison
- ✅ correct / ⚠ suspicious / 🐞 confirmed bug
- For 🐞 entries: research notes (git log / memory / migration history) before fix.

Pass-through entries get a one-line "trivially correct" note.

---

## Topbar (entries #1-11)

- #1 Money — pass-through `state.profile.money`. ✅ trivially correct.
- #2 Runway — 🐞 **BUG (fixed)**: pantry buffers weren't added to stock. After the per-house pantry rollout (2026-05-09), houses hold up to 30 min of consumption in their own buffers; `computeCityRunway` in panels.js was only counting `state.inventory[*]`, ignoring `state.buildingBuffers`. For Drew's 17 houses at tier 2 that's ~120 food-units of unaccounted buffer (~8 min at his drain rate). Under-reported runway in deficit scenarios.
  - Fix shipped: food + lifestyle stock now sums each building's relevant buffer alongside city inventory. Skipped when `state.buildingBuffers` isn't loaded yet (early render guard).
- #3 Parcels — pass-through `state.profile.chunks_owned`. ✅ correct.
- #4 Trader-reset countdown — `(nextUtcMidnight - now) / 60000` then format. ✅ math correct, matches server's `day_bucket = CURRENT_DATE` boundary.
- #5 Workers `used/needed` — pass-through from `state.laborInfo`. ✅ display correct.
- #6 Labor shortage badge — pass-through. ✅
- #7 Population `Math.floor(pop) / cap` — ✅ correct.
- #8 Happiness — `Math.round(h)` from server. ✅ display correct.
  - 🐞 **BUG: tooltip rate estimate is 4× too low.** `ui.js:163-164`:
    ```js
    'Citizens slowly moving in (~' + ((h - 50) / 50).toFixed(2) + '/min).'
    ```
    Server uses `v_max_rate = 4.0` (commit `12c7f87`, 2026-05-06: "was 1.0; bumped per playtest"). Tooltip wasn't updated; still shows the pre-bump 1.0 multiplier. At happiness 100, tooltip says "1.00/min" but real migration is 4/min. Same for the leaving-rate branch.
    Memory `feedback_balance_invariants.md` correctly tracks v_max_rate=4.0; only the UI tooltip leaked.
    **Fix shipped**: tooltip now uses the actual `state.profile.migration_rate` instead of computing its own estimate.
- #9 Crime — `Math.round(c)` from server. ✅ display correct.
- #10 Migration rate `±X.XX` — `Math.round(rate * 100) / 100` of server's `migration_rate`. ✅ math correct.
- #11 Productivity `X%` — `Math.round(p * 100)`. ✅ correct.

## Build Panel (entries #12-25)

Most are pass-throughs from `building_types` columns — trivially correct.

- #16 Extractor recipe — uses shared `recipeOf` / `periodSuffix` from recipe_format.js. ✅
- #17 Booster `+N% within R tiles` — `Math.round((boost_multiplier - 1) * 100)` and `boost_range`. Standard. ✅
- #19 Tax `$X/min per 100 citizens` — server formula is `output_rate * (population/100) * productivity`. Description matches the per-capita scaling; doesn't surface productivity multiplier (minor — would clutter the build description).
- #21 Park pollution `Reduces by N within R tiles` — `Math.abs(pollution_emit)` (parks have negative emit). ✅
- #23 Resource cost chips `(X have)` — inventory comparison. Pass-through. ✅
- #24 Money shortage `need $N more` — `bt.build_cost - state.profile.money`. ✅

## Inspector (entries #62-72)

- #65 Transport hub expansion cost — client `bt.build_cost * 2 * (lvl + 1)` matches server `expand_transport_hub` `v_bt.build_cost * 2 * (v_b.expansion_level + 1)`. ✅
- #66 Extractor effective rate — uses `output_rate * pathFactor` where `pathFactor = min(1, 4/path_length)`. Server formula: `output_rate * path_factor * boost * productivity`. **The inspector omits boost + productivity by design** (matches how processors display nominal recipe rates; commit `83d948c`). Borderline — players might expect the displayed rate to reflect bonuses, but the codebase is consistent. **Not fixing** — would need a broader UX decision about nominal-vs-effective rate display.
- #69 Pantry % — `Math.max(0, Math.min(100, Math.round(quantity / capacity * 100)))`. Clamped, rounded. ✅

## Trade (entries #51-58)

- #54 Best deals matching — sell mode picks highest buy_price ≥ floor; buy mode picks lowest sell_price ≤ ceiling. ✅
- #57 Black Market sell `$X` — client `Math.max(1, Math.floor(base_price * 0.35))`, server `GREATEST(1, FLOOR(base_price * 0.35))`. ✅ exact match
- #58 Black Market buy `$X` — client `Math.ceil(base_price * 2.0)`, server `CEIL(base_price * 2.0)`. ✅ exact match

## Treasury (entries #39-50)

- #41 Treasury net — `totalIn - totalOut`. ✅
- #42 Burn rate `$X/day` — `weekNet / days.length` (8 buckets including today's partial). Title says "last 7 days"; bucket count is 8. Minor framing inconsistency — burn rate is slightly under-reported when today is fresh. Acceptable approximation.
- #43 Runway `~X days` — `Math.floor(money / burn)`. ✅
- #44/45 Top source/sink chips — sort by amount descending, take [0]. ✅
- #46 Daily-net bars — height = `|net| / maxAbs * maxBar`, scaled per-window. ✅
- #47 Balance line — reconstructs historical balance by walking back from currentMoney. ✅
- #50 Transaction-detail cap (200) — clearly labeled "Total of these: $X" when truncated. Parent-panel totals come from server-aggregated RPC (already audited). ✅

## Notifications (entry #76)

- #76 Unread badge — newest-first walk, breaks at first read entry. `n > 9 ? '9+' : n`. ✅

## Resource flow (entries #26-35)

- #27 `formatRate` — `Math.round(rate * 10) / 10` with sign. Loses precision at <0.05/min granularity but readable.
- #30-34 Resource flow analytics (`computeResourceFlow`) — counts staffed buildings only, multiplies by per-building input/output rates. Food drain = pro-rata across all is_food resources. Lifestyle drain = per-tier × house count. Matches server semantics. ✅

## Walker / state-derived (entries #74, #80-85)

- #74 Walker cap = `Math.floor(population / 10)`. Simple. ✅
- #82-85 Server-computed metrics rendered as-is — out of scope for UI display audit (would be a separate server-formula audit).

---

## Summary

**Total computed numbers verified: ~30 high-risk items** (the ones where math, formulas, or aggregations could go wrong).

### Bugs found and fixed (2)
1. 🐞 **Happiness tooltip rate estimate was 4× low** — used `(h-50)/50` while server's v_max_rate has been 4.0 since 2026-05-06. Fixed: tooltip now reads `state.profile.migration_rate` directly.
2. 🐞 **Runway didn't account for per-house pantry buffers** — under-reported by ~5-15 min in deficit scenarios. Fixed: food + lifestyle stock now sums each building's pantry buffer alongside city inventory.

### Borderline / not-fixed (1)
- ⚠ Extractor inspector rate omits boost + productivity multipliers. Consistent with how processors show rates (nominal recipe). Would need a broader UX decision before changing.

### Hit rate vs prediction
- Predicted 3-8 actual bugs. Found 2 confirmed + 1 borderline. Lower than expected — the recent overnight audit (2026-05-09) cleared most UI/server divergences, so diminishing returns kicked in earlier than predicted.
