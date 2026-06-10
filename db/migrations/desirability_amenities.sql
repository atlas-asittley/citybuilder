-- ─────────────────────────────────────────────────────────────────────
-- Civic amenities: Public Garden + Monument (2026-05-22).
--
-- Atlas: Jill's tier-4 houses are stuck because her tile desirability
-- ceilings out around 53-68 vs. tier-5's gate of 70. With the
-- tax-office uncap that shipped earlier today she lost 15 city_base
-- and now has no way to push tile desirability higher. Adding two new
-- building types that DIRECTLY contribute to per-tile desirability
-- (and also absorb workers — she has ~193 idle).
--
-- Public Garden: 2×2, 6 workers, \$12k, \$4/min upkeep, +5
--   desirability within Chebyshev 3. Mid-game spammable.
-- Monument: 1×1, 4 workers, \$25k + 15 statuary, no upkeep,
--   +8 desirability within Chebyshev 3, gates at housing tier 5.
--   Late-game investment; doubles as a sink for stone industry.
--
-- Both require staffing (status='active' AND is_staffed) to contribute,
-- matching the existing service-coverage pattern. Both go under
-- industry_key='common' so every industry can build them.
--
-- Schema: two new columns on building_types — desirability_bonus,
-- desirability_radius — and the desirability formula sums any
-- staffed building whose bonus > 0 within its declared radius. Future
-- additions (e.g. Plaza, Library) just need a row + values.
-- ─────────────────────────────────────────────────────────────────────


ALTER TABLE public.building_types
  ADD COLUMN IF NOT EXISTS desirability_bonus integer NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS desirability_radius integer NOT NULL DEFAULT 0;

-- Extend the category CHECK allowlist with 'civic' (Public Garden,
-- Monument, future amenities). Existing categories preserved.
ALTER TABLE public.building_types DROP CONSTRAINT IF EXISTS building_types_category_check;
ALTER TABLE public.building_types ADD CONSTRAINT building_types_category_check
  CHECK (category IN (
    'extractor','food_extractor','processor','road','housing',
    'service','tax','booster','police','park','civic',
    'transport_hub','transport_connector'
  ));


INSERT INTO public.building_types (
  key, name, tier, category, industry_key, is_active,
  footprint_w, footprint_h, worker_cost, build_cost, upkeep_per_minute,
  output_rate, input_rate, input_rate_2,
  workers_provided, boost_multiplier, boost_range,
  coverage_radius, pollution_emit, pollution_radius,
  desirability_bonus, desirability_radius, unlocks_at_housing_tier
) VALUES
  ('public_garden', 'Public Garden', 1, 'civic', 'common', true,
   2, 2, 6, 12000, 4,
   0, 0, 0,  0, 1.0, 0,  0, 0, 0,
   5, 3, NULL),
  ('monument', 'Monument', 3, 'civic', 'common', true,
   1, 1, 4, 25000, 0,
   0, 0, 0,  0, 1.0, 0,  0, 0, 0,
   8, 3, 5)
ON CONFLICT (key) DO UPDATE SET
  category = EXCLUDED.category,
  industry_key = EXCLUDED.industry_key,
  is_active = EXCLUDED.is_active,
  footprint_w = EXCLUDED.footprint_w,
  footprint_h = EXCLUDED.footprint_h,
  worker_cost = EXCLUDED.worker_cost,
  build_cost = EXCLUDED.build_cost,
  upkeep_per_minute = EXCLUDED.upkeep_per_minute,
  desirability_bonus = EXCLUDED.desirability_bonus,
  desirability_radius = EXCLUDED.desirability_radius,
  unlocks_at_housing_tier = EXCLUDED.unlocks_at_housing_tier;


-- Monument's raw-resource cost: 15 statuary. Public Garden has only
-- the money cost — kept simple to make it accessible to every industry
-- without forcing a cross-industry trade gate.
INSERT INTO public.building_type_resource_costs (building_type_key, resource_key, quantity)
VALUES ('monument', 'statuary', 15)
ON CONFLICT (building_type_key, resource_key) DO UPDATE SET quantity = EXCLUDED.quantity;


-- ── _pp_update_desirability: add civic-amenity contribution ────────
--
-- Adds the staffed-and-active civic buildings' desirability_bonus to
-- every tile within their declared desirability_radius (Chebyshev,
-- matching all other service-proximity gates).
CREATE OR REPLACE FUNCTION public._pp_update_desirability(p_uid uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
DECLARE
  v_food_variety integer;
  v_crime numeric;
  v_tax_count integer;
  v_city_base integer;
BEGIN
  SELECT COUNT(DISTINCT i.resource_key) INTO v_food_variety
  FROM public.inventories i
  JOIN public.resources r ON r.key = i.resource_key
  WHERE i.player_id = p_uid AND r.is_food AND i.quantity > 0;

  SELECT COALESCE(crime, 0) INTO v_crime
  FROM public.player_profiles WHERE id = p_uid;

  SELECT COUNT(*) INTO v_tax_count
  FROM public.buildings b
  JOIN public.building_types bt ON bt.key = b.building_type_key
  WHERE b.player_id = p_uid AND b.status = 'active' AND bt.category = 'tax';

  v_city_base := 50
    + LEAST(10, v_food_variety * 2)
    - LEAST(20, GREATEST(0, FLOOR((v_crime - 30) / 10)::integer * 2))
    - v_tax_count * 3;

  UPDATE public.map_tiles mt SET desirability = LEAST(100, GREATEST(0,
    v_city_base
    - LEAST(30, mt.pollution::integer)
    + COALESCE((
        -- Service coverage (school / temple / well / bathhouse / tavern)
        -- using Chebyshev distance. Magnitudes hardcoded per the
        -- 2026-05-20 service-proximity migration.
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
        -- Civic-amenity coverage: any staffed building with a
        -- declared desirability_bonus + desirability_radius
        -- contributes its bonus to every tile within range. Footprint
        -- anchor (b.x, b.y) used for distance — multi-tile civic
        -- buildings (e.g. 2×2 Public Garden) still measure from their
        -- top-left anchor for simplicity.
        SELECT SUM(bt.desirability_bonus)
        FROM public.buildings b
        JOIN public.building_types bt ON bt.key = b.building_type_key
        WHERE b.player_id = p_uid AND b.status = 'active' AND b.is_staffed
          AND bt.desirability_bonus > 0
          AND bt.desirability_radius > 0
          AND GREATEST(ABS(b.x - mt.x), ABS(b.y - mt.y)) <= bt.desirability_radius
      ), 0)
  )) WHERE mt.owner_player_id = p_uid;
END;
$function$;
