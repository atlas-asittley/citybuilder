-- ============================================================================
-- noise_congestion.sql  (Civic Metrics Expansion — Phase 4)
-- ----------------------------------------------------------------------------
-- Two new pressures. See citybuilder-game/docs/CIVIC_METRICS_EXPANSION.md §9.
--
-- !! APPLY ORDER (manual, chronological — ONBOARDING §5): after
--    power_energy.sql (rebuilds _pp_for_uid on its version), after
--    power_energy_brownout.sql (rebuilds _pp_compute_productivity on its
--    version), AND after fancier_roads.sql (compute_congestion reads the
--    road_tier column it adds — fancier/wider roads relieve congestion).
--    Canonical order: waste → power → brownout → roads → noise_congestion.
--
--   NOISE      — per-tile, mirrors pollution exactly (footprint-aware Manhattan,
--                counts staffed emitters + any negative dampener). Industry +
--                transport emit; parks/groves dampen. SHIPS TOOTHLESS: computed
--                + shown on the heatmap, but no desirability effect yet (so it
--                can't devolve existing housing at rollout). FLIP later by
--                adding `- LEAST(10, mt.noise::integer)` to the desirability
--                city-tile expression in _pp_update_desirability.
--
--   CONGESTION — per-player 0..100. Traffic (population + staffed processors +
--                transport) vs road capacity (Σ road_tier — fancier/wider roads
--                relieve it, tying Phase 3 in). REAL but bounded + gated:
--                only throttles productivity above congestion 40, max −8%,
--                recoverable (productivity, not devolution).
--
-- Idempotent + additive. ============================================================================

BEGIN;

-- 1. Schema -----------------------------------------------------------------
ALTER TABLE public.map_tiles
  ADD COLUMN IF NOT EXISTS noise numeric NOT NULL DEFAULT 0;
ALTER TABLE public.building_types
  ADD COLUMN IF NOT EXISTS noise_emit numeric NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS noise_radius integer NOT NULL DEFAULT 0;
ALTER TABLE public.player_profiles
  ADD COLUMN IF NOT EXISTS congestion numeric NOT NULL DEFAULT 0;

-- 2. Noise emitters + dampeners --------------------------------------------
UPDATE public.building_types SET noise_emit = 3, noise_radius = 2
  WHERE category = 'processor' AND noise_emit = 0;
UPDATE public.building_types SET noise_emit = 2, noise_radius = 2
  WHERE category = 'extractor' AND noise_emit = 0;
UPDATE public.building_types SET noise_emit = 5, noise_radius = 3
  WHERE category = 'transport_hub' AND noise_emit = 0;
UPDATE public.building_types SET noise_emit = 3, noise_radius = 2
  WHERE category = 'transport_connector' AND noise_emit = 0;
-- Greenery dampens noise (negative, counted regardless of staffing).
UPDATE public.building_types SET noise_emit = -4, noise_radius = 3 WHERE key = 'park'       AND noise_emit = 0;
UPDATE public.building_types SET noise_emit = -3, noise_radius = 4 WHERE key = 'tree_grove'  AND noise_emit = 0;

-- 3. _pp_update_noise (verbatim clone of _pp_update_pollution, noise columns) -
CREATE OR REPLACE FUNCTION public._pp_update_noise(p_uid uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
BEGIN
  UPDATE public.map_tiles
  SET noise = 0
  WHERE owner_player_id = p_uid AND noise <> 0;

  UPDATE public.map_tiles mt
  SET noise = GREATEST(0, agg.total)
  FROM (
    SELECT mt2.id AS tile_id, SUM(bt.noise_emit) AS total
    FROM public.map_tiles mt2
    JOIN public.buildings b
      ON b.status = 'active'
    JOIN public.building_types bt
      ON bt.key = b.building_type_key
     AND bt.noise_emit <> 0
    WHERE mt2.owner_player_id = p_uid
      AND (
        GREATEST(0, b.x - mt2.x, mt2.x - (b.x + COALESCE(bt.footprint_w, 1) - 1))
        + GREATEST(0, b.y - mt2.y, mt2.y - (b.y + COALESCE(bt.footprint_h, 1) - 1))
      ) <= bt.noise_radius
      AND (
        b.is_staffed
        OR bt.noise_emit < 0
        OR bt.category IN ('transport_hub', 'transport_connector')
      )
    GROUP BY mt2.id
  ) agg
  WHERE mt.id = agg.tile_id;
END;
$function$;

-- 4. compute_congestion / _pp_update_congestion -----------------------------
CREATE OR REPLACE FUNCTION public.compute_congestion(p_uid uuid)
 RETURNS numeric
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
AS $function$
DECLARE
  v_population numeric;
  v_processors integer;
  v_transport integer;
  v_traffic numeric;
  v_road_cap numeric;
  v_score numeric;
BEGIN
  SELECT COALESCE(population, 0) INTO v_population FROM public.player_profiles WHERE id = p_uid;

  SELECT COUNT(*) INTO v_processors
  FROM public.buildings b JOIN public.building_types bt ON bt.key = b.building_type_key
  WHERE b.player_id = p_uid AND b.status = 'active' AND b.is_staffed AND bt.category = 'processor';

  SELECT COUNT(*) INTO v_transport
  FROM public.buildings b JOIN public.building_types bt ON bt.key = b.building_type_key
  WHERE b.player_id = p_uid AND b.status = 'active'
    AND bt.category IN ('transport_hub', 'transport_connector');

  -- Road capacity = Σ road_tier over the player's road tiles (dirt 1 …
  -- boulevard 4). Wider/fancier roads carry more traffic.
  SELECT COALESCE(SUM(bt.road_tier), 0) INTO v_road_cap
  FROM public.buildings b JOIN public.building_types bt ON bt.key = b.building_type_key
  WHERE b.player_id = p_uid AND b.status = 'active' AND bt.category = 'road';

  v_traffic := FLOOR(v_population / 5) + 2 * v_processors + 3 * v_transport;
  v_score := 5 + 4 * GREATEST(0, v_traffic - v_road_cap);
  RETURN LEAST(100, GREATEST(0, v_score));
END;
$function$;

CREATE OR REPLACE FUNCTION public._pp_update_congestion(p_uid uuid)
 RETURNS numeric
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE v_c numeric;
BEGIN
  v_c := public.compute_congestion(p_uid);
  UPDATE public.player_profiles SET congestion = v_c WHERE id = p_uid;
  RETURN v_c;
END;
$function$;

-- 5. _pp_compute_productivity: + bounded, gated congestion drag -------------
-- (rebuilt from the power_energy_brownout version + the congestion factor)
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
BEGIN
  SELECT COALESCE(crime, 0), COALESCE(population, 0),
         COALESCE(workers_used, 0), COALESCE(worker_capacity, 0),
         COALESCE(power_capacity, 0), COALESCE(power_demand, 0),
         COALESCE(congestion, 0)
  INTO v_crime, v_population, v_workers_used, v_worker_capacity,
       v_pcap, v_pdem, v_congestion
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
          AND s.building_type_key = 'school'
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

  IF v_worker_capacity > 0 AND v_workers_used >= v_worker_capacity THEN
    v_score := v_score - 0.05;
  END IF;

  v_score := GREATEST(-0.30, LEAST(0.30, v_score));
  v_productivity := GREATEST(0.7, LEAST(1.3, 1.0 + v_score));

  -- Brownout: electrified-only (capacity > 0 but short).
  IF v_pcap > 0 AND v_pdem > v_pcap THEN
    v_productivity := ROUND(v_productivity * GREATEST(0.75, v_pcap / v_pdem), 6);
  END IF;

  -- Congestion: gated (>40) + bounded (max −8%). Recoverable — build roads.
  IF v_congestion > 40 THEN
    v_productivity := ROUND(v_productivity * GREATEST(0.92, 1 - (v_congestion - 40) * 0.002), 6);
  END IF;

  UPDATE public.player_profiles SET productivity = v_productivity WHERE id = p_uid;
  RETURN v_productivity;
END;
$function$;

-- 6. Orchestrator: run noise (after pollution) + congestion (with the other
--    per-player metrics). Rebuilt from the power_energy.sql version of
--    _pp_for_uid + the two new phase calls + 'congestion' in the payload.
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
