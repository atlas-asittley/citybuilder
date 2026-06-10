-- Serialize process_production per player to prevent
-- double-application of elapsed-time deltas
-- (food drain, population update, agreements firing)
-- when two ticks land near-simultaneously.

CREATE OR REPLACE FUNCTION public.process_production()
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  v_uid uuid := auth.uid();
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
  v_productivity numeric;
  v_workers_used integer;
BEGIN
  -- Serialize per-player: take a transactional row lock on the
  -- player profile so two concurrent process_production calls (e.g.
  -- two browser tabs both ticking) cannot double-drain food /
  -- double-tick population / double-bill upkeep. Phase helpers
  -- already FOR UPDATE on individual buildings, but the per-player
  -- counters (last_food_tick_at, last_population_tick_at) had no
  -- lock so a near-simultaneous call would read the same prev_at
  -- and apply the elapsed delta twice.
  IF v_uid IS NULL THEN RAISE EXCEPTION 'auth required'; END IF;
  PERFORM 1 FROM public.player_profiles WHERE id = v_uid FOR UPDATE;
  v_tavern_bonus := public._pp_tavern_bonus(v_uid);
  v_population := public._pp_update_population(v_uid);
  v_supply := FLOOR(v_population)::integer + v_tavern_bonus;

  SELECT staffed_ids, workers_needed, unstaffed_count
    INTO v_staffing
    FROM public._pp_staff_buildings(v_uid, v_supply);

  PERFORM public._pp_update_pollution(v_uid);

  v_productivity := public._pp_compute_productivity(v_uid);

  v_partial := public._pp_run_extractors(v_uid, v_staffing.staffed_ids);
  v_total_produced := v_total_produced + v_partial;
  v_partial := public._pp_run_food_extractors(v_uid, v_staffing.staffed_ids);
  v_total_produced := v_total_produced + v_partial;
  PERFORM public._pp_bump_boosters(v_uid, v_staffing.staffed_ids);
  v_partial := public._pp_run_processors(v_uid, v_staffing.staffed_ids);
  v_total_produced := v_total_produced + v_partial;

  PERFORM public._pp_run_agreements(v_uid);

  v_operating_services := public._pp_run_services(v_uid, v_staffing.staffed_ids);
  v_total_money := public._pp_run_tax(v_uid, v_staffing.staffed_ids);
  v_total_upkeep := public._pp_run_upkeep(v_uid, v_staffing.staffed_ids);

  v_food_drained := public._pp_drain_housing_food(v_uid);

  v_crime := public._pp_update_crime(v_uid);
  PERFORM public._pp_update_desirability(v_uid);
  v_evolution_events := public._pp_evolve_housing(v_uid, v_operating_services);

  v_supply := FLOOR(v_population)::integer + v_tavern_bonus;
  v_workers_used := LEAST(v_supply, v_staffing.workers_needed);
  UPDATE public.player_profiles
  SET worker_capacity = v_supply,
      workers_used = v_workers_used
  WHERE id = v_uid;

  PERFORM public._pp_resolve_trader_visits(v_uid);

  RETURN json_build_object(
    'total_produced', v_total_produced,
    'total_money_collected', v_total_money,
    'total_upkeep_paid', v_total_upkeep,
    'food_drained', v_food_drained,
    'evolution_events', array_to_json(v_evolution_events),
    -- Worker fields: worker_supply kept for back-compat; worker_capacity
    -- and workers_used added so game.js's tick handler picks them up
    -- (Atlas-rule fix 2026-05-08: previously the topbar froze between
    -- building placements because the JSON keys didn't match the
    -- client's expected names).
    'worker_supply', v_supply,
    'worker_capacity', v_supply,
    'workers_used', v_workers_used,
    'workers_needed', v_staffing.workers_needed,
    'unstaffed_count', v_staffing.unstaffed_count,
    'labor_shortage', (v_staffing.unstaffed_count > 0),
    'population', v_population,
    'happiness', (SELECT happiness FROM public.player_profiles WHERE id = v_uid),
    'crime', v_crime,
    'migration_rate', (SELECT migration_rate FROM public.player_profiles WHERE id = v_uid),
    'productivity', v_productivity,
    'money', (SELECT money FROM public.player_profiles WHERE id = v_uid),
    'inventory', COALESCE(
      (SELECT json_object_agg(resource_key, quantity)
         FROM public.inventories WHERE player_id = v_uid),
      '{}'::json
    )
  );
END;
$function$
;
