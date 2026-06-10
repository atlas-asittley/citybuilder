-- ── Stricter food consumption: 2x again (2026-05-07 round 2) ──
-- Atlas asked to double the just-doubled values. Cumulative 4x from
-- the original. Now: 1 garden feeds ~4 cottages, ~2.5 townhouses, etc.
-- Each higher-tier house effectively wants its own food extractor.

UPDATE public.housing_tier_config SET food_per_minute = 0.24 WHERE tier = 2;
UPDATE public.housing_tier_config SET food_per_minute = 0.40 WHERE tier = 3;
UPDATE public.housing_tier_config SET food_per_minute = 0.60 WHERE tier = 4;
UPDATE public.housing_tier_config SET food_per_minute = 1.00 WHERE tier = 5;
UPDATE public.housing_tier_config SET food_per_minute = 1.60 WHERE tier = 6;
UPDATE public.housing_tier_config SET food_per_minute = 2.40 WHERE tier = 7;
UPDATE public.housing_tier_config SET food_per_minute = 3.60 WHERE tier = 8;
