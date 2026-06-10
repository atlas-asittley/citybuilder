-- ── Halve cumulative lifestyle demand rates + restore Ironwood (2026-05-07) ──
-- Ship-and-watch: the cumulative model sized for a Manor-tier city was
-- correct directionally but the rates ate Jill's 100-pottery grant in
-- 42 minutes and her 16 Townhouses collapsed back to Mud Hut before
-- she had time to react.
--
-- Fix in two parts:
--
-- 1. Halve every lifestyle rate. Same shape as before (introducing
--    tier 0.05/min, +0.025 per tier above), so the cumulative + scaled
--    structure is preserved — just doubles the runway on any given
--    stockpile. A row of 16 Townhouses at the old 0.15 pottery/min
--    burned 100 pottery in 42 min; at the new 0.075/min it lasts ~84
--    min — long enough to notice on a normal play session.
--
--                    pottery  bread   furniture  statuary
--      T2 Cottage     0.05
--      T3 Townhouse   0.075   0.05
--      T4 Villa       0.10    0.075   0.05
--      T5 Manor       0.125   0.10    0.075     0.05
--      T6 Mansion     0.15    0.125   0.10      0.075
--      T7 Estate      0.175   0.15    0.125     0.10
--      T8 Palace      0.20    0.175   0.15      0.125
--
-- 2. Restore Ironwood's collapsed city. Promote 16 of Jill's 17 T1
--    houses back to T3 (Townhouse) — the same count she had before the
--    migration shipped. Stock her with 1000 pottery (~14 hr runway at
--    the new T3 rate) and 500 bread, and reset last_food_tick_at to
--    `now()` so the next process_production call doesn't try to drain
--    hours of accumulated demand in a single shot.

-- ── 1) Halve all lifestyle rates ──
UPDATE public.housing_lifestyle_demands SET qty_per_minute = 0.05   WHERE tier = 2 AND resource_key = 'pottery';
UPDATE public.housing_lifestyle_demands SET qty_per_minute = 0.075  WHERE tier = 3 AND resource_key = 'pottery';
UPDATE public.housing_lifestyle_demands SET qty_per_minute = 0.05   WHERE tier = 3 AND resource_key = 'bread';
UPDATE public.housing_lifestyle_demands SET qty_per_minute = 0.10   WHERE tier = 4 AND resource_key = 'pottery';
UPDATE public.housing_lifestyle_demands SET qty_per_minute = 0.075  WHERE tier = 4 AND resource_key = 'bread';
UPDATE public.housing_lifestyle_demands SET qty_per_minute = 0.05   WHERE tier = 4 AND resource_key = 'furniture';
UPDATE public.housing_lifestyle_demands SET qty_per_minute = 0.125  WHERE tier = 5 AND resource_key = 'pottery';
UPDATE public.housing_lifestyle_demands SET qty_per_minute = 0.10   WHERE tier = 5 AND resource_key = 'bread';
UPDATE public.housing_lifestyle_demands SET qty_per_minute = 0.075  WHERE tier = 5 AND resource_key = 'furniture';
UPDATE public.housing_lifestyle_demands SET qty_per_minute = 0.05   WHERE tier = 5 AND resource_key = 'statuary';
UPDATE public.housing_lifestyle_demands SET qty_per_minute = 0.15   WHERE tier = 6 AND resource_key = 'pottery';
UPDATE public.housing_lifestyle_demands SET qty_per_minute = 0.125  WHERE tier = 6 AND resource_key = 'bread';
UPDATE public.housing_lifestyle_demands SET qty_per_minute = 0.10   WHERE tier = 6 AND resource_key = 'furniture';
UPDATE public.housing_lifestyle_demands SET qty_per_minute = 0.075  WHERE tier = 6 AND resource_key = 'statuary';
UPDATE public.housing_lifestyle_demands SET qty_per_minute = 0.175  WHERE tier = 7 AND resource_key = 'pottery';
UPDATE public.housing_lifestyle_demands SET qty_per_minute = 0.15   WHERE tier = 7 AND resource_key = 'bread';
UPDATE public.housing_lifestyle_demands SET qty_per_minute = 0.125  WHERE tier = 7 AND resource_key = 'furniture';
UPDATE public.housing_lifestyle_demands SET qty_per_minute = 0.10   WHERE tier = 7 AND resource_key = 'statuary';
UPDATE public.housing_lifestyle_demands SET qty_per_minute = 0.20   WHERE tier = 8 AND resource_key = 'pottery';
UPDATE public.housing_lifestyle_demands SET qty_per_minute = 0.175  WHERE tier = 8 AND resource_key = 'bread';
UPDATE public.housing_lifestyle_demands SET qty_per_minute = 0.15   WHERE tier = 8 AND resource_key = 'furniture';
UPDATE public.housing_lifestyle_demands SET qty_per_minute = 0.125  WHERE tier = 8 AND resource_key = 'statuary';

-- ── 2) Restore Ironwood's 16 Townhouses ──
-- Promote the 16 most-recently-built houses (deterministic via
-- created_at DESC) so the surviving T1 is the original Mud Hut.
WITH ironwood AS (
  SELECT id FROM public.player_profiles WHERE district_name = 'Ironwood'
),
to_promote AS (
  SELECT b.id
  FROM public.buildings b
  JOIN ironwood ON b.player_id = ironwood.id
  WHERE b.building_type_key = 'house'
    AND b.housing_tier = 1
  ORDER BY b.created_at DESC
  LIMIT 16
)
UPDATE public.buildings
   SET housing_tier = 3,
       last_processed_at = now()
 WHERE id IN (SELECT id FROM to_promote);

-- Stock pottery + bread so she has real runway (~14 hr pottery,
-- ~10 hr bread at the new T3 cumulative rate × 16 houses).
UPDATE public.inventories
   SET quantity = 1000,
       updated_at = now()
 WHERE resource_key = 'pottery'
   AND player_id = (SELECT id FROM public.player_profiles WHERE district_name = 'Ironwood');

UPDATE public.inventories
   SET quantity = 500,
       updated_at = now()
 WHERE resource_key = 'bread'
   AND player_id = (SELECT id FROM public.player_profiles WHERE district_name = 'Ironwood');

-- Reset the food-tick anchor so the next process_production call
-- doesn't try to drain hours of accumulated demand in one shot.
UPDATE public.player_profiles
   SET last_food_tick_at = now()
 WHERE district_name = 'Ironwood';

-- Refresh highest_housing_tier_ever so the achievement marker reflects
-- the restored state (otherwise it might've stuck at 1 after the
-- collapse).
UPDATE public.player_profiles
   SET highest_housing_tier_ever = GREATEST(highest_housing_tier_ever, 3)
 WHERE district_name = 'Ironwood';
