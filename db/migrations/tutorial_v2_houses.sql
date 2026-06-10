-- ── Tutorial v2: build houses up front, instant fill ──
-- Playtest feedback: a starting population of 15 doesn't feel earned —
-- the new player wonders where they came from. Better flow:
--
--   Step 0: Build 4 Houses (each is auto-set to tier-1 Hut, 6 workers,
--           and the population snaps up to housing supply immediately).
--   Step 1: Build a Well
--   Step 2: Build a Food Producer
--   Step 3: Build a Resource Extractor
--   Step 4: Done — trade unlocks.
--
-- Two server-side mechanics support this:
--
--   (a) AFTER INSERT trigger on buildings advances tutorial_step. For
--       housing during step 0, it also forces tier=1 (skipping Shanty)
--       and snaps population to v_floor + housing_supply so the
--       citizens are actually present when the house finishes.
--
--   (b) _pp_evolve_housing skips devolve checks while tutorial_step < 4.
--       Without this, the tier-1 huts would devolve back to tier 0 on
--       the next tick because the well doesn't exist until step 1 (or
--       isn't covering the houses if the player placed it far away).
--       After tutorial, normal devolve rules resume.
--
-- Existing players are bumped to tutorial_step = 4 (the new "done"
-- value) so they're not affected.

UPDATE public.player_profiles
   SET tutorial_step = 4
 WHERE tutorial_step >= 3;

-- New trigger function: bigger sequence + housing tier auto-bump.
CREATE OR REPLACE FUNCTION public._advance_tutorial()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_step integer;
  v_category text;
  v_house_count integer;
  v_supply integer;
BEGIN
  SELECT tutorial_step INTO v_step
  FROM public.player_profiles
  WHERE id = NEW.player_id;

  IF v_step IS NULL OR v_step >= 4 THEN
    RETURN NEW;
  END IF;

  SELECT category INTO v_category
  FROM public.building_types
  WHERE key = NEW.building_type_key;

  IF v_step = 0 AND v_category = 'housing' THEN
    -- Auto-bump tier 0 (Shanty) → tier 1 (Hut) for tutorial houses
    -- so each one provides 6 workers right away. _pp_evolve_housing
    -- below is taught to skip devolve while step < 4 so this sticks
    -- even before the well is placed in step 1.
    UPDATE public.buildings
       SET housing_tier = 1, last_processed_at = now()
     WHERE id = NEW.id AND housing_tier = 0;

    -- Snap population to housing supply so the worker pool actually
    -- reflects the citizens this house just brought in. Without this,
    -- _pp_update_population would only ramp pop toward target via
    -- migration rate over the next several minutes, which defeats
    -- the "they fill immediately" UX goal.
    v_supply := public._pp_housing_supply(NEW.player_id);
    UPDATE public.player_profiles
       SET population = GREATEST(population, 15 + v_supply)
     WHERE id = NEW.player_id;

    -- Advance only when the player has 4+ houses — that's the worker
    -- math for staffing well (3) + food (10) + extractor (10) = 23.
    SELECT COUNT(*) INTO v_house_count
      FROM public.buildings b
      JOIN public.building_types bt ON bt.key = b.building_type_key
     WHERE b.player_id = NEW.player_id
       AND b.status = 'active'
       AND bt.category = 'housing';
    IF v_house_count >= 4 THEN
      UPDATE public.player_profiles
         SET tutorial_step = 1
       WHERE id = NEW.player_id;
    END IF;

  ELSIF v_step = 1 AND NEW.building_type_key = 'well' THEN
    UPDATE public.player_profiles
       SET tutorial_step = 2
     WHERE id = NEW.player_id;

  ELSIF v_step = 2 AND v_category = 'food_extractor' THEN
    UPDATE public.player_profiles
       SET tutorial_step = 3
     WHERE id = NEW.player_id;

  ELSIF v_step = 3 AND v_category = 'extractor' THEN
    UPDATE public.player_profiles
       SET tutorial_step = 4,
           trade_unlocked = true
     WHERE id = NEW.player_id;
  END IF;

  RETURN NEW;
END;
$$;

-- Devolve bypass during tutorial. The existing _pp_evolve_housing has
-- the devolve gate tucked inside the loop body; cleanest patch is to
-- replace the function with one that early-skips devolve when the
-- player is still in the tutorial.
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
  v_has_school boolean;
  v_has_temple boolean;
  v_has_bathhouse boolean;
  v_has_food boolean;
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
BEGIN
  v_skip_des := COALESCE(current_setting('city.skip_desirability_gate', true), 'false') = 'true';

  -- Tutorial bypass: while a player is still in the guided tutorial
  -- (step 0..3), houses are protected from devolution. The trigger
  -- force-sets new houses to tier 1 even before a well exists; the
  -- tier needs to stick until the player finishes the sequence.
  SELECT (tutorial_step < 4) INTO v_in_tutorial
  FROM public.player_profiles WHERE id = p_uid;
  v_in_tutorial := COALESCE(v_in_tutorial, false);

  SELECT EXISTS (SELECT 1 FROM public.inventories i JOIN public.resources r ON r.key = i.resource_key
                 WHERE i.player_id = p_uid AND r.is_food AND i.quantity > 0) INTO v_has_food;
  SELECT EXISTS (SELECT 1 FROM public.inventories i JOIN public.resources r ON r.key = i.resource_key
                 WHERE i.player_id = p_uid AND r.is_luxury_food AND i.quantity > 0) INTO v_has_luxury_food;
  SELECT EXISTS (SELECT 1 FROM public.inventories i JOIN public.resources r ON r.key = i.resource_key
                 WHERE i.player_id = p_uid AND r.is_industrial_luxury AND i.quantity > 0) INTO v_has_industrial_luxury;
  SELECT COUNT(*) INTO v_il_count FROM public.inventories i JOIN public.resources r ON r.key = i.resource_key
   WHERE i.player_id = p_uid AND r.is_industrial_luxury AND i.quantity > 0;
  SELECT COUNT(*) INTO v_il_total FROM public.resources WHERE is_industrial_luxury;
  v_has_all_industrial_luxuries := (v_il_total > 0 AND v_il_count >= v_il_total);

  FOR v_house IN
    SELECT b.id, b.x, b.y, b.housing_tier, b.last_processed_at
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
    v_has_school := EXISTS (SELECT 1 FROM public.buildings b2
      WHERE b2.player_id = p_uid AND b2.building_type_key = 'school'
        AND b2.id = ANY(p_operating_services)
        AND ABS(b2.x - v_house.x) + ABS(b2.y - v_house.y) <= 5);
    v_has_temple := EXISTS (SELECT 1 FROM public.buildings b2
      WHERE b2.player_id = p_uid AND b2.building_type_key = 'temple'
        AND b2.id = ANY(p_operating_services)
        AND ABS(b2.x - v_house.x) + ABS(b2.y - v_house.y) <= 6);
    v_has_bathhouse := EXISTS (SELECT 1 FROM public.buildings b2
      WHERE b2.player_id = p_uid AND b2.building_type_key = 'bathhouse'
        AND b2.id = ANY(p_operating_services)
        AND ABS(b2.x - v_house.x) + ABS(b2.y - v_house.y) <= 4);

    SELECT COALESCE(desirability, 50) INTO v_desirability
    FROM public.map_tiles
    WHERE x = v_house.x AND y = v_house.y AND owner_player_id = p_uid;

    v_should_upgrade := v_next_tier IS NOT NULL
      AND v_elapsed >= COALESCE(v_cur_tier.upgrade_secs, 60)
      AND (NOT v_next_tier.needs_road OR v_has_road)
      AND (NOT v_next_tier.needs_well OR v_has_well)
      AND (NOT v_next_tier.needs_food OR v_has_food)
      AND (NOT v_next_tier.needs_school OR v_has_school)
      AND (NOT v_next_tier.needs_temple OR v_has_temple)
      AND (NOT v_next_tier.needs_luxury_food OR v_has_luxury_food)
      AND (NOT v_next_tier.needs_industrial_luxury OR v_has_industrial_luxury)
      AND (NOT v_next_tier.needs_all_industrial_luxuries OR v_has_all_industrial_luxuries)
      AND (v_skip_des OR v_desirability >= COALESCE(v_next_tier.min_desirability, 0));

    -- Tutorial protects from devolve. Otherwise: prereqs missing OR
    -- desirability too low.
    v_should_devolve := NOT v_in_tutorial
      AND v_prev_tier IS NOT NULL
      AND ((v_cur_tier.needs_road AND NOT v_has_road)
           OR (v_cur_tier.needs_well AND NOT v_has_well)
           OR (v_cur_tier.needs_food AND NOT v_has_food)
           OR (v_cur_tier.needs_school AND NOT v_has_school)
           OR (v_cur_tier.needs_temple AND NOT v_has_temple)
           OR (v_cur_tier.needs_luxury_food AND NOT v_has_luxury_food)
           OR (v_cur_tier.needs_industrial_luxury AND NOT v_has_industrial_luxury)
           OR (v_cur_tier.needs_all_industrial_luxuries AND NOT v_has_all_industrial_luxuries)
           OR (NOT v_skip_des AND v_desirability < COALESCE(v_cur_tier.min_desirability, 0) - 30))
      AND NOT v_has_bathhouse
      AND v_elapsed >= COALESCE(v_cur_tier.devolve_secs, 30);

    IF v_should_upgrade THEN
      UPDATE public.buildings SET housing_tier = housing_tier + 1, last_processed_at = v_now
      WHERE id = v_house.id;
      v_events := v_events || jsonb_build_object(
        'building_id', v_house.id, 'event', 'upgrade',
        'from_tier', v_house.housing_tier, 'to_tier', v_house.housing_tier + 1
      )::json;
      UPDATE public.player_profiles
         SET highest_housing_tier_ever = GREATEST(highest_housing_tier_ever, v_house.housing_tier + 1)
       WHERE id = p_uid;
    ELSIF v_should_devolve THEN
      UPDATE public.buildings SET housing_tier = housing_tier - 1, last_processed_at = v_now
      WHERE id = v_house.id;
      v_events := v_events || jsonb_build_object(
        'building_id', v_house.id, 'event', 'devolve',
        'from_tier', v_house.housing_tier, 'to_tier', v_house.housing_tier - 1
      )::json;
    END IF;
  END LOOP;

  RETURN v_events;
END;
$function$;
