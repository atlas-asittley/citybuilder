# Balance notes from sandbox runs

Initial pass on 2026-05-07 using `sandbox/balance_sim.py`. Numbers are
from the **pure-Python model**, not live-DB measurements — directionally
correct but treat as illustrative until validated with `db_sim.py`.

## Baseline starter player (30-min run)

Setup: clay player, $1000, completes the tutorial (4 huts → well →
garden → clay pit), policy clay = `sell_surplus reserve=0`.

```
After 30.0 min:
  money:        $530   (down $470 from $1000 — most of it the build cost)
  population:   54.1
  happiness:    63.0
  workers:      23/23 (fully employed, no labor shortage)
  food stock:   0.0   ← model bottleneck, see below
  avg housing:  tier 6 in the model (model is too lenient on tier gates)
  trade earned: $90 over 3 visits ($45/visit × 2 visits, 1 visit empty)
```

**Time to milestones:**
- Hit population 50 at minute 26.5 (with happiness=63, immigration rate=4·(63-50)/50 = 1.04/min)
- First trade fired at minute 10.5 (river_traders 10-min cooldown)
- Average housing crossed Cottage threshold at minute 0.5 (model artifact —
  the upgrade_secs gate fires too eagerly without the school/temple/luxury-food
  prereqs the SQL enforces; **don't trust avg_tier from this model past tier 3**)

**Reading:** the starter loadout is balanced. ~$45/10min income from
clay sales is a usable starter trickle. Ending at ~$530 with no
upkeep buildings means the player is solvent but has no slack — building
a Watch House ($300, +$15/min upkeep) immediately would be tight.

## Time to first Watch House

Player needs $300 cash + 5 spare workers to staff one. With a stable
$45/10min income and no upkeep yet, money grows at ~$4.5/min. Starting
at $530 after the tutorial, a Watch House is affordable around **minute 15**
post-tutorial — but the spare-workers requirement only relaxes once
population grows past 30 (well 3 + garden 10 + clay 10 + watch 5 = 28).
At immigration rate 1+ per minute, that's roughly the same window.

**Practical guidance for tutorial copy:** don't suggest building a
Watch House until ~15-30 min post-tutorial. Earlier is doable but
puts the player on a knife edge.

## Doubling immigration

`IMMIGRATION_MAX_RATE = 4.0 → 8.0` in the model. Result on the
baseline scenario: pop after 30 min 54 → ~70. That's a meaningful
nudge but the housing capacity (24 from 4 tier-1 huts) is the real
ceiling. Doubling immigration only matters for players who've grown
their housing past the starter set.

**Reading:** the current 4.0/min is fine for early game. If late-game
feels too slow to grow into bigger housing, 6.0 or 8.0 would help —
but only after the player has the housing supply to support it.

## Food drain at higher tiers

At pop=100 with 6 Cottages (tier 2, 0.06/min each = 0.36/min total):
two staffed gardens (1.0/min each = 2.0/min) easily cover. **Surplus.**

At pop=200 of mostly Mansions (tier 6, 0.40/min each):
- 16 mansions × 0.40 = 6.4/min food drain
- Need 7 staffed gardens just to break even (each at 1.0/min)
- Plus food variety for happiness — actually need 2-3 different food types

**Reading:** food becomes a real constraint at tier 5+. Players need
to plan for multiple food extractors (different industries via trade
or own production). Could be intended difficulty curve. Worth checking
late-game playtests.

## Open questions to validate with db_sim

The pure-Python model has known gaps (housing-tier prereq gates,
productivity multipliers, multi-input service feeding). To answer with
high confidence:

1. **At what pop/time does a typical player unlock Cottage (tier 2)?**
   The pure-Python model says ~30s — not realistic; tier 2 needs food.
2. **What's the realistic ceiling on housing tier without trade with
   other players?** The model says tier 6+. SQL says tier 7+ needs
   industrial luxuries which require cross-industry trade.
3. **How long does a player stay at floor=15 if they don't build a
   single house?** Model says forever. SQL says happiness drops without
   services + food, but population stays at floor.

Run these via `db_sim.py` for definitive answers.

# Empirical findings from db_sim (2026-05-07)

Three real scenarios run end-to-end against the live DB schema in a
savepoint. Full server fidelity, so these results match production.

## Finding 1: Roads + spatial layout dominate the early game

A starter player who completes the tutorial sequence (4 huts → well →
garden → clay_pit) but places those buildings at the *closest unoccupied
tiles* — without thinking about well coverage radius — will see their
houses devolve from Mud Hut (tier 1, 6 workers) back to Shanty (tier 0,
2 workers) within ~2 minutes. Population drains from 24 → 15 (the
floor) over ~20 minutes.

**Why:** tier 1 housing requires a well within Manhattan-distance 4. If
houses get placed at distance 5+ from the well, coverage misses and the
houses devolve. Worker capacity drops accordingly.

**Implication:** placement geometry is currently load-bearing in a way
the new-player UI doesn't surface. Suggestions to consider:
- Visualize well coverage radius when placing a Well or a House.
- Loosen tier 1 prereq to "ANY well in district" instead of within-4-tiles.

## Finding 2: Watch House is unaffordable in the first 30 minutes

A starter player generates ~$130 trade revenue over 30 min (3
river_traders visits × ~$42 each). A Watch House costs $300 build +
$15/min upkeep = $750 in the first 30 min. Net loss ~$320.

Crime DOES drop from ~27 → ~19 with a watch house, but the happiness
bonus (one fewer crime penalty unit) doesn't pay for itself.

**Implication:** the player should be steered away from police early
("save up first"). Tutorial copy currently doesn't mention this. Could
also: reduce Watch House upkeep 15 → 5/min, or start the crime
baseline lower so police aren't urgent.

## Finding 3: Population floor of 15 prevents complete collapse

Even with bad placement + happiness drifting to 44, pop bottoms out
at 15. `_pp_update_population`'s under-floor branch refills regardless
of happiness. Without it, this scenario would have drained the player
to 0 workers — game over.

The floor is doing its job. Don't regress.

## Finding 4: Auto-trade economy is healthy

In all three scenarios, the 10-min river_traders cooldown fired
reliably and sold up to 20 clay per visit (capacity). Money trickled
in at $42-45/visit.

**Tune target:** ~$250/hour from one staffed extractor. Reasonable
starter income — enough to slowly accumulate $300 for a Watch House
or $600 for a School over a 1-2 hour session.

## Suggested next balance tweaks (NOT shipped — for Atlas to weigh)

| # | Change | Lever | Risk |
|---|---|---|---|
| 1 | Show well coverage radius at placement time | UX | Low |
| 2 | Tier 1 prereq: "any well in district" instead of within 4 | Gameplay | Med |
| 3 | Watch House upkeep 15 → 5/min | Balance | Low |
| 4 | Base crime 10 → 5 | Balance | Low |
| 5 | Tutorial copy: "save for $300+ before building police" | UX | Low |
