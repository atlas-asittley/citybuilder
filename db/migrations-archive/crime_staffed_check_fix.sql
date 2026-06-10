-- compute_crime exploit fix: police buildings need to be ACTUALLY staffed
-- (got workers assigned in the last process_production tick) to count as
-- providing coverage. The original implementation used has_road_access as
-- a proxy, which let players build many police without workers + skip the
-- upkeep (charged only when staffed) for free crime coverage.
--
-- Fix: persist is_staffed on `buildings`, refreshed each tick by
-- _pp_staff_buildings; compute_crime queries it.

-- ── 1. Schema: is_staffed flag ──────────────────────────
ALTER TABLE public.buildings
  ADD COLUMN IF NOT EXISTS is_staffed boolean NOT NULL DEFAULT false;

-- ── 2. _pp_staff_buildings: refresh is_staffed each tick ─
-- Resets all worker-pool buildings to false at the start, then flips
-- successful entries to true. Buildings that fall outside the worker
-- pool keep is_staffed = false naturally.
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

  -- Reset is_staffed for ALL of this player's worker-pool candidates
  -- (whether or not they get workers this tick).
  UPDATE public.buildings b
  SET is_staffed = false
  FROM public.building_types bt
  WHERE bt.key = b.building_type_key
    AND b.player_id = p_uid AND b.status = 'active'
    AND bt.category IN ('extractor','food_extractor','booster','processor','tax','service','police');

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
      UPDATE public.buildings SET is_staffed = true WHERE id = v_b.id;
    ELSE
      unstaffed_count := unstaffed_count + 1;
    END IF;
  END LOOP;
END;
$$;
GRANT EXECUTE ON FUNCTION public._pp_staff_buildings(uuid, integer) TO authenticated;

-- ── 3. compute_crime: check is_staffed instead of road access ──
-- Same shape as before, just swaps the "covered" predicate.
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

  SELECT COUNT(*) INTO v_uncovered
  FROM public.buildings h
  JOIN public.building_types bt ON bt.key = h.building_type_key
  WHERE h.player_id = p_uid AND h.status = 'active' AND bt.category = 'housing'
    AND NOT EXISTS (
      SELECT 1 FROM public.buildings p
      JOIN public.building_types pt ON pt.key = p.building_type_key
      WHERE p.player_id = p_uid AND p.status = 'active' AND pt.category = 'police'
        AND p.is_staffed
        AND ABS(p.x - h.x) + ABS(p.y - h.y) <= pt.coverage_radius
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
