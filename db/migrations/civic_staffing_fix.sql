-- ─────────────────────────────────────────────────────────────────────
-- Civic-category buildings now get staffed (2026-05-22).
--
-- Jill bug 66b9a6cb: "I built a monument and I have workers available,
-- but it remains unstaffed." Same affects Public Garden and Marketplace
-- — all `civic` category buildings shipped 2026-05-22.
--
-- Root cause: _pp_staff_buildings's category list never included
-- 'civic'. The function's UPDATE-and-reset clears is_staffed only for
-- listed categories, and the worker-allocation loop only iterates
-- listed categories. So civic buildings never got considered, never
-- got is_staffed=true, and their effects (desirability_bonus,
-- migration_bonus, trade_sell_bonus_pct, crime_emit) never activated.
--
-- Fix: add 'civic' to both spots. Priority 2 (same tier as service +
-- police) since civic amenities are quality-of-life city investments
-- — they should staff before extractors/processors when workers are
-- tight, alongside services + police.
-- ─────────────────────────────────────────────────────────────────────


CREATE OR REPLACE FUNCTION public._pp_workers_needed(p_uid uuid)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
DECLARE
  v_total integer;
BEGIN
  SELECT COALESCE(SUM(bt.worker_cost), 0) INTO v_total
  FROM public.buildings b
  JOIN public.building_types bt ON bt.key = b.building_type_key
  WHERE b.player_id = p_uid AND b.status = 'active'
    AND bt.category IN ('extractor','food_extractor','booster','processor',
                        'tax','service','police','civic')
    AND public.has_road_access(p_uid, b.x, b.y);
  RETURN v_total;
END;
$function$;


CREATE OR REPLACE FUNCTION public._pp_staff_buildings(
  p_uid uuid, p_supply integer,
  OUT staffed_ids uuid[], OUT workers_needed integer, OUT unstaffed_count integer
)
RETURNS record
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
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
    AND bt.category IN ('extractor','food_extractor','booster','processor','tax','service','police','civic');

  FOR v_b IN
    SELECT b.id, bt.worker_cost
    FROM public.buildings b
    JOIN public.building_types bt ON bt.key = b.building_type_key
    WHERE b.player_id = p_uid AND b.status = 'active'
      AND bt.category IN ('extractor','food_extractor','booster','processor','tax','service','police','civic')
      AND public.has_road_access(p_uid, b.x, b.y)
    ORDER BY
      CASE bt.category
        WHEN 'service' THEN 2
        WHEN 'police' THEN 2
        WHEN 'civic' THEN 2
        ELSE 1
      END DESC,
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
$function$;
