-- Happiness system: per-player happiness drives a per-tick drift of a
-- stored `population` toward housing capacity. worker_capacity becomes
-- floor(population) + tavern_bonus. See docs/HAPPINESS.md.

-- ── 1. Schema ───────────────────────────────────────────
ALTER TABLE public.player_profiles
  ADD COLUMN IF NOT EXISTS population numeric NOT NULL DEFAULT 5;
ALTER TABLE public.player_profiles
  ADD COLUMN IF NOT EXISTS happiness numeric NOT NULL DEFAULT 50;
ALTER TABLE public.player_profiles
  ADD COLUMN IF NOT EXISTS last_population_tick_at timestamptz NOT NULL DEFAULT now();

-- Seed existing players so they don't suddenly drop to population=5.
-- A row whose population equals the default AND already has
-- worker_capacity above default is a pre-existing player — bump them
-- up so the transition is invisible.
UPDATE public.player_profiles
SET population = GREATEST(5, worker_capacity)
WHERE population = 5 AND worker_capacity > 5;

-- ── 2. compute_happiness ────────────────────────────────
-- Returns 0..100. Six weighted inputs (see docs/HAPPINESS.md):
--   30 base
--   +3 per operational service (well + tavern + bathhouse + school + temple)
--   +2 × avg active housing tier
--   +min(15, distinct foods × 2)
--   -3 per active tax office
--   +20 × (staffed / total worker buildings)
CREATE OR REPLACE FUNCTION public.compute_happiness(p_uid uuid)
RETURNS json
LANGUAGE plpgsql STABLE SECURITY DEFINER AS $$
DECLARE
  v_base constant numeric := 30;
  v_services integer := 0;
  v_avg_tier numeric := 0;
  v_food_variety integer := 0;
  v_tax_count integer := 0;
  v_staffed integer := 0;
  v_total_worker_bldgs integer := 0;
  v_score numeric;
BEGIN
  -- Operational services. Well counts when active + road-connected.
  -- Tavern/bathhouse/school/temple count when staffed AND fed (i.e.
  -- active + has_road_access + both inputs cover the elapsed tick).
  -- For the happiness check we use a slightly looser test — staffed
  -- and inputs > 0 in inventory — to avoid coupling with the
  -- per-tick service-feed logic.
  IF EXISTS (
    SELECT 1 FROM public.buildings b
    JOIN public.building_types bt ON bt.key = b.building_type_key
    WHERE b.player_id = p_uid AND b.status = 'active' AND bt.key = 'well'
      AND public.has_road_access(p_uid, b.x, b.y)
  ) THEN v_services := v_services + 1; END IF;

  -- Tavern/bathhouse/school/temple: staffed (status='active') + road-adjacent + inputs in stock.
  v_services := v_services + (
    SELECT COUNT(DISTINCT bt.key) FROM public.buildings b
    JOIN public.building_types bt ON bt.key = b.building_type_key
    WHERE b.player_id = p_uid AND b.status = 'active'
      AND bt.category = 'service' AND bt.key <> 'well'
      AND public.has_road_access(p_uid, b.x, b.y)
      AND COALESCE((SELECT quantity FROM public.inventories i
                    WHERE i.player_id = p_uid AND i.resource_key = bt.input_resource_key), 0) > 0
      AND (bt.input_resource_key_2 IS NULL
           OR COALESCE((SELECT quantity FROM public.inventories i
                        WHERE i.player_id = p_uid AND i.resource_key = bt.input_resource_key_2), 0) > 0)
  );

  -- Avg active housing tier.
  SELECT COALESCE(AVG(b.housing_tier), 0) INTO v_avg_tier
  FROM public.buildings b
  JOIN public.building_types bt ON bt.key = b.building_type_key
  WHERE b.player_id = p_uid AND b.status = 'active' AND bt.category = 'housing';

  -- Distinct is_food resources currently in stock (qty > 0).
  SELECT COUNT(*) INTO v_food_variety
  FROM public.inventories i
  JOIN public.resources r ON r.key = i.resource_key
  WHERE i.player_id = p_uid AND r.is_food AND i.quantity > 0;

  -- Active tax offices.
  SELECT COUNT(*) INTO v_tax_count
  FROM public.buildings b
  JOIN public.building_types bt ON bt.key = b.building_type_key
  WHERE b.player_id = p_uid AND b.status = 'active' AND bt.category = 'tax';

  -- Staffing health.
  SELECT
    COUNT(*) FILTER (WHERE b.id = ANY(ARRAY(SELECT id FROM public.buildings sb
                                            JOIN public.building_types sbt ON sbt.key = sb.building_type_key
                                            WHERE sb.player_id = p_uid AND sb.status = 'active'
                                              AND sbt.category IN ('extractor','food_extractor','booster','processor','tax','service')
                                              AND public.has_road_access(p_uid, sb.x, sb.y)
                                            ORDER BY sb.staffing_priority DESC, sb.created_at ASC))),
    COUNT(*)
  INTO v_staffed, v_total_worker_bldgs
  FROM public.buildings b
  JOIN public.building_types bt ON bt.key = b.building_type_key
  WHERE b.player_id = p_uid AND b.status = 'active'
    AND bt.category IN ('extractor','food_extractor','booster','processor','tax','service');

  -- Approximate staffed = (worker_supply >= sum of worker_costs)?
  -- Simpler: assume all that meet road-access are staffed if total
  -- worker_cost <= worker_capacity. Even simpler for this metric:
  -- count the buildings actually assigned in the last process_production.
  -- For now, approximate via worker capacity vs need.
  -- We'll just return total - unstaffed via a direct query:
  SELECT COALESCE((SELECT GREATEST(0, v_total_worker_bldgs - COUNT(*))
                   FROM public.buildings b2
                   JOIN public.building_types bt2 ON bt2.key = b2.building_type_key
                   WHERE b2.player_id = p_uid AND b2.status = 'active'
                     AND bt2.category IN ('extractor','food_extractor','booster','processor','tax','service')
                     AND NOT public.has_road_access(p_uid, b2.x, b2.y)), 0)
  INTO v_staffed;
  -- v_staffed now ≈ road-connected worker buildings; treat that as
  -- "staffable". Good-enough proxy without re-running the staffing loop.

  v_score :=
    v_base
    + 3 * v_services
    + 2 * v_avg_tier
    + LEAST(15, v_food_variety * 2)
    - 3 * v_tax_count
    + CASE WHEN v_total_worker_bldgs > 0
           THEN 20.0 * (v_staffed::numeric / v_total_worker_bldgs::numeric)
           ELSE 20.0   -- no worker buildings yet → neutral max-staffing score
      END;

  RETURN json_build_object(
    'happiness', LEAST(100, GREATEST(0, v_score)),
    'breakdown', json_build_object(
      'base', v_base,
      'services', v_services,
      'avg_tier', v_avg_tier,
      'food_variety', v_food_variety,
      'tax_count', v_tax_count,
      'staffed', v_staffed,
      'total_worker_bldgs', v_total_worker_bldgs
    )
  );
END;
$$;
GRANT EXECUTE ON FUNCTION public.compute_happiness(uuid) TO authenticated;

-- ── 3. _pp_update_population ────────────────────────────
-- Phase helper for the process_production orchestrator. Drifts
-- population toward (5 + housing_workers) at ±1/min based on
-- (happiness - 50)/50. Returns the new population (numeric).
CREATE OR REPLACE FUNCTION public._pp_update_population(p_uid uuid)
RETURNS numeric
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_target numeric;
  v_pop numeric;
  v_happiness numeric;
  v_last timestamptz;
  v_minutes numeric;
  v_velocity numeric;
  v_max_rate constant numeric := 1.0;
  v_delta numeric;
BEGIN
  -- Target: 5 base + Σ housing tier workers.
  v_target := 5 + public._pp_housing_supply(p_uid);

  SELECT population, last_population_tick_at INTO v_pop, v_last
  FROM public.player_profiles WHERE id = p_uid;
  IF v_pop IS NULL THEN v_pop := 5; END IF;
  IF v_last IS NULL THEN v_last := now() - interval '1 minute'; END IF;

  v_minutes := GREATEST(0, EXTRACT(EPOCH FROM (now() - v_last)) / 60.0);
  IF v_minutes > 60 THEN v_minutes := 60; END IF;  -- cap catch-up at 1 hour

  v_happiness := (public.compute_happiness(p_uid)->>'happiness')::numeric;

  v_velocity := (v_happiness - 50.0) / 50.0;  -- [-1, +1]
  v_delta := v_velocity * v_max_rate * v_minutes;

  v_pop := GREATEST(0, LEAST(v_target, v_pop + v_delta));

  UPDATE public.player_profiles
  SET population = v_pop,
      happiness = v_happiness,
      last_population_tick_at = now()
  WHERE id = p_uid;

  RETURN v_pop;
END;
$$;
GRANT EXECUTE ON FUNCTION public._pp_update_population(uuid) TO authenticated;

-- ── 4. Wire population into process_production ──────────
-- The orchestrator currently computes worker_supply as
--   5 + _pp_housing_supply + _pp_tavern_bonus.
-- Replace with floor(population) + tavern_bonus, where population was
-- updated by _pp_update_population earlier in the tick.
CREATE OR REPLACE FUNCTION public.process_production()
RETURNS json
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_base constant integer := 5;
  v_tavern_bonus integer;
  v_supply integer;
  v_staffing record;
  v_total_produced numeric := 0;
  v_total_money integer := 0;
  v_food_drained numeric := 0;
  v_evolution_events json[];
  v_operating_services uuid[];
  v_partial numeric;
  v_population numeric;
BEGIN
  -- Capture tavern bonus ONCE up front (same reasoning as before:
  -- service loop will update tavern timestamps mid-tick).
  v_tavern_bonus := public._pp_tavern_bonus(v_uid);

  -- Population-driven supply: drift toward (5 + housing) at ±1/min by happiness.
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

  v_operating_services := public._pp_run_services(v_uid, v_staffing.staffed_ids);
  v_total_money := public._pp_run_tax(v_uid, v_staffing.staffed_ids);

  v_food_drained := public._pp_drain_housing_food(v_uid);

  v_evolution_events := public._pp_evolve_housing(v_uid, v_operating_services);

  -- Final supply: re-floor population (housing tier may have changed
  -- via evolution, which expands the cap; but population doesn't tick
  -- a second time within the same call). Reuse the start-of-tick
  -- tavern bonus.
  v_supply := FLOOR(v_population)::integer + v_tavern_bonus;
  UPDATE public.player_profiles
  SET worker_capacity = v_supply,
      workers_used = LEAST(v_supply, v_staffing.workers_needed)
  WHERE id = v_uid;

  RETURN json_build_object(
    'total_produced', v_total_produced,
    'total_money_collected', v_total_money,
    'food_drained', v_food_drained,
    'evolution_events', array_to_json(v_evolution_events),
    'worker_supply', v_supply,
    'workers_needed', v_staffing.workers_needed,
    'unstaffed_count', v_staffing.unstaffed_count,
    'population', v_population,
    'happiness', (SELECT happiness FROM public.player_profiles WHERE id = v_uid)
  );
END;
$$;
GRANT EXECUTE ON FUNCTION public.process_production() TO authenticated;
