-- ============================================================================
-- power_energy.sql  (Civic Metrics Expansion — Phase 2)
-- ----------------------------------------------------------------------------
-- Adds POWER, a city-wide utility (capacity vs demand). See
-- citybuilder-game/docs/CIVIC_METRICS_EXPANSION.md §7.
--
-- !! APPLY ORDER: this migration MUST run AFTER waste_management.sql. It
--    redefines _pp_for_uid on top of the WASTE version (keeps the waste phase),
--    and the 'power' category + its staffing were already reserved by
--    waste_management.sql. Migrations apply chronologically; this was authored
--    after waste_management.sql.
--
-- Model:
--   * power_capacity = Σ power_output of STAFFED power buildings. Fuel-free
--     mills always contribute; the charcoal-fired Powerhouse only contributes
--     when it has charcoal in stock (and burns input_rate each tick) — the
--     TIMBER sink. The Powerhouse also costs 1 machinery to build (IRON sink).
--   * power_demand = Σ power_load of STAFFED consumers (processors + transport).
--     Extractors / food / housing / services draw none.
--   * Both are stored on player_profiles for display.
--
-- !! VISIBLE-BUT-TOOTHLESS: the brownout productivity penalty is intentionally
--    NOT wired yet. Computing + displaying capacity/demand is safe for existing
--    live cities (which would otherwise have demand > 0 with no plants → an
--    immediate productivity hit). To FLIP IT ON after playtesting, have
--    _pp_compute_productivity multiply its result by
--    clamp(power_capacity / GREATEST(1, power_demand), 0.6, 1.0)  — one spot,
--    no schema change.
--
-- Idempotent + additive. NOT applied to live until the matching frontend ships.
-- ============================================================================

BEGIN;

-- 1. Schema -----------------------------------------------------------------
ALTER TABLE public.player_profiles
  ADD COLUMN IF NOT EXISTS power_capacity numeric NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS power_demand   numeric NOT NULL DEFAULT 0;

ALTER TABLE public.building_types
  ADD COLUMN IF NOT EXISTS power_output numeric NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS power_load   numeric NOT NULL DEFAULT 0;

-- 2. Power demand: processing + logistics are power-hungry. -----------------
UPDATE public.building_types SET power_load = 3
  WHERE category = 'processor' AND power_load = 0;
UPDATE public.building_types SET power_load = 8
  WHERE category = 'transport_hub' AND power_load = 0;
UPDATE public.building_types SET power_load = 4
  WHERE category = 'transport_connector' AND power_load = 0;

-- 3. Power buildings --------------------------------------------------------
-- output_rate is NOT NULL with no default, so set it explicitly (0). The
-- Powerhouse uses input_resource_key/input_rate to burn charcoal — no other
-- tick loop touches the 'power' category, so reusing those columns is safe.
INSERT INTO public.building_types
  (key, name, tier, industry_key, category, build_cost, worker_cost,
   output_rate, power_output, input_resource_key, input_rate,
   upkeep_per_minute, pollution_emit, pollution_radius,
   footprint_w, footprint_h, is_active)
VALUES
  ('watermill',  'Watermill',  2, 'common', 'power',  700,  4, 0, 20, NULL,        0,    3, 0, 0, 1, 1, true),
  ('windmill',   'Windmill',   2, 'common', 'power',  700,  4, 0, 20, NULL,        0,    3, 0, 0, 1, 1, true),
  ('powerhouse', 'Powerhouse', 3, 'common', 'power', 1600, 10, 0, 80, 'charcoal',  0.5, 10, 4, 3, 2, 2, true)
ON CONFLICT (key) DO UPDATE SET
  name = EXCLUDED.name, tier = EXCLUDED.tier, category = EXCLUDED.category,
  build_cost = EXCLUDED.build_cost, worker_cost = EXCLUDED.worker_cost,
  power_output = EXCLUDED.power_output,
  input_resource_key = EXCLUDED.input_resource_key, input_rate = EXCLUDED.input_rate,
  upkeep_per_minute = EXCLUDED.upkeep_per_minute,
  pollution_emit = EXCLUDED.pollution_emit, pollution_radius = EXCLUDED.pollution_radius,
  footprint_w = EXCLUDED.footprint_w, footprint_h = EXCLUDED.footprint_h,
  is_active = true;

-- Powerhouse build cost: 1 machinery (iron capstone → infrastructure sink).
INSERT INTO public.building_type_resource_costs (building_type_key, resource_key, quantity)
VALUES ('powerhouse', 'machinery', 1)
ON CONFLICT (building_type_key, resource_key) DO UPDATE SET quantity = EXCLUDED.quantity;

-- 4. _pp_update_power -------------------------------------------------------
CREATE OR REPLACE FUNCTION public._pp_update_power(p_uid uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  v_capacity numeric := 0;
  v_demand numeric := 0;
  v_b record;
  v_have numeric;
BEGIN
  -- Demand: staffed consumers that draw load.
  SELECT COALESCE(SUM(bt.power_load), 0) INTO v_demand
  FROM public.buildings b
  JOIN public.building_types bt ON bt.key = b.building_type_key
  WHERE b.player_id = p_uid AND b.status = 'active' AND b.is_staffed
    AND bt.power_load > 0;

  -- Capacity: staffed power buildings. Fuelled plants burn their input.
  FOR v_b IN
    SELECT b.id, bt.power_output, bt.input_resource_key, bt.input_rate
    FROM public.buildings b
    JOIN public.building_types bt ON bt.key = b.building_type_key
    WHERE b.player_id = p_uid AND b.status = 'active' AND b.is_staffed
      AND bt.category = 'power' AND bt.power_output > 0
  LOOP
    IF v_b.input_resource_key IS NULL OR v_b.input_rate <= 0 THEN
      v_capacity := v_capacity + v_b.power_output;            -- fuel-free
    ELSE
      SELECT quantity INTO v_have FROM public.inventories
        WHERE player_id = p_uid AND resource_key = v_b.input_resource_key;
      IF COALESCE(v_have, 0) >= v_b.input_rate THEN
        UPDATE public.inventories
          SET quantity = ROUND(quantity - v_b.input_rate, 6)
          WHERE player_id = p_uid AND resource_key = v_b.input_resource_key;
        v_capacity := v_capacity + v_b.power_output;
      END IF;                                                  -- unfuelled → 0
    END IF;
  END LOOP;

  UPDATE public.player_profiles
    SET power_capacity = v_capacity, power_demand = v_demand
    WHERE id = p_uid;
END;
$function$;

-- 5. Orchestrator: run power after waste ------------------------------------
-- (rebuilt from the waste_management.sql version of _pp_for_uid + the
--  _pp_update_power call and power_capacity/power_demand in the payload)
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
