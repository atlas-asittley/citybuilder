-- ====================================================================
-- Balance pass: police upkeep, staffing priority, civic costs
-- ====================================================================
-- Three fixes after analyzing live player data:
--
-- A. Police upkeep over-charges when a building goes unstaffed.
--    `_pp_run_upkeep` only charges staffed police, but it computes
--    elapsed since `last_processed_at` — and updates that timestamp
--    only when charging. So if a police building goes unstaffed for
--    an hour and is re-staffed, it pays a full hour of upkeep on its
--    next staffed tick. Real example: Jill paid $32,863 in upkeep over
--    24h on 3 police buildings that were 0-staffed in the snapshot.
--    Fix: always advance last_processed_at, charge only when staffed.
--
-- D. Staffing priority deprioritizes services + police. When workers
--    are scarce, production buildings get them first because all
--    categories share the same default `staffing_priority = 1`. But
--    services (well, school, temple — gates housing) and police (gates
--    crime → happiness → migration) are exactly what fixes a worker
--    shortage. Fix: tier services + police above other categories in
--    the ORDER BY, so they keep running and production idles first
--    when the squeeze hits.
--
-- E. Civic infrastructure can't pay for itself. 2 tax offices = 20/min
--    revenue; 1 constabulary = 25/min upkeep. New players don't see
--    the math and end up structurally cash-negative. Cut police upkeep
--    by ~20% so 2 tax offices comfortably cover 1 constabulary, with
--    headroom for a Watch House on top.

-- ── A: upkeep ───────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public._pp_run_upkeep(p_uid uuid, p_staffed_ids uuid[])
RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER
AS $$
DECLARE
  v_now timestamptz := now();
  v_total integer := 0;
  v_b record;
  v_elapsed numeric;
  v_amt numeric;
  v_is_staffed boolean;
BEGIN
  FOR v_b IN
    SELECT b.id, b.last_processed_at, bt.upkeep_per_minute
    FROM public.buildings b
    JOIN public.building_types bt ON bt.key = b.building_type_key
    WHERE b.player_id = p_uid AND b.status = 'active'
      AND bt.upkeep_per_minute > 0
    FOR UPDATE OF b
  LOOP
    v_is_staffed := v_b.id = ANY(p_staffed_ids);
    IF v_is_staffed THEN
      v_elapsed := EXTRACT(EPOCH FROM (v_now - v_b.last_processed_at));
      v_amt := FLOOR((v_elapsed / 60.0) * v_b.upkeep_per_minute);
      IF v_amt > 0 THEN
        UPDATE public.player_profiles SET money = money - v_amt::integer WHERE id = p_uid;
        v_total := v_total + v_amt::integer;
      END IF;
    END IF;
    -- Always advance the clock — don't bill unstaffed time on the
    -- next staffed tick.
    UPDATE public.buildings SET last_processed_at = v_now WHERE id = v_b.id;
  END LOOP;

  IF v_total > 0 THEN
    INSERT INTO public.cash_transactions (player_id, source, amount, context)
    VALUES (p_uid, 'upkeep', -v_total, NULL);
  END IF;

  RETURN v_total;
END;
$$;


-- ── D: staffing priority ─────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public._pp_staff_buildings(p_uid uuid, p_supply integer, OUT staffed_ids uuid[], OUT workers_needed integer, OUT unstaffed_count integer)
RETURNS record
LANGUAGE plpgsql SECURITY DEFINER
AS $$
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
    AND bt.category IN ('extractor','food_extractor','booster','processor','tax','service','police');

  -- Service + police get a category bonus so they're staffed BEFORE
  -- production buildings when workers are tight. Within each tier
  -- (civic vs production), the per-building staffing_priority and
  -- creation order break ties.
  FOR v_b IN
    SELECT b.id, bt.worker_cost
    FROM public.buildings b
    JOIN public.building_types bt ON bt.key = b.building_type_key
    WHERE b.player_id = p_uid AND b.status = 'active'
      AND bt.category IN ('extractor','food_extractor','booster','processor','tax','service','police')
      AND public.has_road_access(p_uid, b.x, b.y)
    ORDER BY
      CASE bt.category WHEN 'service' THEN 2 WHEN 'police' THEN 2 ELSE 1 END DESC,
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
$$;


-- ── E: police upkeep cuts ────────────────────────────────────────────
-- 2 tax offices (20/min revenue) now comfortably cover 1 constabulary
-- (20/min upkeep) with no headroom — and easily cover a Watch House
-- on top. Was: WH 5, PS 12, Const 25.

UPDATE public.building_types SET upkeep_per_minute = 4  WHERE key = 'watch_house';
UPDATE public.building_types SET upkeep_per_minute = 10 WHERE key = 'police_station';
UPDATE public.building_types SET upkeep_per_minute = 20 WHERE key = 'constabulary';
