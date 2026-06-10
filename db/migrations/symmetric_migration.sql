-- ====================================================================
-- Symmetric population dynamics + migration_rate exposure
-- ====================================================================
-- Atlas: "we just want to make sure that there isn't some sort of hole
-- that a user can get into where their people are very unhappy and so
-- everyone leaves the city and they have no chance of bringing
-- happiness back."
--
-- Old model was asymmetric: population SNAPS UP to housing capacity
-- instantly when housing > pop, but emigrates GRADUALLY when unhappy
-- (max 1/min at happiness=0). That had a built-in floor at 5 +
-- housing_supply because the snap-up always refilled to target — but
-- it also meant unhappiness barely affected pop while housing >= pop
-- (pop oscillated between target and target-delta).
--
-- New model is symmetric:
-- - max ±1/min in either direction (Atlas's "1 person per minute")
-- - Immigration scales with (happiness - 50) / 50, only at happiness ≥ 50
-- - Emigration scales with (50 - happiness) / 50, only at happiness < 50
-- - Hard floor at population = 5 — citizens NEVER drop below baseline
--   even at happiness = 0. Recovery is always possible because 5 idle
--   workers can staff a Well or Watch House.
-- - If pop < 5 (e.g. fresh player), refill at full rate regardless of
--   happiness (humanitarian floor).
-- - If pop > target (housing destroyed), snap down — homes are gone.
--
-- Also exposes migration_rate as a column on player_profiles so the
-- frontend can show a topbar indicator (positive = inflow, negative =
-- outflow, in citizens/min).

ALTER TABLE public.player_profiles
  ADD COLUMN IF NOT EXISTS migration_rate numeric NOT NULL DEFAULT 0;


CREATE OR REPLACE FUNCTION public._pp_update_population(p_uid uuid)
RETURNS numeric
LANGUAGE plpgsql SECURITY DEFINER
AS $$
DECLARE
  v_target numeric;
  v_pop numeric;
  v_happiness numeric;
  v_last timestamptz;
  v_minutes numeric;
  v_max_rate constant numeric := 1.0;  -- citizens/min cap each direction
  v_floor constant numeric := 5;       -- population never drops below this
  v_rate numeric;
BEGIN
  v_target := v_floor + public._pp_housing_supply(p_uid);

  SELECT population, last_population_tick_at INTO v_pop, v_last
  FROM public.player_profiles WHERE id = p_uid;
  IF v_pop IS NULL THEN v_pop := v_floor; END IF;
  IF v_last IS NULL THEN v_last := now() - interval '1 minute'; END IF;

  v_minutes := GREATEST(0, EXTRACT(EPOCH FROM (now() - v_last)) / 60.0);
  IF v_minutes > 60 THEN v_minutes := 60; END IF;  -- cap catch-up window

  v_happiness := (public.compute_happiness(p_uid)->>'happiness')::numeric;

  IF v_pop > v_target THEN
    -- Housing destroyed/devolved below pop. Snap down — the homes
    -- physically don't exist anymore. Not an emigration event.
    v_rate := 0;
    v_pop := v_target;
  ELSIF v_pop < v_floor THEN
    -- Hard floor: always recover toward 5 baseline citizens at full
    -- rate, regardless of happiness. Prevents the death-spiral
    -- Atlas asked about — even at happiness=0, you keep 5 workers
    -- which can staff a Well or Watch House to start clawing back.
    v_rate := v_max_rate;
    v_pop := LEAST(v_floor, v_pop + v_rate * v_minutes);
  ELSIF v_pop < v_target AND v_happiness >= 50 THEN
    -- Immigration: rate scales with happiness above 50.
    -- happiness=50 → 0/min; happiness=100 → 1/min.
    v_rate := ((v_happiness - 50) / 50.0) * v_max_rate;
    v_pop := LEAST(v_target, v_pop + v_rate * v_minutes);
  ELSIF v_happiness < 50 AND v_pop > v_floor THEN
    -- Emigration: rate scales with happiness below 50.
    -- happiness=49 → -0.02/min; happiness=0 → -1/min.
    -- Floor at v_floor = 5 — citizens never leave below baseline.
    v_rate := -((50 - v_happiness) / 50.0) * v_max_rate;
    v_pop := GREATEST(v_floor, v_pop + v_rate * v_minutes);
  ELSE
    -- At target with happiness ≥ 50, or at floor with happiness < 50.
    v_rate := 0;
  END IF;

  UPDATE public.player_profiles
  SET population = v_pop,
      happiness = v_happiness,
      migration_rate = v_rate,
      last_population_tick_at = now()
  WHERE id = p_uid;

  RETURN v_pop;
END;
$$;


-- process_production: include migration_rate in the JSON response so
-- the topbar indicator can render it without a separate fetch.
CREATE OR REPLACE FUNCTION public.process_production()
RETURNS json
LANGUAGE plpgsql SECURITY DEFINER
AS $$
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
BEGIN
  v_tavern_bonus := public._pp_tavern_bonus(v_uid);

  v_population := public._pp_update_population(v_uid);
  v_supply := FLOOR(v_population)::integer + v_tavern_bonus;

  SELECT staffed_ids, workers_needed, unstaffed_count
    INTO v_staffing
    FROM public._pp_staff_buildings(v_uid, v_supply);

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

  v_evolution_events := public._pp_evolve_housing(v_uid, v_operating_services);

  v_crime := public._pp_update_crime(v_uid);

  v_supply := FLOOR(v_population)::integer + v_tavern_bonus;
  UPDATE public.player_profiles
  SET worker_capacity = v_supply,
      workers_used = LEAST(v_supply, v_staffing.workers_needed)
  WHERE id = v_uid;

  RETURN json_build_object(
    'total_produced', v_total_produced,
    'total_money_collected', v_total_money,
    'total_upkeep_paid', v_total_upkeep,
    'food_drained', v_food_drained,
    'evolution_events', array_to_json(v_evolution_events),
    'worker_supply', v_supply,
    'workers_needed', v_staffing.workers_needed,
    'unstaffed_count', v_staffing.unstaffed_count,
    'population', v_population,
    'happiness', (SELECT happiness FROM public.player_profiles WHERE id = v_uid),
    'crime', v_crime,
    'migration_rate', (SELECT migration_rate FROM public.player_profiles WHERE id = v_uid)
  );
END;
$$;
