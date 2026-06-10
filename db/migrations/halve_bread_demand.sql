-- ─────────────────────────────────────────────────────────────────────
-- Halve bread demand across all housing tiers (2026-05-21).
--
-- Drew feedback (bug-report 20203301): "The economy is based so much
-- on bread. Jill buys so much bread just to keep her housing up. We
-- should balance that out more."
--
-- Verified pre-fix: Jill's 95 houses (tiers 3-8) drained 26.88
-- bread/min ≈ 1612/hour. At the cheapest import price of \$14/unit
-- that's \$376/min — about 14% of her gross tax revenue, just on
-- bread. Drew's instinct is right: bread demand scales 3.5× over
-- the housing ladder and a mature city eats 15-30 bread/min just to
-- stay put.
--
-- Halving brings the same Jill total to ~13.4 bread/min ≈ \$188/min,
-- ~7% of her gross. Players still need bread, just less of it; the
-- bread-vs-substitutes balance (spices/caviar/spirits) stays the
-- same proportionally since this is a pure demand cut.
--
-- No restoration SQL needed — drains are per-tick from this table,
-- so the next tick uses the new rates. Per-house pantry buffers
-- refill faster too (good side effect).
-- ─────────────────────────────────────────────────────────────────────

UPDATE public.housing_lifestyle_demands
SET qty_per_minute = qty_per_minute * 0.5
WHERE resource_key = 'bread';
