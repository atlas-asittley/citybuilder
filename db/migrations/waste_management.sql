-- ============================================================================
-- waste_management.sql  (Civic Metrics Expansion — Phase 1)
-- ----------------------------------------------------------------------------
-- Adds WASTE, the first new civic-metric pressure. See
-- citybuilder-game/docs/CIVIC_METRICS_EXPANSION.md for the full design.
--
-- Model (mirrors compute_crime intentionally):
--   * Active housing generates garbage. A house is "covered" if a STAFFED
--     sanitation building sits within its coverage_radius (Manhattan).
--     Uncovered houses pile up waste.
--   * Active production also emits a little industrial waste (building_types
--     .waste_emit), so heavy-industry cities run a higher floor.
--   * waste is a 0..100 per-player score on player_profiles.waste.
--   * waste drags desirability through the city-base term, BOUNDED at -8 so it
--     can never trigger mass devolution.
--
-- New building category 'sanitation' (+ 'power', reserved for Phase 2 so we
-- only rewrite the CHECK constraint once). Three sanitation buildings; the
-- Incinerator costs 2 machinery to build — the first capstone->infrastructure
-- sink (see design doc §2/§4).
--
-- Idempotent: safe to re-run. Additive only; existing state defaults to 0.
-- ============================================================================

BEGIN;

-- 1. Schema -----------------------------------------------------------------

ALTER TABLE public.player_profiles
  ADD COLUMN IF NOT EXISTS waste numeric NOT NULL DEFAULT 0;

ALTER TABLE public.building_types
  ADD COLUMN IF NOT EXISTS waste_emit numeric NOT NULL DEFAULT 0;

-- Widen the category CHECK to allow the new infrastructure categories.
ALTER TABLE public.building_types
  DROP CONSTRAINT IF EXISTS building_types_category_check;
ALTER TABLE public.building_types
  ADD CONSTRAINT building_types_category_check CHECK (category = ANY (ARRAY[
    'extractor','food_extractor','processor','road','housing','service','tax',
    'booster','police','park','civic','transport_hub','transport_connector',
    'sanitation','power'
  ]));

-- Industrial waste floor. Residential garbage is handled by the uncovered-house
-- term in compute_waste; production adds a modest byproduct floor.
UPDATE public.building_types SET waste_emit = 1
  WHERE category = 'processor' AND waste_emit = 0;
UPDATE public.building_types SET waste_emit = 2
  WHERE category IN ('transport_hub','transport_connector') AND waste_emit = 0;

-- 2. Sanitation buildings ---------------------------------------------------
-- output_rate is NOT NULL with no default, so set it explicitly (0).
INSERT INTO public.building_types
  (key, name, tier, industry_key, category, build_cost, worker_cost,
   output_rate, coverage_radius, upkeep_per_minute,
   pollution_emit, pollution_radius, footprint_w, footprint_h, is_active)
VALUES
  ('dump',             'Refuse Dump',      1, 'common', 'sanitation',  400,  6, 0, 5,  4, 2, 2, 1, 1, true),
  ('recycling_center', 'Recycling Center', 2, 'common', 'sanitation',  900, 12, 0, 7,  8, 0, 0, 2, 2, true),
  ('incinerator',      'Incinerator',      3, 'common', 'sanitation', 1800, 16, 0, 9, 15, 5, 3, 2, 2, true)
ON CONFLICT (key) DO UPDATE SET
  name = EXCLUDED.name, tier = EXCLUDED.tier, category = EXCLUDED.category,
  build_cost = EXCLUDED.build_cost, worker_cost = EXCLUDED.worker_cost,
  coverage_radius = EXCLUDED.coverage_radius, upkeep_per_minute = EXCLUDED.upkeep_per_minute,
  pollution_emit = EXCLUDED.pollution_emit, pollution_radius = EXCLUDED.pollution_radius,
  footprint_w = EXCLUDED.footprint_w, footprint_h = EXCLUDED.footprint_h,
  is_active = true;

-- Incinerator build cost: 2 machinery (iron capstone) — the capstone->infra sink.
INSERT INTO public.building_type_resource_costs (building_type_key, resource_key, quantity)
VALUES ('incinerator', 'machinery', 2)
ON CONFLICT (building_type_key, resource_key) DO UPDATE SET quantity = EXCLUDED.quantity;

-- 3. compute_waste ----------------------------------------------------------
-- Templated on compute_crime: uncovered housing + population + industrial floor.
CREATE OR REPLACE FUNCTION public.compute_waste(p_uid uuid)
 RETURNS numeric
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
AS $function$
DECLARE
  v_population numeric;
  v_uncovered integer;
  v_industry numeric;
  v_score numeric;
BEGIN
  SELECT population INTO v_population FROM public.player_profiles WHERE id = p_uid;
  IF v_population IS NULL THEN v_population := 5; END IF;

  -- Active houses NOT within coverage_radius of a staffed sanitation building.
  SELECT COUNT(*) INTO v_uncovered
  FROM public.buildings h
  JOIN public.building_types bt ON bt.key = h.building_type_key
  WHERE h.player_id = p_uid AND h.status = 'active' AND bt.category = 'housing'
    AND NOT EXISTS (
      SELECT 1 FROM public.buildings s
      JOIN public.building_types st ON st.key = s.building_type_key
      WHERE s.player_id = p_uid AND s.status = 'active' AND st.category = 'sanitation'
        AND s.is_staffed
        AND ABS(s.x - h.x) + ABS(s.y - h.y) <= st.coverage_radius
    );

  -- Industrial byproduct floor from staffed buildings that emit waste.
  SELECT COALESCE(SUM(bt.waste_emit), 0) INTO v_industry
  FROM public.buildings b
  JOIN public.building_types bt ON bt.key = b.building_type_key
  WHERE b.player_id = p_uid AND b.status = 'active' AND b.is_staffed
    AND bt.waste_emit > 0;

  v_score := 3
    + 3 * v_uncovered
    + LEAST(15, FLOOR(v_population / 10))
    + v_industry;

  RETURN LEAST(100, GREATEST(0, v_score));
END;
$function$;

CREATE OR REPLACE FUNCTION public._pp_update_waste(p_uid uuid)
 RETURNS numeric
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  v_waste numeric;
BEGIN
  v_waste := public.compute_waste(p_uid);
  UPDATE public.player_profiles SET waste = v_waste WHERE id = p_uid;
  RETURN v_waste;
END;
$function$;

-- 4. Staffing: sanitation + power become staffable categories ---------------
-- (rebuilt verbatim from the live definition with the two new categories added)
CREATE OR REPLACE FUNCTION public._pp_staff_buildings(p_uid uuid, p_supply integer, OUT staffed_ids uuid[], OUT workers_needed integer, OUT unstaffed_count integer)
 RETURNS record
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  v_remaining integer := p_supply;
  v_b record;
BEGIN
  staffed_ids := ARRAY[]::uuid[];
  workers_needed := 0;
  unstaffed_count := 0;

  UPDATE public.buildings b
  SET is_staffed = false
  FROM public.building_types bt
  WHERE bt.key = b.building_type_key
    AND b.player_id = p_uid AND b.status = 'active'
    AND bt.category IN ('extractor','food_extractor','booster','processor','tax','service','police','civic','sanitation','power');

  FOR v_b IN
    SELECT b.id, bt.worker_cost
    FROM public.buildings b
    JOIN public.building_types bt ON bt.key = b.building_type_key
    WHERE b.player_id = p_uid AND b.status = 'active'
      AND bt.category IN ('extractor','food_extractor','booster','processor','tax','service','police','civic','sanitation','power')
      AND public.has_road_access(p_uid, b.x, b.y)
    ORDER BY
      CASE bt.category
        WHEN 'service' THEN 2
        WHEN 'police' THEN 2
        WHEN 'civic' THEN 2
        ELSE 1
      END DESC,
      b.staffing_priority DESC,
      b.created_at ASC
  LOOP
    workers_needed := workers_needed + v_b.worker_cost;
    IF v_remaining >= v_b.worker_cost THEN
      staffed_ids := staffed_ids || v_b.id;
      v_remaining := v_remaining - v_b.worker_cost;
      UPDATE public.buildings SET is_staffed = true WHERE id = v_b.id;
    ELSE
      unstaffed_count := unstaffed_count + 1;
    END IF;
  END LOOP;
END;
$function$;

-- 5. Desirability: bounded waste drag ---------------------------------------
-- (rebuilt verbatim from the live definition + the v_waste term)
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

-- 6. Orchestrator: run waste between crime and desirability -----------------
-- (rebuilt verbatim from the live definition + the _pp_update_waste call and
--  'waste' in the return payload)
CREATE OR REPLACE FUNCTION public._pp_for_uid(p_uid uuid)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  v_base constant integer := 5;
  v_tavern_bonus integer;
  v_supply integer;
  v_staffing record;
  v_total_produced numeric := 0;
  v_total_money integer := 0;
  v_total_upkeep integer := 0;
  v_food_drained numeric := 0;
  v_evolution_events json[];
  v_operating_services uuid[];
  v_partial numeric;
  v_population numeric;
  v_crime numeric;
  v_waste numeric;
  v_productivity numeric;
  v_workers_used integer;
BEGIN
  IF p_uid IS NULL THEN RETURN NULL; END IF;
  PERFORM 1 FROM public.player_profiles WHERE id = p_uid FOR UPDATE;
  v_tavern_bonus := public._pp_tavern_bonus(p_uid);
  v_population := public._pp_update_population(p_uid);
  v_supply := FLOOR(v_population)::integer + v_tavern_bonus;

  SELECT staffed_ids, workers_needed, unstaffed_count
    INTO v_staffing
    FROM public._pp_staff_buildings(p_uid, v_supply);

  PERFORM public._pp_update_pollution(p_uid);

  v_productivity := public._pp_compute_productivity(p_uid);

  v_partial := public._pp_run_extractors(p_uid, v_staffing.staffed_ids);
  v_total_produced := v_total_produced + v_partial;
  v_partial := public._pp_run_food_extractors(p_uid, v_staffing.staffed_ids);
  v_total_produced := v_total_produced + v_partial;
  PERFORM public._pp_bump_boosters(p_uid, v_staffing.staffed_ids);
  v_partial := public._pp_run_processors(p_uid, v_staffing.staffed_ids);
  v_total_produced := v_total_produced + v_partial;

  PERFORM public._pp_run_agreements(p_uid);

  v_operating_services := public._pp_run_services(p_uid, v_staffing.staffed_ids);
  v_total_money := public._pp_run_tax(p_uid, v_staffing.staffed_ids);
  v_total_upkeep := public._pp_run_upkeep(p_uid, v_staffing.staffed_ids);

  v_food_drained := public._pp_drain_housing_food(p_uid);

  v_crime := public._pp_update_crime(p_uid);
  v_waste := public._pp_update_waste(p_uid);
  PERFORM public._pp_update_desirability(p_uid);
  v_evolution_events := public._pp_evolve_housing(p_uid, v_operating_services);

  v_supply := FLOOR(v_population)::integer + v_tavern_bonus;
  v_workers_used := LEAST(v_supply, v_staffing.workers_needed);
  UPDATE public.player_profiles
  SET worker_capacity = v_supply,
      workers_used = v_workers_used
  WHERE id = p_uid;

  PERFORM public._pp_resolve_trader_visits(p_uid);

  RETURN json_build_object(
    'total_produced', v_total_produced,
    'total_money_collected', v_total_money,
    'total_upkeep_paid', v_total_upkeep,
    'food_drained', v_food_drained,
    'evolution_events', array_to_json(v_evolution_events),
    'worker_supply', v_supply,
    'worker_capacity', v_supply,
    'workers_used', v_workers_used,
    'workers_needed', v_staffing.workers_needed,
    'unstaffed_count', v_staffing.unstaffed_count,
    'labor_shortage', (v_staffing.unstaffed_count > 0),
    'population', v_population,
    'happiness', (SELECT happiness FROM public.player_profiles WHERE id = p_uid),
    'crime', v_crime,
    'waste', v_waste,
    'migration_rate', (SELECT migration_rate FROM public.player_profiles WHERE id = p_uid),
    'productivity', v_productivity,
    'money', (SELECT money FROM public.player_profiles WHERE id = p_uid),
    'tutorial_step', (SELECT tutorial_step FROM public.player_profiles WHERE id = p_uid),
    'trade_unlocked', (SELECT trade_unlocked FROM public.player_profiles WHERE id = p_uid),
    'highest_housing_tier_ever', (SELECT highest_housing_tier_ever FROM public.player_profiles WHERE id = p_uid),
    'inventory', COALESCE(
      (SELECT json_object_agg(resource_key, quantity)
         FROM public.inventories WHERE player_id = p_uid),
      '{}'::json
    )
  );
END;
$function$;

COMMIT;
