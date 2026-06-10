-- ─────────────────────────────────────────────────────────────────────
-- Desirability service coverage → Chebyshev (2026-05-20).
--
-- Follow-up to service_proximity_chebyshev.sql (same day). The housing
-- upgrade gates and well_access function were switched to Chebyshev to
-- match how players see "within N tiles" on the map, but the
-- desirability calc that FEEDS the housing gate was left on Manhattan.
--
-- Concretely: Jill's tier-3 townhouse at (-14, 51) sat at desirability
-- 53 (Villa needs 60). Six staffed services were Chebyshev=4 from the
-- tile, but only two were Manhattan-in-range, so the formula only
-- credited 8 of the 28 desirability points the tile actually deserved
-- under the new coverage rules. Switching to Chebyshev raises it to
-- ~73, which makes the tile qualify for both Villa AND Manor Estate.
--
-- This brings the desirability formula into agreement with the housing
-- gate and the (well_access) road-gating. Pollution penalty and the
-- city-wide base term are unchanged.
-- ─────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public._pp_update_desirability(p_uid uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
DECLARE
  v_food_variety integer;
  v_crime numeric;
  v_tax_count integer;
  v_city_base integer;
BEGIN
  -- District-wide terms (apply equally to every tile in this district)
  SELECT COUNT(DISTINCT i.resource_key) INTO v_food_variety
  FROM public.inventories i
  JOIN public.resources r ON r.key = i.resource_key
  WHERE i.player_id = p_uid AND r.is_food AND i.quantity > 0;

  SELECT COALESCE(crime, 0) INTO v_crime
  FROM public.player_profiles WHERE id = p_uid;

  SELECT COUNT(*) INTO v_tax_count
  FROM public.buildings b
  JOIN public.building_types bt ON bt.key = b.building_type_key
  WHERE b.player_id = p_uid AND b.status = 'active' AND bt.category = 'tax';

  v_city_base := 50
    + LEAST(10, v_food_variety * 2)
    - LEAST(20, GREATEST(0, FLOOR((v_crime - 30) / 10)::integer * 2))
    - LEAST(15, v_tax_count * 3);

  -- Per-tile: city_base + service coverage − pollution penalty.
  -- Service coverage uses Chebyshev (king's-move) distance to match the
  -- housing upgrade gate and the inspector's "within N tiles" text:
  -- well/school/temple/bathhouse cover an N-tile square around the
  -- staffed building (range 5 for school, 6 for temple, 4 for well /
  -- bathhouse / tavern).
  UPDATE public.map_tiles mt SET desirability = LEAST(100, GREATEST(0,
    v_city_base
    - LEAST(30, mt.pollution::integer)
    + COALESCE((
        SELECT SUM(CASE bt.key
          WHEN 'well'      THEN 5
          WHEN 'school'    THEN 5
          WHEN 'temple'    THEN 5
          WHEN 'bathhouse' THEN 5
          WHEN 'tavern'    THEN 3
          ELSE 0 END)
        FROM public.buildings b
        JOIN public.building_types bt ON bt.key = b.building_type_key
        WHERE b.player_id = p_uid AND b.status = 'active' AND b.is_staffed
          AND bt.category = 'service'
          AND GREATEST(ABS(b.x - mt.x), ABS(b.y - mt.y)) <=
              CASE bt.key
                WHEN 'well'      THEN 4
                WHEN 'school'    THEN 5
                WHEN 'temple'    THEN 6
                WHEN 'bathhouse' THEN 4
                WHEN 'tavern'    THEN 4
                ELSE 0 END
      ), 0)
  )) WHERE mt.owner_player_id = p_uid;
END;
$function$;
