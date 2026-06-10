-- ============================================================================
-- fancier_roads.sql  (Civic Metrics Expansion — Phase 3)
-- ----------------------------------------------------------------------------
-- Adds three upgraded road tiers that project a DESIRABILITY aura, consuming
-- progressively fancier materials. See
-- citybuilder-game/docs/CIVIC_METRICS_EXPANSION.md §8.
--
-- !! APPLY ORDER: run AFTER waste_management.sql (this redefines
--    _pp_update_desirability on top of the waste version). It does NOT touch
--    _pp_for_uid, so it's independent of power_energy.sql. Migrations apply
--    chronologically; authored after waste/power.
--
--   road            Dirt Road        (existing)  road_tier 1, +0 desirability
--   paved_road      Paved Road       1 brick     road_tier 2, +2 desir r1
--   tiled_avenue    Tiled Avenue     1 tiles     road_tier 3, +4 desir r2
--   grand_boulevard Grand Boulevard  1 monuments + 1 cabinets + 1 mosaics
--                                                 road_tier 4, +6 desir r2,
--                                                 −3 pollution r2 (tree-lined)
--
-- This is the headline DEAD-RESOURCE SINK: the Grand Boulevard consumes the
-- three "art" capstones (monuments/cabinets/mosaics = stone/timber/clay), while
-- machinery (the iron capstone) is sunk by sanitation/power. Desirability gates
-- housing tiers (min_desirability up to 94 at tier 8), so reaching elite housing
-- now genuinely requires beautifying with these roads — which requires the
-- capstones — which spreads demand across stone/timber/clay.
--
-- All tiers are category='road', so they inherit EVERYTHING from the road
-- system: connectivity (has_road_access), placement/paving rules, autotiling,
-- walker pathing, extractor-path recompute. They're never staffed, so the
-- desirability term below lets category='road' bypass the is_staffed gate.
--
-- Idempotent + additive. NOT applied to live until the matching frontend ships.
-- ============================================================================

BEGIN;

-- 1. Schema -----------------------------------------------------------------
ALTER TABLE public.building_types
  ADD COLUMN IF NOT EXISTS road_tier smallint NOT NULL DEFAULT 1;

UPDATE public.building_types SET road_tier = 1 WHERE category = 'road' AND road_tier = 1;

-- 2. Road tiers -------------------------------------------------------------
-- output_rate is NOT NULL with no default → set explicitly (0).
INSERT INTO public.building_types
  (key, name, tier, industry_key, category, build_cost, worker_cost,
   output_rate, road_tier, desirability_bonus, desirability_radius,
   pollution_emit, pollution_radius, footprint_w, footprint_h, is_active)
VALUES
  ('paved_road',      'Paved Road',      1, 'common', 'road', 20, 0, 0, 2, 2, 1,  0, 0, 1, 1, true),
  ('tiled_avenue',    'Tiled Avenue',    1, 'common', 'road', 40, 0, 0, 3, 4, 2,  0, 0, 1, 1, true),
  ('grand_boulevard', 'Grand Boulevard', 1, 'common', 'road', 80, 0, 0, 4, 6, 2, -3, 2, 1, 1, true)
ON CONFLICT (key) DO UPDATE SET
  name = EXCLUDED.name, category = EXCLUDED.category, build_cost = EXCLUDED.build_cost,
  road_tier = EXCLUDED.road_tier, desirability_bonus = EXCLUDED.desirability_bonus,
  desirability_radius = EXCLUDED.desirability_radius,
  pollution_emit = EXCLUDED.pollution_emit, pollution_radius = EXCLUDED.pollution_radius,
  footprint_w = EXCLUDED.footprint_w, footprint_h = EXCLUDED.footprint_h, is_active = true;

-- 3. Build materials (the sinks) -------------------------------------------
INSERT INTO public.building_type_resource_costs (building_type_key, resource_key, quantity)
VALUES
  ('paved_road',      'brick',     1),
  ('tiled_avenue',    'tiles',     1),
  ('grand_boulevard', 'monuments', 1),
  ('grand_boulevard', 'cabinets',  1),
  ('grand_boulevard', 'mosaics',   1)
ON CONFLICT (building_type_key, resource_key) DO UPDATE SET quantity = EXCLUDED.quantity;

-- 4. Desirability: let roads contribute their aura unstaffed -----------------
-- (rebuilt from the waste_management.sql version; the ONLY change is the
--  amenity subquery condition: (b.is_staffed OR bt.category = 'road'). Roads
--  are never staffed, so without this their desirability_bonus would never
--  apply. The Grand Boulevard's negative pollution_emit is already handled by
--  _pp_update_pollution's negative-emitter clause — no change needed there.)
CREATE OR REPLACE FUNCTION public._pp_update_desirability(p_uid uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  v_food_variety integer;
  v_crime numeric;
  v_waste numeric;
  v_tax_count integer;
  v_city_base integer;
BEGIN
  SELECT COUNT(DISTINCT i.resource_key) INTO v_food_variety
  FROM public.inventories i
  JOIN public.resources r ON r.key = i.resource_key
  WHERE i.player_id = p_uid AND r.is_food AND i.quantity > 0;

  SELECT COALESCE(crime, 0), COALESCE(waste, 0) INTO v_crime, v_waste
  FROM public.player_profiles WHERE id = p_uid;

  SELECT COUNT(*) INTO v_tax_count
  FROM public.buildings b
  JOIN public.building_types bt ON bt.key = b.building_type_key
  WHERE b.player_id = p_uid AND b.status = 'active' AND bt.category = 'tax';

  v_city_base := 50
    + LEAST(10, v_food_variety * 2)
    - LEAST(20, GREATEST(0, FLOOR((v_crime - 30) / 10)::integer * 2))
    - v_tax_count * 3
    - LEAST(8, FLOOR(v_waste / 12)::integer);   -- bounded waste drag (max -8 at waste>=96)

  UPDATE public.map_tiles mt SET desirability = LEAST(100, GREATEST(0,
    v_city_base
    - LEAST(30, mt.pollution::integer)
    + COALESCE((
        SELECT SUM(CASE bt.key
          WHEN 'well'      THEN 5
          WHEN 'school'    THEN 5
          WHEN 'temple'    THEN 5
          WHEN 'bathhouse' THEN 5
          WHEN 'tavern'    THEN 3
          ELSE 0 END)
        FROM public.buildings b
        JOIN public.building_types bt ON bt.key = b.building_type_key
        WHERE b.player_id = p_uid AND b.status = 'active' AND b.is_staffed
          AND bt.category = 'service'
          AND GREATEST(ABS(b.x - mt.x), ABS(b.y - mt.y)) <=
              CASE bt.key
                WHEN 'well'      THEN 4
                WHEN 'school'    THEN 5
                WHEN 'temple'    THEN 6
                WHEN 'bathhouse' THEN 4
                WHEN 'tavern'    THEN 4
                ELSE 0 END
      ), 0)
    + COALESCE((
        -- Civic amenities (staffed) + ROAD tiers (never staffed → bypass).
        SELECT SUM(bt.desirability_bonus)
        FROM public.buildings b
        JOIN public.building_types bt ON bt.key = b.building_type_key
        WHERE b.player_id = p_uid AND b.status = 'active'
          AND (b.is_staffed OR bt.category = 'road')
          AND bt.desirability_bonus > 0
          AND bt.desirability_radius > 0
          AND GREATEST(ABS(b.x - mt.x), ABS(b.y - mt.y)) <= bt.desirability_radius
      ), 0)
  )) WHERE mt.owner_player_id = p_uid;
END;
$function$;

COMMIT;
