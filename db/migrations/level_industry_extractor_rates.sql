-- ─────────────────────────────────────────────────────────────────────
-- Level all four industry extractors to output_rate = 4 (2026-05-20).
--
-- Atlas: "clay pit, iron mine, stone quarry, and timber camp should
-- all be at the same. Put them all at 4."
--
-- Follow-up to double_extractor_rates.sql. After the 2× pass clay_pit
-- ended at 3.0 (it had carried a +50% historical buff) and the other
-- three at 2.0. Setting all four to a flat 4 levels the industries —
-- a clay city and a timber city now extract their primary resource at
-- the same base rate. Food extractors stay at 4 (where the doubling
-- left them — already symmetric across industries).
--
-- Path-length scaling, booster MAX, and productivity continue to
-- apply on top.
-- ─────────────────────────────────────────────────────────────────────

UPDATE public.building_types
SET output_rate = 4
WHERE key IN ('clay_pit', 'iron_mine', 'stone_quarry', 'timber_camp');
