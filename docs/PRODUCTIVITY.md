# Productivity

Status: **v2 shipped 2026-05-06.** All five levers from the original recommendation are live. Tools v2 ship as a soft incentive (no consumption); the four open design questions below were resolved by going with the doc's recommendations on each one.

## Problem

Today, happiness gates **who lives in the district** (immigration / emigration via the population-snap-up + slow-emigrate model in HAPPINESS.md). We don't have a separate measure that affects **how productive each building is**. Atlas wants one — a per-player productivity modifier that multiplies building output, distinct from local booster buildings.

## Recommended design (v1)

A single global multiplier per player, range **0.7 to 1.3**, default 1.0. Multiplies the effective output rate of every functional building (extractors, food extractors, processors, services with output, tax). Layered on top of the existing local boosters — they don't compete:

```
effective_rate = base_rate × productivity × (1 + sum_of_local_booster_bonuses) × staffing × inputs
```

So a Mason Workshop on a tile with a Foreman's Office adjacent (+30% local) and a city productivity of 1.2 outputs `0.5 × 1.2 × 1.30 = 0.78 brick/min` (vs. 0.5 baseline).

### Inputs (additive — capped at +0.3 / -0.3)

| Lever | Effect | Why |
|---|---|---|
| Education coverage | +0.03 per 10% of active housing within a school radius (max +0.10) | Schools already gate Townhouse evolution; stacking small productivity on top reinforces "schools are good" without making them mandatory. |
| Tools in inventory | +0.10 if you have ≥ population × 0.5 tools, +0.05 if ≥ population × 0.2, else 0 | Reuses the existing Toolmaker chain. Tools become consumables: drained by `_pp_drain_tools` at population × 0.05/min while staffed productive buildings exist. |
| Crime | -0.005 per crime point above 50, capped at -0.10 | Already-tracked metric, additional pressure besides the happiness penalty. |
| Population pressure | -0.05 if workers_idle ≤ 0 (everyone tapped) | Encourages keeping a worker buffer. |
| Tavern services running | +0.05 (booster — pulled from existing service flag) | Already exists in the staffing model, this just ties it to productivity too. |

Additive total clamped to ±0.3, applied as 1.0 + clamped_total → final productivity in [0.7, 1.3].

### Storage

New column `player_profiles.productivity` (numeric, default 1.0). Recomputed every tick by `_pp_compute_productivity(uid)` (new phase helper, runs after housing evolution since it depends on housing tier counts and active-house counts). Returned in the process_production JSON so the frontend can show it.

### UI

Topbar indicator next to the happiness emoji: `⚒︎ 1.18×` color-coded (red <0.9 / amber 0.9–1.1 / green >1.1). Clicking opens a tooltip with the breakdown of contributors.

## Open design questions — RESOLVED

1. **Single number or per-category?** → Single. Shipped as one global multiplier; the topbar shows one ⚒ value.
2. **Tools as a hard requirement or soft?** → Soft. Tools are a stockpile incentive only; not consumed. If we want to harden later, the lever exists.
3. **Crime penalty: stack on happiness penalty or replace?** → Stack. Crime already drags happiness; productivity adds a second pressure to keep police covering housing.
4. **How visible should the breakdown be?** → City-level only (topbar tooltip). Per-building inspector annotation deferred — not required to feel the system.

## Implementation cost (rough)

If recommendation is approved as-is:
- 1 column on player_profiles + small migration.
- 1 new `_pp_compute_productivity` helper (~50 lines plpgsql).
- 1 hook in process_production after housing evolution.
- Update _pp_run_extractors / _pp_run_food_extractors / _pp_run_processors / _pp_run_tax to multiply output by productivity (~5 lines each).
- Frontend: topbar indicator + tooltip.
- ~10 regression tests pinning each lever.

Ballpark: half a session.

## Shipped form (v2)

Implemented in `migration_patches/productivity_v2.sql` as a single helper, `_pp_compute_productivity(uid)`, called once per tick from `process_production` (after staffing — so tavern's `is_staffed` is fresh — and before the production phases that read it). Five levers, summed and clamped:

```
score = (crime drag, capped −0.10)
      + (tavern bonus, +0.05 when fed)
      + (education coverage, +0.03 per 10% of houses near a staffed school, capped +0.10)
      + (tools stockpile, +0.10 ≥ pop·0.5 / +0.05 ≥ pop·0.2)
      + (worker buffer penalty, −0.05 when workers_used ≥ worker_capacity)

clamp score to ±0.30; productivity = clamp(1.0 + score, 0.7, 1.3)
```

Net swing: −0.15 to +0.25. The cap at ±0.30 is defensive — no current combination reaches it — but leaves room for a 6th lever without re-doing the formula.

Multiplied into output by `_pp_run_extractors`, `_pp_run_food_extractors`, `_pp_run_processors`, and `_pp_run_tax`. Boosters (per-tile multiplier on adjacent extractors) layer on top — this stacks multiplicatively with them, which means a Forester's Office + 1.2 productivity gives `0.5 × 1.2 × 1.30 = 0.78` instead of additive `0.5 × 1.5 = 0.75`. Small difference, intentional: makes city-level productivity worth investing in even when boosters are saturated.
