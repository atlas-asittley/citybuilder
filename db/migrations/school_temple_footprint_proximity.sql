-- ─────────────────────────────────────────────────────────────────────
-- School / temple proximity → footprint-perimeter Chebyshev (2026-06-02).
--
-- Atlas: both school and temple are 2×2 buildings. The previous check
-- used anchor-to-anchor Chebyshev (top-left cell to house). A house
-- that is 5 tiles from the school's RIGHT edge is only 6 from the
-- anchor — so the upgrade gate refuses even though the house is
-- visually well within range.
--
-- Bug filed by Jill (2026-06-02):
--   "The school is within 5 spaces of the homes, not 6 so should
--   allow them to upgrade."
-- She was right: school anchor at (-9,25), 2×2 footprint → nearest
-- cell (-8,25). Houses at (-3,26)/(-3,25): footprint Chebyshev = 5,
-- anchor Chebyshev = 6 → old gate refused.
--
-- Fix: replace anchor-to-anchor with footprint-perimeter Chebyshev:
--
--   dx = GREATEST(b2.x - v_house.x,   v_house.x - (b2.x + 1), 0)
--   dy = GREATEST(b2.y - v_house.y,   v_house.y - (b2.y + 1), 0)
--   dist = GREATEST(dx, dy)
--
-- This is the minimum Chebyshev distance from any cell in the 2×2
-- footprint to the house. For 1×1 buildings it reduces to plain
-- Chebyshev (no change to bathhouse/well/road checks).
-- ─────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public._pp_evolve_housing(p_uid uuid, p_operating_services uuid[])
RETURNS json[]
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
DECLARE
  v_now timestamptz := now();
  v_events json[] := ARRAY[]::json[];
  v_house record;
  v_cur_tier record;
  v_next_tier record;
  v_prev_tier record;
  v_elapsed numeric;
  v_has_road boolean;
  v_has_well boolean;
  v_has_any_well boolean;
  v_well_for_next boolean;
  v_well_for_cur boolean;
  v_has_school boolean;
  v_has_temple boolean;
  v_has_bathhouse boolean;
  v_has_food_global boolean;
  v_has_luxury_food boolean;
  v_has_industrial_luxury boolean;
  v_has_all_industrial_luxuries boolean;
  v_il_count integer;
  v_il_total integer;
  v_should_upgrade boolean;
  v_should_devolve boolean;
  v_desirability integer;
  v_skip_des boolean;
  v_in_tutorial boolean;
  v_lifestyle_for_cur_ok boolean;
  v_lifestyle_for_next_ok boolean;
  v_house_food_ok boolean;
  v_newly_eligible integer := 0;
  v_lost_eligibility integer := 0;
  v_auto_upgraded integer := 0;
  v_devolve_reason text;
  v_missing_lifestyle text;
BEGIN
  v_skip_des := COALESCE(current_setting('city.skip_desirability_gate', true), 'false') = 'true';

  SELECT (tutorial_step < 4) INTO v_in_tutorial
  FROM public.player_profiles WHERE id = p_uid;
  v_in_tutorial := COALESCE(v_in_tutorial, false);

  v_has_any_well := public.has_any_well(p_uid);

  SELECT EXISTS (SELECT 1 FROM public.inventories i JOIN public.resources r ON r.key = i.resource_key
                 WHERE i.player_id = p_uid AND r.is_food AND i.quantity > 0) INTO v_has_food_global;
  SELECT EXISTS (SELECT 1 FROM public.inventories i JOIN public.resources r ON r.key = i.resource_key
                 WHERE i.player_id = p_uid AND r.is_luxury_food AND i.quantity > 0) INTO v_has_luxury_food;
  SELECT EXISTS (SELECT 1 FROM public.inventories i JOIN public.resources r ON r.key = i.resource_key
                 WHERE i.player_id = p_uid AND r.is_industrial_luxury AND i.quantity > 0) INTO v_has_industrial_luxury;
  SELECT COUNT(*) INTO v_il_count FROM public.inventories i JOIN public.resources r ON r.key = i.resource_key
   WHERE i.player_id = p_uid AND r.is_industrial_luxury AND i.quantity > 0;
  SELECT COUNT(*) INTO v_il_total FROM public.resources WHERE is_industrial_luxury;
  v_has_all_industrial_luxuries := (v_il_total > 0 AND v_il_count >= v_il_total);

  FOR v_house IN
    SELECT b.id, b.x, b.y, b.housing_tier, b.last_processed_at, b.evolution_eligible_at,
           b.auto_upgrade
    FROM public.buildings b
    JOIN public.building_types bt ON bt.key = b.building_type_key
    WHERE b.player_id = p_uid AND b.status = 'active' AND bt.category = 'housing'
    FOR UPDATE OF b
  LOOP
    SELECT * INTO v_cur_tier  FROM public.housing_tier_config WHERE tier = v_house.housing_tier;
    SELECT * INTO v_next_tier FROM public.housing_tier_config WHERE tier = v_house.housing_tier + 1;
    SELECT * INTO v_prev_tier FROM public.housing_tier_config WHERE tier = v_house.housing_tier - 1;
    v_elapsed := EXTRACT(EPOCH FROM (v_now - v_house.last_processed_at));
    v_has_road := public.has_road_access(p_uid, v_house.x, v_house.y);
    v_has_well := public.has_well_access(p_uid, v_house.x, v_house.y);
    -- Footprint-perimeter Chebyshev: school and temple are 2×2 buildings.
    -- Using anchor-to-anchor Chebyshev misses houses on the right/bottom
    -- side of the building's footprint (they appear within range visually
    -- but fail the anchor check by 1). The formula below finds the closest
    -- cell in the 2×2 footprint, matching player intuition.
    v_has_school := EXISTS (SELECT 1 FROM public.buildings b2
      WHERE b2.player_id = p_uid AND b2.building_type_key = 'school'
        AND b2.id = ANY(p_operating_services)
        AND GREATEST(
              GREATEST(b2.x - v_house.x, v_house.x - (b2.x + 1), 0),
              GREATEST(b2.y - v_house.y, v_house.y - (b2.y + 1), 0)
            ) <= 5);
    v_has_temple := EXISTS (SELECT 1 FROM public.buildings b2
      WHERE b2.player_id = p_uid AND b2.building_type_key = 'temple'
        AND b2.id = ANY(p_operating_services)
        AND GREATEST(
              GREATEST(b2.x - v_house.x, v_house.x - (b2.x + 1), 0),
              GREATEST(b2.y - v_house.y, v_house.y - (b2.y + 1), 0)
            ) <= 6);
    v_has_bathhouse := EXISTS (SELECT 1 FROM public.buildings b2
      WHERE b2.player_id = p_uid AND b2.building_type_key = 'bathhouse'
        AND b2.id = ANY(p_operating_services)
        AND GREATEST(ABS(b2.x - v_house.x), ABS(b2.y - v_house.y)) <= 4);

    SELECT COALESCE(desirability, 50) INTO v_desirability
    FROM public.map_tiles
    WHERE x = v_house.x AND y = v_house.y AND owner_player_id = p_uid;

    v_well_for_next := CASE
      WHEN v_next_tier IS NULL THEN false
      WHEN v_next_tier.tier = 1 THEN v_has_any_well
      ELSE v_has_well
    END;
    v_well_for_cur := CASE
      WHEN v_cur_tier.tier = 1 THEN v_has_any_well
      ELSE v_has_well
    END;

    SELECT COALESCE(brb.quantity, 0) > 0 INTO v_house_food_ok
    FROM public.building_resource_buffers brb
    WHERE brb.building_id = v_house.id AND brb.resource_key = 'food';
    IF NOT FOUND THEN v_house_food_ok := true; END IF;

    SELECT hld.resource_key INTO v_missing_lifestyle
    FROM public.housing_lifestyle_demands hld
    WHERE hld.tier = v_house.housing_tier
      AND COALESCE(
        (SELECT brb.quantity FROM public.building_resource_buffers brb
         WHERE brb.building_id = v_house.id AND brb.resource_key = hld.resource_key),
        0
      ) <= 0
    ORDER BY hld.resource_key
    LIMIT 1;
    v_lifestyle_for_cur_ok := v_missing_lifestyle IS NULL;

    IF v_next_tier IS NOT NULL THEN
      SELECT NOT EXISTS (
        SELECT 1 FROM public.housing_lifestyle_demands hld
        WHERE hld.tier = v_next_tier.tier
          AND NOT EXISTS (
            SELECT 1 FROM public.inventories i
            WHERE i.player_id = p_uid
              AND i.quantity > 0
              AND (
                i.resource_key = hld.resource_key
                OR i.resource_key IN (
                  SELECT ls.substitute_key FROM public.lifestyle_substitutes ls
                  WHERE ls.primary_key = hld.resource_key
                )
              )
          )
      ) INTO v_lifestyle_for_next_ok;
    ELSE
      v_lifestyle_for_next_ok := false;
    END IF;

    v_should_upgrade := v_next_tier IS NOT NULL
      AND (NOT v_next_tier.needs_road OR v_has_road)
      AND (NOT v_next_tier.needs_well OR v_well_for_next)
      AND (NOT v_next_tier.needs_food OR v_has_food_global)
      AND (NOT v_next_tier.needs_school OR v_has_school)
      AND (NOT v_next_tier.needs_temple OR v_has_temple)
      AND (NOT v_next_tier.needs_luxury_food OR v_has_luxury_food)
      AND (NOT v_next_tier.needs_industrial_luxury OR v_has_industrial_luxury)
      AND (NOT v_next_tier.needs_all_industrial_luxuries OR v_has_all_industrial_luxuries)
      AND v_lifestyle_for_next_ok
      AND (v_skip_des OR v_desirability >= COALESCE(v_next_tier.min_desirability, 0));

    v_should_devolve := NOT v_in_tutorial
      AND v_prev_tier IS NOT NULL
      AND ((v_cur_tier.needs_road AND NOT v_has_road)
           OR (v_cur_tier.needs_well AND NOT v_well_for_cur)
           OR (v_cur_tier.needs_food AND NOT v_house_food_ok)
           OR (v_cur_tier.needs_school AND NOT v_has_school)
           OR (v_cur_tier.needs_temple AND NOT v_has_temple)
           OR (v_cur_tier.needs_luxury_food AND NOT v_has_luxury_food)
           OR (v_cur_tier.needs_industrial_luxury AND NOT v_has_industrial_luxury)
           OR (v_cur_tier.needs_all_industrial_luxuries AND NOT v_has_all_industrial_luxuries)
           OR NOT v_lifestyle_for_cur_ok
           OR (NOT v_skip_des AND v_desirability < COALESCE(v_cur_tier.min_desirability, 0) - 30))
      AND NOT v_has_bathhouse
      AND v_elapsed >= COALESCE(v_cur_tier.devolve_secs, 30);

    IF v_should_upgrade THEN
      IF v_house.auto_upgrade THEN
        UPDATE public.buildings
           SET housing_tier = housing_tier + 1,
               last_processed_at = v_now,
               evolution_eligible_at = NULL
         WHERE id = v_house.id;
        UPDATE public.player_profiles
           SET highest_housing_tier_ever = GREATEST(highest_housing_tier_ever, v_house.housing_tier + 1)
         WHERE id = p_uid;
        v_auto_upgraded := v_auto_upgraded + 1;
        v_events := v_events || jsonb_build_object(
          'building_id', v_house.id, 'event', 'auto_upgrade',
          'from_tier', v_house.housing_tier, 'to_tier', v_house.housing_tier + 1
        )::json;
      ELSE
        IF v_house.evolution_eligible_at IS NULL THEN
          UPDATE public.buildings SET evolution_eligible_at = v_now WHERE id = v_house.id;
          v_newly_eligible := v_newly_eligible + 1;
        END IF;
      END IF;
    ELSE
      IF v_house.evolution_eligible_at IS NOT NULL THEN
        UPDATE public.buildings SET evolution_eligible_at = NULL WHERE id = v_house.id;
        v_lost_eligibility := v_lost_eligibility + 1;
      END IF;
    END IF;

    IF v_should_devolve THEN
      v_devolve_reason := CASE
        WHEN v_cur_tier.needs_road AND NOT v_has_road THEN 'road'
        WHEN v_cur_tier.needs_well AND NOT v_well_for_cur THEN 'well'
        WHEN v_cur_tier.needs_food AND NOT v_house_food_ok THEN 'food'
        WHEN v_cur_tier.needs_school AND NOT v_has_school THEN 'school'
        WHEN v_cur_tier.needs_temple AND NOT v_has_temple THEN 'temple'
        WHEN v_cur_tier.needs_luxury_food AND NOT v_has_luxury_food THEN 'luxury_food'
        WHEN v_cur_tier.needs_industrial_luxury AND NOT v_has_industrial_luxury THEN 'industrial_luxury'
        WHEN v_cur_tier.needs_all_industrial_luxuries AND NOT v_has_all_industrial_luxuries THEN 'all_industrial_luxuries'
        WHEN NOT v_lifestyle_for_cur_ok THEN 'lifestyle:' || COALESCE(v_missing_lifestyle, 'unknown')
        WHEN NOT v_skip_des AND v_desirability < COALESCE(v_cur_tier.min_desirability, 0) - 30 THEN 'desirability'
        ELSE 'unknown'
      END;

      UPDATE public.buildings
         SET housing_tier = housing_tier - 1,
             last_processed_at = v_now,
             evolution_eligible_at = NULL,
             last_devolve_at = v_now,
             last_devolve_reason = v_devolve_reason,
             last_devolve_from_tier = v_house.housing_tier
       WHERE id = v_house.id;
      v_events := v_events || jsonb_build_object(
        'building_id', v_house.id, 'event', 'devolve',
        'from_tier', v_house.housing_tier, 'to_tier', v_house.housing_tier - 1,
        'reason', v_devolve_reason
      )::json;
    END IF;
  END LOOP;

  IF v_newly_eligible > 0 THEN
    v_events := v_events || jsonb_build_object(
      'event', 'housing_ready_to_upgrade', 'count', v_newly_eligible
    )::json;
  END IF;
  IF v_lost_eligibility > 0 THEN
    v_events := v_events || jsonb_build_object(
      'event', 'housing_lost_eligibility', 'count', v_lost_eligibility
    )::json;
  END IF;

  RETURN v_events;
END;
$function$;
