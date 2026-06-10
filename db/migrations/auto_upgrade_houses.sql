-- ─────────────────────────────────────────────────────────────────────
-- Per-house auto-upgrade toggle (2026-05-11).
--
-- Atlas: "Houses currently have the button to upgrade manually. Let's
-- change that. Let's make it a toggle... per house... default to auto
-- upgrade. However for the houses that currently exist, have it
-- toggled off. But if I build a new house, it should initially be
-- set to auto upgrade."
--
-- Schema:
--   buildings.auto_upgrade boolean. Existing rows default to FALSE
--   (preserves the manual flow for houses Atlas + others have been
--   playing with). Future INSERTs default to TRUE so new houses
--   auto-upgrade by default.
--
-- Server:
--   _pp_evolve_housing now branches on auto_upgrade when an upgrade
--   gate passes:
--     - auto_upgrade=TRUE  → bump housing_tier immediately (just like
--                            a devolve in reverse), no manual button,
--                            no bell notification
--     - auto_upgrade=FALSE → stamp evolution_eligible_at + bump the
--                            newly_eligible counter, exactly as before
--   Both branches set last_processed_at = now() so the upgrade grace
--   anchor for the new tier is fresh.
--
-- Client RPC:
--   set_house_auto_upgrade(p_building_id uuid, p_enabled boolean)
--   Validates ownership + housing category, updates the flag.
--
-- The Inspector will surface a toggle button (separate JS change).
-- ─────────────────────────────────────────────────────────────────────

-- ── Column with backfill ────────────────────────────────────────────
ALTER TABLE public.buildings
  ADD COLUMN IF NOT EXISTS auto_upgrade boolean NOT NULL DEFAULT false;

-- Future INSERTs (new houses) get TRUE. Existing rows already got FALSE
-- as the backfill default above; the ALTER below only affects rows
-- inserted from this point on.
ALTER TABLE public.buildings
  ALTER COLUMN auto_upgrade SET DEFAULT true;


-- ── set_house_auto_upgrade RPC ──────────────────────────────────────
CREATE OR REPLACE FUNCTION public.set_house_auto_upgrade(
  p_building_id uuid,
  p_enabled boolean
)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_b record;
  v_bt record;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'auth required'; END IF;

  SELECT * INTO v_b FROM public.buildings WHERE id = p_building_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Building not found'; END IF;
  IF v_b.player_id <> v_uid THEN RAISE EXCEPTION 'Not your building'; END IF;

  SELECT category INTO v_bt FROM public.building_types
  WHERE key = v_b.building_type_key;
  IF v_bt.category <> 'housing' THEN
    RAISE EXCEPTION 'Auto-upgrade only applies to housing';
  END IF;

  UPDATE public.buildings SET auto_upgrade = p_enabled WHERE id = p_building_id;

  RETURN json_build_object(
    'building_id', p_building_id,
    'auto_upgrade', p_enabled
  );
END;
$$;


-- ── _pp_evolve_housing: branch on auto_upgrade for upgrades ─────────
CREATE OR REPLACE FUNCTION public._pp_evolve_housing(p_uid uuid, p_operating_services uuid[])
RETURNS json[]
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
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
          AND COALESCE((SELECT quantity FROM public.inventories i
                         WHERE i.player_id = p_uid AND i.resource_key = hld.resource_key), 0) <= 0
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
        -- Auto-upgrade path: bump the tier in place. No
        -- evolution_eligible_at stamp, no newly_eligible count
        -- (no bell notification needed — player opted in).
        UPDATE public.buildings
           SET housing_tier = housing_tier + 1,
               last_processed_at = v_now,
               evolution_eligible_at = NULL
         WHERE id = v_house.id;
        v_auto_upgraded := v_auto_upgraded + 1;
        v_events := v_events || jsonb_build_object(
          'building_id', v_house.id, 'event', 'auto_upgrade',
          'from_tier', v_house.housing_tier, 'to_tier', v_house.housing_tier + 1
        )::json;
      ELSE
        -- Manual path: stamp eligibility + count for the bell.
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
$$;


-- ── Changelog entry ─────────────────────────────────────────────────
INSERT INTO public.changelog_entries (slug, title, body)
VALUES (
  '2026-05-11-auto-upgrade-toggle',
  'Houses get a per-house auto-upgrade toggle',
  E'Tap a house in the inspector to find a new "Auto-upgrade" toggle. When ON, the server bumps the house''s tier the moment all the conditions are met — no more tapping Upgrade to confirm each one. When OFF, you keep the manual button you''re used to.\n\nNew houses you place from this point on default to auto-upgrade ON. Your existing houses default to OFF so nothing changes for them unless you flip the switch.'
)
ON CONFLICT (slug) DO NOTHING;
