-- Add resource-cost validation + deduction to place_building.
--
-- Two new sections:
--   1. After the money check: loop building_type_resource_costs for
--      this building type, raise EXCEPTION if any quantity short.
--   2. Right before the final RETURN: loop again and deduct each
--      resource from the player's inventory. Money deduction stays
--      where it is.
--
-- Single-pass validation (collect missing, raise once with the full
-- list) so the player sees "Need 8 brick + 5 lime" not "Need brick"
-- followed by a separate "Need lime" on the next try.

CREATE OR REPLACE FUNCTION public.place_building(p_tile_id uuid, p_building_type_key text)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
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
  v_cost record;
  v_have numeric;
  v_missing text;
  v_missing_list text := '';
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
  IF v_bt.unlocks_at_housing_tier IS NOT NULL
     AND v_player.highest_housing_tier_ever < v_bt.unlocks_at_housing_tier THEN
    RAISE EXCEPTION 'Locked: %', v_bt.name
      USING HINT = 'Reach housing tier ' || v_bt.unlocks_at_housing_tier || ' first';
  END IF;
  IF v_player.money < v_bt.build_cost THEN
    RAISE EXCEPTION 'Not enough money (need %, have %)', v_bt.build_cost, v_player.money;
  END IF;

  -- Resource cost gate. Walk every required resource for this building
  -- type, collect any shortages, then raise once with the full list so
  -- the player can fix everything at once.
  FOR v_cost IN
    SELECT btrc.resource_key, btrc.quantity, r.name AS resource_name
    FROM public.building_type_resource_costs btrc
    JOIN public.resources r ON r.key = btrc.resource_key
    WHERE btrc.building_type_key = p_building_type_key
  LOOP
    SELECT COALESCE(quantity, 0) INTO v_have
    FROM public.inventories
    WHERE player_id = v_uid AND resource_key = v_cost.resource_key;
    v_have := COALESCE(v_have, 0);
    IF v_have < v_cost.quantity THEN
      v_missing := v_cost.quantity || ' ' || v_cost.resource_name
                || ' (have ' || FLOOR(v_have)::text || ')';
      v_missing_list := CASE WHEN v_missing_list = '' THEN v_missing
                             ELSE v_missing_list || ', ' || v_missing END;
    END IF;
  END LOOP;
  IF v_missing_list <> '' THEN
    RAISE EXCEPTION 'Not enough resources: need %', v_missing_list;
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

  -- Deduct resource costs (validated above; safe to subtract now).
  FOR v_cost IN
    SELECT resource_key, quantity FROM public.building_type_resource_costs
    WHERE building_type_key = p_building_type_key
  LOOP
    UPDATE public.inventories
       SET quantity = quantity - v_cost.quantity, updated_at = now()
     WHERE player_id = v_uid AND resource_key = v_cost.resource_key;
  END LOOP;

  v_worker_supply := 5 + public._pp_housing_supply(v_uid);
  v_workers_needed := public._pp_workers_needed(v_uid);

  UPDATE public.player_profiles
  SET money = money - v_bt.build_cost,
      worker_capacity = v_worker_supply,
      workers_used = LEAST(v_worker_supply, v_workers_needed)
  WHERE id = v_uid RETURNING * INTO v_player;

  IF v_bt.build_cost > 0 THEN
    INSERT INTO public.cash_transactions (player_id, source, amount, context)
    VALUES (v_uid, 'build_cost', -v_bt.build_cost,
            jsonb_build_object('building_type_key', p_building_type_key, 'building_id', v_building_id));
  END IF;

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
$function$;
