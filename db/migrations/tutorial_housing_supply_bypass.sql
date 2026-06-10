-- ── Tutorial: count housing supply without the well prereq ──
-- The previous tutorial-pop migration intended each starter house to
-- add 6 workers immediately. It didn't, because tier 1 Mud Hut has
-- needs_well = true and the player only builds the well in step 1 —
-- so during step 0 _pp_housing_supply returned 0 and the trigger's
-- "pop = housing_supply" set pop to 0 every time.
--
-- Fix: _pp_housing_supply skips the needs_well check while a player
-- is in the tutorial (step < 4). After the tutorial, normal rules
-- apply. By then the player has built a well anyway (tutorial step 1),
-- and they'd typically place it within the 4-tile coverage radius
-- of their houses, so the post-tutorial supply value remains stable.

CREATE OR REPLACE FUNCTION public._pp_housing_supply(p_uid uuid)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
DECLARE
  v_housing integer := 0;
  v_in_tutorial boolean;
BEGIN
  SELECT (tutorial_step < 4) INTO v_in_tutorial
  FROM public.player_profiles WHERE id = p_uid;
  v_in_tutorial := COALESCE(v_in_tutorial, false);

  SELECT COALESCE(SUM(htc.workers), 0) INTO v_housing
  FROM public.buildings b
  JOIN public.building_types bt ON bt.key = b.building_type_key
  JOIN public.housing_tier_config htc ON htc.tier = b.housing_tier
  WHERE b.player_id = p_uid AND b.status = 'active' AND bt.category = 'housing'
    AND (NOT htc.needs_road OR public.has_road_access(p_uid, b.x, b.y))
    -- Bypass the well requirement during tutorial. After tutorial
    -- step 4, the regular check is back: needs_well demands the
    -- house be within 4 tiles of an active well.
    AND (v_in_tutorial OR NOT htc.needs_well OR public.has_well_access(p_uid, b.x, b.y));
  RETURN v_housing;
END;
$function$;
