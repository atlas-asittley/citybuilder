-- ─────────────────────────────────────────────────────────────────────
-- Double the output rate on resource collectors (2026-05-20).
--
-- Atlas: "let's double the production rate of our resource collectors —
-- and the foods you grow."
--
-- Scope: every building whose category is 'extractor' (clay_pit,
-- iron_mine, stone_quarry, timber_camp) or 'food_extractor' (garden,
-- grain_farm, fishing_pier, orchard). Just the base output_rate; path-
-- length scaling, booster MAX, and productivity all still apply on top
-- of the new rate. Processors and boosters unchanged — this only
-- doubles what comes out of the ground.
--
-- Pre-change rates:
--   clay_pit       1.5  →  3.0    (clay industry's higher-base extractor)
--   iron_mine        1  →    2
--   stone_quarry     1  →    2
--   timber_camp      1  →    2
--   garden / grain_farm / fishing_pier / orchard   2  →  4
--
-- No restoration SQL needed: the change touches building_types only,
-- not any per-player state. The next process_production tick simply
-- harvests at the new rate.
-- ─────────────────────────────────────────────────────────────────────

UPDATE public.building_types
SET output_rate = output_rate * 2
WHERE category IN ('extractor', 'food_extractor')
  AND output_rate > 0;
