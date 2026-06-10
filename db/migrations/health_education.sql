-- ============================================================================
-- health_education.sql  (Civic Metrics Expansion — Phase 5)
-- ----------------------------------------------------------------------------
-- Two new STANDINGS (higher = better) + the food-variety housing-gate scaffold.
-- See citybuilder-game/docs/CIVIC_METRICS_EXPANSION.md §9–10.
--
-- !! APPLY ORDER (manual, chronological — ONBOARDING §5): LAST in the
--    expansion. Rebuilds _pp_for_uid on the noise_congestion version and
--    _pp_compute_productivity on the noise_congestion version. Canonical
--    order: waste -> power -> brownout -> roads -> noise_congestion ->
--    health_education.
--
--   EDUCATION (0..100) — % of housing within Chebyshev 5 of a staffed School
--     OR the new Library. Stored for display; ALSO real (upside): the existing
--     productivity education bonus now counts Libraries too.
--   HEALTH (0..100) — 50 + up to +30 for Clinic/Hospital housing coverage,
--     minus a bounded waste drag. UPSIDE-ONLY effect: health > 70 grants a
--     small productivity bonus; low health is never penalised, so existing
--     cities can only benefit.
--   Clinic + Library — category='service' (reuse staffing/road/feed machinery).
--     They consume lumber + glass while operating (timber/clay demand). Real
--     upside (health/education → productivity) gives players a reason to build
--     and feed them, so the sink is live.
--   FOOD-VARIETY — adds housing_tier_config.food_variety_required and populates
--     it (T4+ want 2 distinct foods, T6+ want 3). SHIPS TOOTHLESS: column +
--     values only; NOT yet read by _pp_evolve_housing (enforcing it could
--     strand existing cities). FLIP later by gating evolution on the count of
--     distinct in-stock is_food resources. This is the structural fix that
--     de-thrones iron's bread monopoly.
--
-- Idempotent + additive. ============================================================================

BEGIN;

-- 1. Schema -----------------------------------------------------------------
ALTER TABLE public.player_profiles
  ADD COLUMN IF NOT EXISTS health    numeric NOT NULL DEFAULT 50,
  ADD COLUMN IF NOT EXISTS education numeric NOT NULL DEFAULT 0;
ALTER TABLE public.housing_tier_config
  ADD COLUMN IF NOT EXISTS food_variety_required integer NOT NULL DEFAULT 1;

-- Food-variety targets (toothless until _pp_evolve_housing reads them).
UPDATE public.housing_tier_config SET food_variety_required = 1 WHERE tier <= 3;
UPDATE public.housing_tier_config SET food_variety_required = 2 WHERE tier BETWEEN 4 AND 5;
UPDATE public.housing_tier_config SET food_variety_required = 3 WHERE tier >= 6;

-- 2. Clinic + Library (services that consume lumber + glass) -----------------
INSERT INTO public.building_types
  (key, name, tier, industry_key, category, build_cost, worker_cost,
   output_rate, input_resource_key, input_rate, input_resource_key_2, input_rate_2,
   coverage_radius, footprint_w, footprint_h, is_active)
VALUES
  ('clinic',  'Clinic',  2, 'common', 'service', 600, 8, 0, 'lumber', 0.25, 'glass', 0.25, 5, 2, 1, true),
  ('library', 'Library', 2, 'common', 'service', 600, 8, 0, 'lumber', 0.25, 'glass', 0.25, 5, 2, 1, true)
ON CONFLICT (key) DO UPDATE SET
  name = EXCLUDED.name, category = EXCLUDED.category, build_cost = EXCLUDED.build_cost,
  worker_cost = EXCLUDED.worker_cost, input_resource_key = EXCLUDED.input_resource_key,
  input_rate = EXCLUDED.input_rate, input_resource_key_2 = EXCLUDED.input_resource_key_2,
  input_rate_2 = EXCLUDED.input_rate_2, coverage_radius = EXCLUDED.coverage_radius,
  footprint_w = EXCLUDED.footprint_w, footprint_h = EXCLUDED.footprint_h, is_active = true;

-- 3. compute_education / compute_health -------------------------------------
CREATE OR REPLACE FUNCTION public.compute_education(p_uid uuid)
 RETURNS numeric
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
AS $function$
DECLARE
  v_total integer;
  v_covered integer;
BEGIN
  SELECT COUNT(*) INTO v_total
  FROM public.buildings b JOIN public.building_types bt ON bt.key = b.building_type_key
  WHERE b.player_id = p_uid AND b.status = 'active'
    AND bt.category = 'housing' AND COALESCE(b.housing_tier, 0) >= 1;
  IF v_total = 0 THEN RETURN 0; END IF;

  SELECT COUNT(*) INTO v_covered
  FROM public.buildings h JOIN public.building_types bt ON bt.key = h.building_type_key
  WHERE h.player_id = p_uid AND h.status = 'active'
    AND bt.category = 'housing' AND COALESCE(h.housing_tier, 0) >= 1
    AND EXISTS (
      SELECT 1 FROM public.buildings s
      WHERE s.player_id = p_uid AND s.status = 'active' AND s.is_staffed
        AND s.building_type_key IN ('school', 'library')
        AND GREATEST(ABS(s.x - h.x), ABS(s.y - h.y)) <= 5
    );
  RETURN ROUND(100.0 * v_covered / v_total, 2);
END;
$function$;

CREATE OR REPLACE FUNCTION public.compute_health(p_uid uuid)
 RETURNS numeric
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
AS $function$
DECLARE
  v_total integer;
  v_covered integer;
  v_waste numeric;
  v_score numeric;
BEGIN
  SELECT COALESCE(waste, 0) INTO v_waste FROM public.player_profiles WHERE id = p_uid;

  SELECT COUNT(*) INTO v_total
  FROM public.buildings b JOIN public.building_types bt ON bt.key = b.building_type_key
  WHERE b.player_id = p_uid AND b.status = 'active'
    AND bt.category = 'housing' AND COALESCE(b.housing_tier, 0) >= 1;

  IF v_total = 0 THEN
    -- No housing yet: neutral baseline minus any waste drag.
    RETURN LEAST(100, GREATEST(0, 50 - LEAST(15, FLOOR(v_waste / 4)::integer)));
  END IF;

  SELECT COUNT(*) INTO v_covered
  FROM public.buildings h JOIN public.building_types bt ON bt.key = h.building_type_key
  WHERE h.player_id = p_uid AND h.status = 'active'
    AND bt.category = 'housing' AND COALESCE(h.housing_tier, 0) >= 1
    AND EXISTS (
      SELECT 1 FROM public.buildings c
      WHERE c.player_id = p_uid AND c.status = 'active' AND c.is_staffed
        AND c.building_type_key IN ('clinic', 'hospital')
        AND GREATEST(ABS(c.x - h.x), ABS(c.y - h.y)) <= 5
    );

  v_score := 50
    + 30.0 * v_covered / v_total          -- up to +30 for full coverage
    - LEAST(15, FLOOR(v_waste / 4)::integer);
  RETURN LEAST(100, GREATEST(0, ROUND(v_score, 2)));
END;
$function$;

CREATE OR REPLACE FUNCTION public._pp_update_health_education(p_uid uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
BEGIN
  UPDATE public.player_profiles
  SET health = public.compute_health(p_uid),
      education = public.compute_education(p_uid)
  WHERE id = p_uid;
END;
$function$;

-- 4. _pp_compute_productivity: Library counts toward the education bonus, and
--    high health grants a small upside. (Rebuilt on the noise_congestion
--    version.)
CREATE OR REPLACE FUNCTION public._pp_compute_productivity(p_uid uuid)
 RETURNS numeric
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  v_crime numeric;
  v_tavern boolean;
  v_score numeric := 0;
  v_total_houses integer;
  v_covered_houses integer;
  v_coverage numeric;
  v_edu_bonus numeric;
  v_population numeric;
  v_pop_floor integer;
  v_tools numeric;
  v_workers_used integer;
  v_worker_capacity integer;
  v_productivity numeric;
  v_pcap numeric;
  v_pdem numeric;
  v_congestion numeric;
  v_health numeric;
BEGIN
  SELECT COALESCE(crime, 0), COALESCE(population, 0),
         COALESCE(workers_used, 0), COALESCE(worker_capacity, 0),
         COALESCE(power_capacity, 0), COALESCE(power_demand, 0),
         COALESCE(congestion, 0), COALESCE(health, 50)
  INTO v_crime, v_population, v_workers_used, v_worker_capacity,
       v_pcap, v_pdem, v_congestion, v_health
  FROM public.player_profiles WHERE id = p_uid;

  IF v_crime > 50 THEN
    v_score := v_score - LEAST(0.10, (v_crime - 50) * 0.005);
  END IF;

  SELECT EXISTS (
    SELECT 1 FROM public.buildings b
    WHERE b.player_id = p_uid AND b.status = 'active' AND b.is_staffed
      AND b.building_type_key = 'tavern'
  ) INTO v_tavern;
  IF v_tavern THEN v_score := v_score + 0.05; END IF;

  SELECT COUNT(*) INTO v_total_houses
  FROM public.buildings b
  JOIN public.building_types bt ON bt.key = b.building_type_key
  WHERE b.player_id = p_uid AND b.status = 'active'
    AND bt.category = 'housing' AND COALESCE(b.housing_tier, 0) >= 1;

  IF v_total_houses > 0 THEN
    SELECT COUNT(*) INTO v_covered_houses
    FROM public.buildings h
    JOIN public.building_types bt ON bt.key = h.building_type_key
    WHERE h.player_id = p_uid AND h.status = 'active'
      AND bt.category = 'housing' AND COALESCE(h.housing_tier, 0) >= 1
      AND EXISTS (
        SELECT 1 FROM public.buildings s
        WHERE s.player_id = p_uid AND s.status = 'active' AND s.is_staffed
          AND s.building_type_key IN ('school', 'library')
          AND GREATEST(ABS(s.x - h.x), ABS(s.y - h.y)) <= 5
      );
    v_coverage := v_covered_houses::numeric / v_total_houses::numeric;
    v_edu_bonus := LEAST(0.10, FLOOR(v_coverage * 10) * 0.03);
    v_score := v_score + v_edu_bonus;
  END IF;

  v_pop_floor := FLOOR(v_population)::integer;
  IF v_pop_floor > 0 THEN
    SELECT COALESCE(quantity, 0) INTO v_tools
    FROM public.inventories
    WHERE player_id = p_uid AND resource_key = 'tools';
    v_tools := COALESCE(v_tools, 0);
    IF v_tools >= v_pop_floor * 0.5 THEN
      v_score := v_score + 0.10;
    ELSIF v_tools >= v_pop_floor * 0.2 THEN
      v_score := v_score + 0.05;
    END IF;
  END IF;

  -- Health upside: a well-served city works a little better. No penalty for
  -- low health → existing cities can only gain.
  IF v_health > 70 THEN v_score := v_score + 0.05; END IF;

  IF v_worker_capacity > 0 AND v_workers_used >= v_worker_capacity THEN
    v_score := v_score - 0.05;
  END IF;

  v_score := GREATEST(-0.30, LEAST(0.30, v_score));
  v_productivity := GREATEST(0.7, LEAST(1.3, 1.0 + v_score));

  IF v_pcap > 0 AND v_pdem > v_pcap THEN
    v_productivity := ROUND(v_productivity * GREATEST(0.75, v_pcap / v_pdem), 6);
  END IF;
  IF v_congestion > 40 THEN
    v_productivity := ROUND(v_productivity * GREATEST(0.92, 1 - (v_congestion - 40) * 0.002), 6);
  END IF;

  UPDATE public.player_profiles SET productivity = v_productivity WHERE id = p_uid;
  RETURN v_productivity;
END;
$function$;

-- 5. Orchestrator: update health/education with the other per-player metrics.
--    (Rebuilt on the noise_congestion version + the new phase + payload.)
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
  v_congestion numeric;
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
  PERFORM public._pp_update_noise(p_uid);

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
  v_congestion := public._pp_update_congestion(p_uid);
  PERFORM public._pp_update_power(p_uid);
  PERFORM public._pp_update_health_education(p_uid);
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
    'congestion', v_congestion,
    'health', (SELECT health FROM public.player_profiles WHERE id = p_uid),
    'education', (SELECT education FROM public.player_profiles WHERE id = p_uid),
    'power_capacity', (SELECT power_capacity FROM public.player_profiles WHERE id = p_uid),
    'power_demand', (SELECT power_demand FROM public.player_profiles WHERE id = p_uid),
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
