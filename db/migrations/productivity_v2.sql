-- ====================================================================
-- Productivity v2: education / tools / worker-buffer levers
-- ====================================================================
-- Layers 3 more inputs onto the v1 baseline (crime drag + tavern bonus):
--
--   Education coverage  — +0.03 per 10% of active housing within 5 tiles
--                         of a staffed school. Caps at +0.10 (i.e. kicks
--                         in fully at 40% coverage and stops there).
--   Tools stockpile     — +0.10 if tools >= floor(population) * 0.5
--                         +0.05 if tools >= floor(population) * 0.2
--                         else 0. Tools are NOT consumed in v2 — making
--                         them a hard maintenance drain is a separate
--                         design call (Atlas hasn't signed off yet).
--   Worker buffer       — -0.05 if workers_used >= worker_capacity (no
--                         idle workers; everyone is tapped).
--
-- Net swing now: -0.15 (crime cap + worker buffer) to +0.25 (tavern + edu
-- cap + tools cap). Sum is capped to ±0.30 defensively, then applied as
-- 1.0 + sum, then clamped a second time to [0.7, 1.3].
--
-- compute_productivity continues to run early in the tick — extractors,
-- food extractors, processors, and tax all use the freshly-computed
-- value. Education looks at `is_staffed` (set by _pp_staff_buildings,
-- which runs first); the school doesn't have to be input-fed for v2.
-- worker_capacity / workers_used are last-tick's values (updated at the
-- END of process_production), same lag as crime — fine for a slow city
-- metric.

CREATE OR REPLACE FUNCTION public._pp_compute_productivity(p_uid uuid)
RETURNS numeric
LANGUAGE plpgsql SECURITY DEFINER
AS $$
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
BEGIN
  SELECT COALESCE(crime, 0), COALESCE(population, 0),
         COALESCE(workers_used, 0), COALESCE(worker_capacity, 0)
  INTO v_crime, v_population, v_workers_used, v_worker_capacity
  FROM public.player_profiles WHERE id = p_uid;

  -- Crime drag: -0.005 per crime point above 50, max -0.10
  IF v_crime > 50 THEN
    v_score := v_score - LEAST(0.10, (v_crime - 50) * 0.005);
  END IF;

  -- Tavern bonus: +0.05 if any staffed tavern operating
  SELECT EXISTS (
    SELECT 1 FROM public.buildings b
    WHERE b.player_id = p_uid AND b.status = 'active' AND b.is_staffed
      AND b.building_type_key = 'tavern'
  ) INTO v_tavern;
  IF v_tavern THEN v_score := v_score + 0.05; END IF;

  -- Education coverage: +0.03 per 10% of active houses (tier ≥ 1) within
  -- 5 tiles of a staffed school. Caps at +0.10.
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
          AND ABS(s.x - h.x) + ABS(s.y - h.y) <= 5
      );
    v_coverage := v_covered_houses::numeric / v_total_houses::numeric;
    v_edu_bonus := LEAST(0.10, FLOOR(v_coverage * 10) * 0.03);
    v_score := v_score + v_edu_bonus;
  END IF;

  -- Tools stockpile vs. population
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

  -- Worker buffer: -0.05 when no idle workers. worker_capacity = 0 on a
  -- brand-new player (pre-staffing-tick), so guard on > 0 to avoid
  -- penalizing the first tick before the city has any capacity.
  IF v_worker_capacity > 0 AND v_workers_used >= v_worker_capacity THEN
    v_score := v_score - 0.05;
  END IF;

  v_score := GREATEST(-0.30, LEAST(0.30, v_score));
  v_productivity := GREATEST(0.7, LEAST(1.3, 1.0 + v_score));

  UPDATE public.player_profiles SET productivity = v_productivity WHERE id = p_uid;
  RETURN v_productivity;
END;
$$;
GRANT EXECUTE ON FUNCTION public._pp_compute_productivity(uuid) TO authenticated;
