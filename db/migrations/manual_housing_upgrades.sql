-- ─────────────────────────────────────────────────────────────────────
-- Manual housing upgrades (2026-05-08).
--
-- Atlas's call: housing tiers no longer auto-upgrade. When a house
-- meets its next-tier conditions, the server flags it eligible and
-- emits a summary event; the client toasts a notification; the
-- inspector shows an "Upgrade" button. The player chooses when to
-- step the house up.
--
-- Devolves stay automatic — losing tier is the failure state for
-- letting conditions slip and shouldn't require an opt-in.
--
-- Implementation:
--   1. _pp_evolve_housing rewritten — no auto-upgrade. Sets
--      buildings.evolution_eligible_at = now() on null→eligible
--      transition, clears it when conditions slip. Counts newly-
--      eligible houses; emits one summary event per tick if > 0.
--      Drops the `v_elapsed >= upgrade_secs` throttle on the upgrade
--      path — with manual upgrades, the player is the throttle.
--      Devolve still gates on devolve_secs (grace before tier loss).
--   2. New RPC upgrade_house(p_building_id) — caller-validated,
--      flag-validated, bumps tier + clears flag + bumps
--      highest_housing_tier_ever. The flag is refreshed every
--      process_production tick, so a click within ~30s of a
--      conditions-slip will be rejected (RPC checks current flag).
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
  v_lifestyle_for_cur_ok boolean;
  v_lifestyle_for_next_ok boolean;
  v_was_eligible_at timestamptz;
  v_newly_eligible integer := 0;
BEGIN
  v_skip_des := COALESCE(current_setting('city.skip_desirability_gate', true), 'false') = 'true';

  SELECT (tutorial_step < 4) INTO v_in_tutorial
  FROM public.player_profiles WHERE id = p_uid;
  v_in_tutorial := COALESCE(v_in_tutorial, false);

  v_has_any_well := public.has_any_well(p_uid);

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
    SELECT b.id, b.x, b.y, b.housing_tier, b.last_processed_at, b.evolution_eligible_at
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

    v_well_for_next := CASE
      WHEN v_next_tier IS NULL THEN false
      WHEN v_next_tier.tier = 1 THEN v_has_any_well
      ELSE v_has_well
    END;
    v_well_for_cur := CASE
      WHEN v_cur_tier.tier = 1 THEN v_has_any_well
      ELSE v_has_well
    END;

    SELECT NOT EXISTS (
      SELECT 1 FROM public.housing_lifestyle_demands hld
      WHERE hld.tier = v_house.housing_tier
        AND COALESCE((SELECT quantity FROM public.inventories i
                       WHERE i.player_id = p_uid AND i.resource_key = hld.resource_key), 0) <= 0
    ) INTO v_lifestyle_for_cur_ok;

    IF v_next_tier IS NOT NULL THEN
      SELECT NOT EXISTS (
        SELECT 1 FROM public.housing_lifestyle_demands hld
        WHERE hld.tier = v_next_tier.tier
          AND COALESCE((SELECT quantity FROM public.inventories i
                         WHERE i.player_id = p_uid AND i.resource_key = hld.resource_key), 0) <= 0
      ) INTO v_lifestyle_for_next_ok;
    ELSE
      v_lifestyle_for_next_ok := false;
    END IF;

    -- Eligibility for upgrade — same condition set as before, minus
    -- the v_elapsed throttle (manual upgrade = player is the throttle).
    v_should_upgrade := v_next_tier IS NOT NULL
      AND (NOT v_next_tier.needs_road OR v_has_road)
      AND (NOT v_next_tier.needs_well OR v_well_for_next)
      AND (NOT v_next_tier.needs_food OR v_has_food)
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
           OR (v_cur_tier.needs_food AND NOT v_has_food)
           OR (v_cur_tier.needs_school AND NOT v_has_school)
           OR (v_cur_tier.needs_temple AND NOT v_has_temple)
           OR (v_cur_tier.needs_luxury_food AND NOT v_has_luxury_food)
           OR (v_cur_tier.needs_industrial_luxury AND NOT v_has_industrial_luxury)
           OR (v_cur_tier.needs_all_industrial_luxuries AND NOT v_has_all_industrial_luxuries)
           OR NOT v_lifestyle_for_cur_ok
           OR (NOT v_skip_des AND v_desirability < COALESCE(v_cur_tier.min_desirability, 0) - 30))
      AND NOT v_has_bathhouse
      AND v_elapsed >= COALESCE(v_cur_tier.devolve_secs, 30);

    -- Track null→eligible transitions for the summary event.
    IF v_should_upgrade THEN
      IF v_house.evolution_eligible_at IS NULL THEN
        UPDATE public.buildings SET evolution_eligible_at = v_now WHERE id = v_house.id;
        v_newly_eligible := v_newly_eligible + 1;
      END IF;
    ELSE
      -- Conditions slipped (or never met). Clear the flag — inspector
      -- button + summary count drops accordingly. Don't emit an event.
      IF v_house.evolution_eligible_at IS NOT NULL THEN
        UPDATE public.buildings SET evolution_eligible_at = NULL WHERE id = v_house.id;
      END IF;
    END IF;

    -- Devolves still fire automatically.
    IF v_should_devolve THEN
      UPDATE public.buildings
         SET housing_tier = housing_tier - 1,
             last_processed_at = v_now,
             evolution_eligible_at = NULL
       WHERE id = v_house.id;
      v_events := v_events || jsonb_build_object(
        'building_id', v_house.id, 'event', 'devolve',
        'from_tier', v_house.housing_tier, 'to_tier', v_house.housing_tier - 1
      )::json;
    END IF;
  END LOOP;

  -- Single summary event per tick — client converts to one toast.
  -- Repeats on every tick where new houses become eligible (so the
  -- player gets prompted again if they upgrade some and others go
  -- eligible later).
  IF v_newly_eligible > 0 THEN
    v_events := v_events || jsonb_build_object(
      'event', 'housing_ready_to_upgrade',
      'count', v_newly_eligible
    )::json;
  END IF;

  RETURN v_events;
END;
$function$;


-- ── New RPC: upgrade_house ──
-- The player taps the "Upgrade" button in the inspector. RPC validates
-- the eligibility flag (set by _pp_evolve_housing on the most recent
-- tick) before bumping the tier. If conditions slipped between tick
-- and click, the flag is null and the call is rejected.
CREATE OR REPLACE FUNCTION public.upgrade_house(p_building_id uuid)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_b record;
  v_bt record;
  v_new_tier integer;
  v_next_cfg record;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;

  SELECT * INTO v_b FROM public.buildings WHERE id = p_building_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Building not found'; END IF;
  IF v_b.player_id <> v_uid THEN RAISE EXCEPTION 'Not your building'; END IF;

  SELECT * INTO v_bt FROM public.building_types WHERE key = v_b.building_type_key;
  IF v_bt.category <> 'housing' THEN
    RAISE EXCEPTION 'Only housing can be upgraded';
  END IF;

  IF v_b.status <> 'active' THEN
    RAISE EXCEPTION 'House is not active';
  END IF;

  IF v_b.evolution_eligible_at IS NULL THEN
    RAISE EXCEPTION 'House is not currently eligible to upgrade';
  END IF;

  v_new_tier := v_b.housing_tier + 1;
  SELECT * INTO v_next_cfg FROM public.housing_tier_config WHERE tier = v_new_tier;
  IF v_next_cfg IS NULL THEN
    RAISE EXCEPTION 'Already at max tier';
  END IF;

  UPDATE public.buildings
     SET housing_tier = v_new_tier,
         evolution_eligible_at = NULL,
         last_processed_at = now()
   WHERE id = p_building_id;

  UPDATE public.player_profiles
     SET highest_housing_tier_ever = GREATEST(highest_housing_tier_ever, v_new_tier)
   WHERE id = v_uid;

  RETURN json_build_object(
    'building_id', p_building_id,
    'from_tier', v_b.housing_tier,
    'to_tier', v_new_tier,
    'tier_name', v_next_cfg.name
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.upgrade_house(uuid) TO authenticated;
