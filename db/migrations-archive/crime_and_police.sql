-- Crime + police system. See docs/CRIME.md for the full design.

-- ── 1. Schema ───────────────────────────────────────────
ALTER TABLE public.building_types
  ADD COLUMN IF NOT EXISTS coverage_radius integer NOT NULL DEFAULT 0;
ALTER TABLE public.building_types
  ADD COLUMN IF NOT EXISTS upkeep_per_minute integer NOT NULL DEFAULT 0;

ALTER TABLE public.player_profiles
  ADD COLUMN IF NOT EXISTS crime numeric NOT NULL DEFAULT 10;

-- Extend the category check to admit 'police'.
ALTER TABLE public.building_types DROP CONSTRAINT IF EXISTS building_types_category_check;
ALTER TABLE public.building_types ADD CONSTRAINT building_types_category_check
  CHECK (category IN ('extractor','processor','housing','road','service','tax',
                      'food_extractor','booster','police'));

-- Extend cash_transactions source check to admit 'upkeep'.
ALTER TABLE public.cash_transactions DROP CONSTRAINT IF EXISTS cash_source_check;
ALTER TABLE public.cash_transactions ADD CONSTRAINT cash_source_check
  CHECK (source IN ('tax_revenue','build_cost','expansion_cost',
                    'starting_grant','demolish_refund','upkeep'));

-- ── 2. Seed the three police building types ─────────────
-- Common to all industries (police is a civic concern). Tier reuses the
-- existing 1..4 scale; policed correctly via category='police'.
INSERT INTO public.building_types
  (key, name, category, industry_key, tier, build_cost, worker_cost,
   output_resource_key, output_rate, input_resource_key, input_rate,
   coverage_radius, upkeep_per_minute, unlocks_at_housing_tier, is_active)
VALUES
  ('watch_house',    'Watch House',     'police', 'common', 1, 300,  5, NULL, 0, NULL, 0, 4,  5, NULL, TRUE),
  ('police_station', 'Police Station',  'police', 'common', 2, 700, 10, NULL, 0, NULL, 0, 6, 12, 3,    TRUE),
  ('constabulary',   'Constabulary',    'police', 'common', 3, 1500,15, NULL, 0, NULL, 0, 8, 25, 5,    TRUE)
ON CONFLICT (key) DO UPDATE SET
  name = EXCLUDED.name,
  build_cost = EXCLUDED.build_cost,
  worker_cost = EXCLUDED.worker_cost,
  coverage_radius = EXCLUDED.coverage_radius,
  upkeep_per_minute = EXCLUDED.upkeep_per_minute,
  unlocks_at_housing_tier = EXCLUDED.unlocks_at_housing_tier,
  is_active = EXCLUDED.is_active;

-- ── 3. Add 'police' to worker-loop helpers ──────────────
-- _pp_workers_needed: include police in the worker-need sum.
CREATE OR REPLACE FUNCTION public._pp_workers_needed(p_uid uuid)
RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_total integer;
BEGIN
  SELECT COALESCE(SUM(bt.worker_cost), 0) INTO v_total
  FROM public.buildings b
  JOIN public.building_types bt ON bt.key = b.building_type_key
  WHERE b.player_id = p_uid AND b.status = 'active'
    AND bt.category IN ('extractor','food_extractor','booster','processor','tax','service','police')
    AND public.has_road_access(p_uid, b.x, b.y);
  RETURN v_total;
END;
$$;
GRANT EXECUTE ON FUNCTION public._pp_workers_needed(uuid) TO authenticated;

-- _pp_staff_buildings: same set of categories.
CREATE OR REPLACE FUNCTION public._pp_staff_buildings(
  p_uid uuid,
  p_supply integer,
  OUT staffed_ids uuid[],
  OUT workers_needed integer,
  OUT unstaffed_count integer
) RETURNS record
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_remaining integer := p_supply;
  v_b record;
BEGIN
  staffed_ids := ARRAY[]::uuid[];
  workers_needed := 0;
  unstaffed_count := 0;
  FOR v_b IN
    SELECT b.id, bt.worker_cost
    FROM public.buildings b
    JOIN public.building_types bt ON bt.key = b.building_type_key
    WHERE b.player_id = p_uid AND b.status = 'active'
      AND bt.category IN ('extractor','food_extractor','booster','processor','tax','service','police')
      AND public.has_road_access(p_uid, b.x, b.y)
    ORDER BY b.staffing_priority DESC, b.created_at ASC
  LOOP
    workers_needed := workers_needed + v_b.worker_cost;
    IF v_remaining >= v_b.worker_cost THEN
      staffed_ids := staffed_ids || v_b.id;
      v_remaining := v_remaining - v_b.worker_cost;
    ELSE
      unstaffed_count := unstaffed_count + 1;
    END IF;
  END LOOP;
END;
$$;
GRANT EXECUTE ON FUNCTION public._pp_staff_buildings(uuid, integer) TO authenticated;

-- ── 4. compute_crime: stable-per-tick crime score ───────
CREATE OR REPLACE FUNCTION public.compute_crime(p_uid uuid)
RETURNS numeric
LANGUAGE plpgsql STABLE SECURITY DEFINER AS $$
DECLARE
  v_population numeric;
  v_uncovered integer;
  v_taverns integer;
  v_score numeric;
BEGIN
  SELECT population INTO v_population FROM public.player_profiles WHERE id = p_uid;
  IF v_population IS NULL THEN v_population := 5; END IF;

  -- Uncovered active houses: housing tiles NOT within Manhattan
  -- coverage_radius of any active staffed police building.
  SELECT COUNT(*) INTO v_uncovered
  FROM public.buildings h
  JOIN public.building_types bt ON bt.key = h.building_type_key
  WHERE h.player_id = p_uid AND h.status = 'active' AND bt.category = 'housing'
    AND NOT EXISTS (
      SELECT 1 FROM public.buildings p
      JOIN public.building_types pt ON pt.key = p.building_type_key
      WHERE p.player_id = p_uid AND p.status = 'active' AND pt.category = 'police'
        AND ABS(p.x - h.x) + ABS(p.y - h.y) <= pt.coverage_radius
        AND public.has_road_access(p_uid, p.x, p.y)
    );

  SELECT COUNT(*) INTO v_taverns
  FROM public.buildings b
  WHERE b.player_id = p_uid AND b.status = 'active' AND b.building_type_key = 'tavern';

  v_score := 10
    + 4 * v_uncovered
    + LEAST(20, FLOOR(v_population / 10))
    + 1 * v_taverns;

  RETURN LEAST(100, GREATEST(0, v_score));
END;
$$;
GRANT EXECUTE ON FUNCTION public.compute_crime(uuid) TO authenticated;

-- ── 5. _pp_update_crime: persist on player_profiles ─────
CREATE OR REPLACE FUNCTION public._pp_update_crime(p_uid uuid)
RETURNS numeric
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_crime numeric;
BEGIN
  v_crime := public.compute_crime(p_uid);
  UPDATE public.player_profiles SET crime = v_crime WHERE id = p_uid;
  RETURN v_crime;
END;
$$;
GRANT EXECUTE ON FUNCTION public._pp_update_crime(uuid) TO authenticated;

-- ── 6. _pp_run_upkeep: deduct per-minute upkeep ─────────
-- Aggregate per-tick (one row per tick, not per-building) so the cash
-- ledger stays readable.
CREATE OR REPLACE FUNCTION public._pp_run_upkeep(p_uid uuid, p_staffed_ids uuid[])
RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_now timestamptz := now();
  v_total integer := 0;
  v_b record;
  v_elapsed numeric;
  v_amt numeric;
BEGIN
  FOR v_b IN
    SELECT b.id, b.last_processed_at, bt.upkeep_per_minute
    FROM public.buildings b
    JOIN public.building_types bt ON bt.key = b.building_type_key
    WHERE b.player_id = p_uid AND b.status = 'active'
      AND bt.upkeep_per_minute > 0
      AND b.id = ANY(p_staffed_ids)
    FOR UPDATE OF b
  LOOP
    v_elapsed := EXTRACT(EPOCH FROM (v_now - v_b.last_processed_at));
    v_amt := FLOOR((v_elapsed / 60.0) * v_b.upkeep_per_minute);
    IF v_amt > 0 THEN
      UPDATE public.player_profiles SET money = money - v_amt::integer WHERE id = p_uid;
      v_total := v_total + v_amt::integer;
    END IF;
    UPDATE public.buildings SET last_processed_at = v_now WHERE id = v_b.id;
  END LOOP;

  IF v_total > 0 THEN
    INSERT INTO public.cash_transactions (player_id, source, amount, context)
    VALUES (p_uid, 'upkeep', -v_total, NULL);
  END IF;

  RETURN v_total;
END;
$$;
GRANT EXECUTE ON FUNCTION public._pp_run_upkeep(uuid, uuid[]) TO authenticated;

-- ── 7. compute_happiness: subtract floor(crime/5) ──────
-- Re-fetched + edited from the live function. New term: −FLOOR(crime/5).
CREATE OR REPLACE FUNCTION public.compute_happiness(p_uid uuid)
RETURNS json
LANGUAGE plpgsql STABLE SECURITY DEFINER AS $$
DECLARE
  v_base constant numeric := 30;
  v_services integer := 0;
  v_avg_tier numeric := 0;
  v_food_variety integer := 0;
  v_tax_count integer := 0;
  v_workers_needed integer := 0;
  v_worker_capacity integer := 0;
  v_staffing_ratio numeric := 1.0;
  v_crime numeric := 0;
  v_crime_penalty numeric := 0;
  v_score numeric;
BEGIN
  IF EXISTS (
    SELECT 1 FROM public.buildings b
    JOIN public.building_types bt ON bt.key = b.building_type_key
    WHERE b.player_id = p_uid AND b.status = 'active' AND bt.key = 'well'
      AND public.has_road_access(p_uid, b.x, b.y)
  ) THEN v_services := v_services + 1; END IF;

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

  SELECT COALESCE(AVG(b.housing_tier), 0) INTO v_avg_tier
  FROM public.buildings b
  JOIN public.building_types bt ON bt.key = b.building_type_key
  WHERE b.player_id = p_uid AND b.status = 'active' AND bt.category = 'housing';

  SELECT COUNT(*) INTO v_food_variety
  FROM public.inventories i
  JOIN public.resources r ON r.key = i.resource_key
  WHERE i.player_id = p_uid AND r.is_food AND i.quantity > 0;

  SELECT COUNT(*) INTO v_tax_count
  FROM public.buildings b
  JOIN public.building_types bt ON bt.key = b.building_type_key
  WHERE b.player_id = p_uid AND b.status = 'active' AND bt.category = 'tax';

  SELECT worker_capacity INTO v_worker_capacity
  FROM public.player_profiles WHERE id = p_uid;
  v_workers_needed := public._pp_workers_needed(p_uid);
  IF v_workers_needed > 0 THEN
    v_staffing_ratio := LEAST(1.0, v_worker_capacity::numeric / v_workers_needed::numeric);
  END IF;

  -- Crime penalty: high crime steals happiness, which (asymmetric model)
  -- pushes citizens to emigrate.
  v_crime := public.compute_crime(p_uid);
  v_crime_penalty := FLOOR(v_crime / 5);

  v_score :=
    v_base
    + 3 * v_services
    + 2 * v_avg_tier
    + LEAST(15, v_food_variety * 2)
    - 3 * v_tax_count
    + 20 * v_staffing_ratio
    - v_crime_penalty;

  RETURN json_build_object(
    'happiness', LEAST(100, GREATEST(0, v_score)),
    'breakdown', json_build_object(
      'base', v_base,
      'services', v_services,
      'avg_tier', v_avg_tier,
      'food_variety', v_food_variety,
      'tax_count', v_tax_count,
      'worker_capacity', v_worker_capacity,
      'workers_needed', v_workers_needed,
      'staffing_ratio', v_staffing_ratio,
      'crime', v_crime,
      'crime_penalty', v_crime_penalty
    )
  );
END;
$$;
GRANT EXECUTE ON FUNCTION public.compute_happiness(uuid) TO authenticated;

-- ── 8. process_production orchestrator: wire crime + upkeep ──
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
    'crime', v_crime
  );
END;
$$;
GRANT EXECUTE ON FUNCTION public.process_production() TO authenticated;
