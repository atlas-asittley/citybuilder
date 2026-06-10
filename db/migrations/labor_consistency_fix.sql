-- ─────────────────────────────────────────────────────────────────────
-- Labor model consistency (2026-05-09):
--
-- Bug: _pp_workers_needed sums worker_cost across categories
--      'extractor','food_extractor','booster','processor','tax','service','police',
--      'transport_hub','transport_connector'
--      — INCLUDING transport. But _pp_staff_buildings's loop only iterates
--      'extractor','food_extractor','booster','processor','tax','service','police'
--      — EXCLUDING transport. Transport buildings (worker_cost 5-10 each)
--      get counted as needing workers but never actually staffed, so a
--      city with an airport+seaport+train+truck reads "labor shortage"
--      forever even when every actual production building is fully
--      staffed. Atlas's Lyrandel had 33 phantom worker need from
--      transport.
--
-- Fix: transport doesn't gate on staffing. Their unlocks work via
-- _player_has_transport_access which only checks status='active' and
-- road access, never is_staffed. Remove transport from
-- _pp_workers_needed so the counts match reality.
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
                        'tax','service','police')
    AND public.has_road_access(p_uid, b.x, b.y);
  RETURN v_total;
END;
$function$;
