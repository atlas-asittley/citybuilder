-- ── Stricter food consumption per housing tier (2026-05-07) ──
-- Previous food drain was generous: 1 food extractor (1.0/min) fed ~16
-- cottages (tier 2 at 0.06/min). Atlas wanted "a little stricter" so
-- the food-extractor count actually scales with city size.
--
-- 2x bump across tiers 2-8. Tier 0 (Shanty) and tier 1 (Mud Hut) stay
-- at 0 — early-game players should not be food-stressed before they
-- have housing that benefits from it.

UPDATE public.housing_tier_config SET food_per_minute = 0.12 WHERE tier = 2;
UPDATE public.housing_tier_config SET food_per_minute = 0.20 WHERE tier = 3;
UPDATE public.housing_tier_config SET food_per_minute = 0.30 WHERE tier = 4;
UPDATE public.housing_tier_config SET food_per_minute = 0.50 WHERE tier = 5;
UPDATE public.housing_tier_config SET food_per_minute = 0.80 WHERE tier = 6;
UPDATE public.housing_tier_config SET food_per_minute = 1.20 WHERE tier = 7;
UPDATE public.housing_tier_config SET food_per_minute = 1.80 WHERE tier = 8;
