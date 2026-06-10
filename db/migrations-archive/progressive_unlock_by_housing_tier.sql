-- Progressive building unlock by housing tier.
--
-- Buildings whose only purpose is gating a higher tier of housing are
-- now locked until the player has reached the previous tier. So school
-- (which itself gates T4 housing) is hidden until you have a T3 house;
-- temple (gates T5) hidden until T4; luxury food (gates T6) until T5;
-- industrial luxury T4 cross-recipe processors (gate T7+) until T6.
--
-- Sticky: once a tier has been reached, the gate stays unlocked forever
-- — even if the qualifying house later devolves. Tracked by a new
-- `highest_housing_tier_ever` column on player_profiles, bumped inside
-- the _pp_evolve_housing helper.

-- ── 1. Schema ───────────────────────────────────────────
ALTER TABLE public.building_types
  ADD COLUMN IF NOT EXISTS unlocks_at_housing_tier integer;

ALTER TABLE public.player_profiles
  ADD COLUMN IF NOT EXISTS highest_housing_tier_ever integer NOT NULL DEFAULT 0;

-- ── 2. Seed unlock thresholds for the gate buildings ────
UPDATE public.building_types SET unlocks_at_housing_tier = 3 WHERE key = 'school';
UPDATE public.building_types SET unlocks_at_housing_tier = 4 WHERE key = 'temple';
UPDATE public.building_types SET unlocks_at_housing_tier = 5
  WHERE key IN ('distillery','curing_house','spicery','brewery');
UPDATE public.building_types SET unlocks_at_housing_tier = 6
  WHERE key IN ('cabinetmaker','architect','mosaic_workshop','engineer_workshop');

-- ── 3. Backfill highest_housing_tier_ever for existing players ──
-- Existing players get credit for any house tier they currently have
-- so the migration is invisible to anyone mid-game.
UPDATE public.player_profiles pp
SET highest_housing_tier_ever = COALESCE((
  SELECT MAX(b.housing_tier) FROM public.buildings b
  JOIN public.building_types bt ON bt.key = b.building_type_key
  WHERE b.player_id = pp.id AND b.status = 'active'
    AND bt.category = 'housing'
), 0)
WHERE highest_housing_tier_ever = 0;

-- ── 4. Update _pp_evolve_housing to bump the watermark on every upgrade ──
-- Re-fetched + edited from the live function. Adds one UPDATE at the
-- top of the upgrade branch.
CREATE OR REPLACE FUNCTION public._pp_evolve_housing(p_uid uuid, p_operating_services uuid[])
RETURNS json[]
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  h record;
  v_now timestamptz := now();
  v_events json[] := ARRAY[]::json[];
  v_next_tier integer;
  v_next_cfg record;
  v_blocked boolean;
  v_has_road boolean;
  v_has_well boolean;
  v_has_food boolean;
  v_has_school boolean;
  v_has_temple boolean;
  v_has_bathhouse boolean;
  v_has_lux_food boolean;
  v_has_ind_lux boolean;
  v_has_all_ind_lux boolean;
  v_count_in_stock integer;
  v_count_total integer;
  v_elapsed_secs numeric;
  v_upgrade_secs constant numeric := 60;
  v_devolve_secs constant numeric := 120;
BEGIN
  FOR h IN
    SELECT b.* FROM public.buildings b
    JOIN public.building_types bt ON bt.key = b.building_type_key
    WHERE b.player_id = p_uid AND b.status = 'active' AND bt.category = 'housing'
    FOR UPDATE OF b
  LOOP
    v_elapsed_secs := EXTRACT(EPOCH FROM (v_now - h.last_processed_at));

    -- Try to upgrade to next tier if conditions met for v_upgrade_secs.
    v_next_tier := h.housing_tier + 1;
    SELECT * INTO v_next_cfg FROM public.housing_tier_config WHERE tier = v_next_tier;
    IF FOUND THEN
      v_has_road := NOT v_next_cfg.needs_road OR public.has_road_access(p_uid, h.x, h.y);
      v_has_well := NOT v_next_cfg.needs_well OR public.has_well_access(p_uid, h.x, h.y);
      v_has_food := NOT v_next_cfg.needs_food OR EXISTS (
        SELECT 1 FROM public.inventories i JOIN public.resources r ON r.key = i.resource_key
        WHERE i.player_id = p_uid AND r.is_food AND i.quantity > 0
      );
      v_has_school := NOT v_next_cfg.needs_school OR EXISTS (
        SELECT 1 FROM public.buildings b2
        WHERE b2.id = ANY(p_operating_services)
          AND b2.building_type_key = 'school'
          AND ABS(b2.x - h.x) + ABS(b2.y - h.y) <= 5
      );
      v_has_temple := NOT v_next_cfg.needs_temple OR EXISTS (
        SELECT 1 FROM public.buildings b2
        WHERE b2.id = ANY(p_operating_services)
          AND b2.building_type_key = 'temple'
          AND ABS(b2.x - h.x) + ABS(b2.y - h.y) <= 6
      );
      v_has_lux_food := NOT v_next_cfg.needs_luxury_food OR EXISTS (
        SELECT 1 FROM public.inventories i JOIN public.resources r ON r.key = i.resource_key
        WHERE i.player_id = p_uid AND r.is_luxury_food AND i.quantity > 0
      );
      v_has_ind_lux := NOT v_next_cfg.needs_industrial_luxury OR EXISTS (
        SELECT 1 FROM public.inventories i JOIN public.resources r ON r.key = i.resource_key
        WHERE i.player_id = p_uid AND r.is_industrial_luxury AND i.quantity > 0
      );
      v_has_all_ind_lux := TRUE;
      IF v_next_cfg.needs_all_industrial_luxuries THEN
        SELECT
          COUNT(*) FILTER (WHERE COALESCE(i.quantity, 0) > 0),
          COUNT(*)
        INTO v_count_in_stock, v_count_total
        FROM public.resources r
        LEFT JOIN public.inventories i
          ON i.resource_key = r.key AND i.player_id = p_uid
        WHERE r.is_industrial_luxury;
        v_has_all_ind_lux := v_count_in_stock >= v_count_total;
      END IF;

      IF v_has_road AND v_has_well AND v_has_food AND v_has_school AND v_has_temple
         AND v_has_lux_food AND v_has_ind_lux AND v_has_all_ind_lux
         AND v_elapsed_secs >= v_upgrade_secs
      THEN
        UPDATE public.buildings
        SET housing_tier = v_next_tier, last_processed_at = v_now
        WHERE id = h.id;
        v_events := array_append(v_events, json_build_object(
          'event', 'upgrade', 'building_id', h.id,
          'from_tier', h.housing_tier, 'to_tier', v_next_tier
        ));
        -- Sticky watermark: never goes down. Lets the build panel keep
        -- gate-buildings unlocked even if all houses later devolve.
        UPDATE public.player_profiles
          SET highest_housing_tier_ever = GREATEST(highest_housing_tier_ever, v_next_tier)
          WHERE id = p_uid;
        CONTINUE;
      END IF;
    END IF;

    -- Try to devolve. We re-evaluate the CURRENT tier's prereqs; if they
    -- fail and a bathhouse isn't sheltering this house, devolve.
    SELECT * INTO v_next_cfg FROM public.housing_tier_config WHERE tier = h.housing_tier;
    IF FOUND AND h.housing_tier > 0 THEN
      v_has_road := NOT v_next_cfg.needs_road OR public.has_road_access(p_uid, h.x, h.y);
      v_has_well := NOT v_next_cfg.needs_well OR public.has_well_access(p_uid, h.x, h.y);
      v_has_food := NOT v_next_cfg.needs_food OR EXISTS (
        SELECT 1 FROM public.inventories i JOIN public.resources r ON r.key = i.resource_key
        WHERE i.player_id = p_uid AND r.is_food AND i.quantity > 0
      );
      v_has_bathhouse := EXISTS (
        SELECT 1 FROM public.buildings b2
        WHERE b2.id = ANY(p_operating_services)
          AND b2.building_type_key = 'bathhouse'
          AND ABS(b2.x - h.x) + ABS(b2.y - h.y) <= 4
      );
      v_blocked := v_has_road AND v_has_well AND v_has_food;
      IF NOT v_blocked AND NOT v_has_bathhouse AND v_elapsed_secs >= v_devolve_secs THEN
        UPDATE public.buildings
        SET housing_tier = h.housing_tier - 1, last_processed_at = v_now
        WHERE id = h.id;
        v_events := array_append(v_events, json_build_object(
          'event', 'devolve', 'building_id', h.id,
          'from_tier', h.housing_tier, 'to_tier', h.housing_tier - 1
        ));
      END IF;
    END IF;
  END LOOP;
  RETURN v_events;
END;
$$;

GRANT EXECUTE ON FUNCTION public._pp_evolve_housing(uuid, uuid[]) TO authenticated;

-- ── 5. Server-side gate in place_building ───────────────
-- Reject placement if the player hasn't reached the required watermark.
-- Add the check near the top of place_building, right after looking up
-- the building type and player.
CREATE OR REPLACE FUNCTION public.place_building(p_tile_id uuid, p_building_type_key text)
RETURNS json
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_bt record;
  v_tile record;
  v_player record;
  v_building_id uuid;
  v_worker_supply integer;
  v_workers_needed integer;
  v_road_connected boolean;
  v_path record;
  v_w int;
  v_h int;
  v_dx int;
  v_dy int;
  v_check_tile record;
  v_footprint_tile_ids uuid[] := ARRAY[]::uuid[];
BEGIN
  SELECT NULL::integer AS target_x, NULL::integer AS target_y, NULL::integer AS path_length
  INTO v_path;
  SELECT * INTO v_bt FROM public.building_types WHERE key = p_building_type_key AND is_active;
  IF NOT FOUND THEN RAISE EXCEPTION 'Unknown building type'; END IF;
  SELECT * INTO v_player FROM public.player_profiles WHERE id = v_uid;
  IF NOT FOUND THEN RAISE EXCEPTION 'Player not found'; END IF;
  IF v_bt.industry_key <> 'common' AND v_bt.industry_key <> v_player.industry_key THEN
    RAISE EXCEPTION 'You can only place buildings for your chosen industry';
  END IF;
  -- Progressive unlock gate.
  IF v_bt.unlocks_at_housing_tier IS NOT NULL
     AND v_player.highest_housing_tier_ever < v_bt.unlocks_at_housing_tier THEN
    RAISE EXCEPTION 'Locked: %', v_bt.name
      USING HINT = 'Reach housing tier ' || v_bt.unlocks_at_housing_tier || ' first';
  END IF;
  IF v_player.money < v_bt.build_cost THEN
    RAISE EXCEPTION 'Not enough money (need %, have %)', v_bt.build_cost, v_player.money;
  END IF;
  SELECT * INTO v_tile FROM public.map_tiles WHERE id = p_tile_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Tile not found'; END IF;

  v_w := COALESCE(v_bt.footprint_w, 1);
  v_h := COALESCE(v_bt.footprint_h, 1);

  FOR v_dx IN 0..(v_w - 1) LOOP
    FOR v_dy IN 0..(v_h - 1) LOOP
      SELECT * INTO v_check_tile FROM public.map_tiles
        WHERE x = v_tile.x + v_dx AND y = v_tile.y + v_dy
        FOR UPDATE;
      IF NOT FOUND THEN
        RAISE EXCEPTION 'Footprint extends off the map at (%, %)', v_tile.x + v_dx, v_tile.y + v_dy;
      END IF;
      IF v_check_tile.owner_player_id IS NULL THEN
        RAISE EXCEPTION 'Cannot build on wilderness — expand your district first';
      END IF;
      IF v_check_tile.owner_player_id <> v_uid THEN
        RAISE EXCEPTION 'Cannot build on another player''s district';
      END IF;
      IF NOT v_check_tile.buildable THEN
        RAISE EXCEPTION 'Tile (%, %) is not buildable', v_check_tile.x, v_check_tile.y;
      END IF;
      IF v_check_tile.occupied_building_id IS NOT NULL THEN
        RAISE EXCEPTION 'Tile (%, %) is already occupied', v_check_tile.x, v_check_tile.y;
      END IF;
      v_footprint_tile_ids := v_footprint_tile_ids || v_check_tile.id;
    END LOOP;
  END LOOP;

  IF v_bt.category = 'road' THEN
    SELECT EXISTS (
      SELECT 1 FROM public.buildings b2
      JOIN public.building_types bt2 ON bt2.key = b2.building_type_key
      WHERE bt2.category = 'road' AND b2.status = 'active' AND b2.player_id = v_uid
        AND ((b2.x = v_tile.x - 1 AND b2.y = v_tile.y)
             OR (b2.x = v_tile.x + 1 AND b2.y = v_tile.y)
             OR (b2.x = v_tile.x AND b2.y = v_tile.y - 1)
             OR (b2.x = v_tile.x AND b2.y = v_tile.y + 1))
    ) INTO v_road_connected;
    IF NOT v_road_connected THEN
      RAISE EXCEPTION 'Roads must connect to another of your roads';
    END IF;
  END IF;

  IF v_bt.category = 'housing' THEN
    INSERT INTO public.buildings (player_id, building_type_key, tile_id, x, y, housing_tier)
    VALUES (v_uid, p_building_type_key, p_tile_id, v_tile.x, v_tile.y, 0)
    RETURNING id INTO v_building_id;
  ELSE
    INSERT INTO public.buildings (player_id, building_type_key, tile_id, x, y)
    VALUES (v_uid, p_building_type_key, p_tile_id, v_tile.x, v_tile.y)
    RETURNING id INTO v_building_id;
  END IF;

  UPDATE public.map_tiles SET occupied_building_id = v_building_id
    WHERE id = ANY(v_footprint_tile_ids);

  IF v_bt.category = 'extractor' THEN
    SELECT * INTO v_path FROM public.find_nearest_unclaimed_resource(v_uid, v_tile.x, v_tile.y);
    IF v_path.path_length IS NOT NULL THEN
      UPDATE public.buildings
        SET target_x = v_path.target_x, target_y = v_path.target_y, path_length = v_path.path_length
      WHERE id = v_building_id;
      UPDATE public.map_tiles SET claimed_by_building_id = v_building_id
        WHERE x = v_path.target_x AND y = v_path.target_y;
    END IF;
  END IF;

  IF v_bt.category = 'road' THEN
    PERFORM public.recompute_extractor_paths(v_uid);
  END IF;

  v_worker_supply := 5 + public._pp_housing_supply(v_uid);
  v_workers_needed := public._pp_workers_needed(v_uid);

  UPDATE public.player_profiles
  SET money = money - v_bt.build_cost,
      worker_capacity = v_worker_supply,
      workers_used = LEAST(v_worker_supply, v_workers_needed)
  WHERE id = v_uid RETURNING * INTO v_player;

  RETURN json_build_object(
    'building_id', v_building_id,
    'money', v_player.money,
    'workers_used', v_player.workers_used,
    'worker_capacity', v_player.worker_capacity,
    'workers_needed', v_workers_needed,
    'labor_shortage', v_workers_needed > v_worker_supply,
    'extractor_target', CASE WHEN v_path.path_length IS NOT NULL
      THEN json_build_object('x', v_path.target_x, 'y', v_path.target_y, 'path_length', v_path.path_length)
      ELSE NULL END
  );
END;
$$;
GRANT EXECUTE ON FUNCTION public.place_building(uuid, text) TO authenticated;
