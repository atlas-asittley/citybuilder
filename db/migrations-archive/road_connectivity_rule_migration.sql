-- ============================================================
-- City Builder - Road Connectivity Rule Migration
-- ============================================================
-- Run AFTER the Housing Evolution migration is in place.
-- Adds: road placement rule so roads must connect to the
--       city center or an existing road.
-- ============================================================

CREATE OR REPLACE FUNCTION public.place_building(p_tile_id uuid, p_building_type_key text)
RETURNS json LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_bt record;
  v_tile record;
  v_player record;
  v_building_id uuid;
  v_worker_supply integer;
  v_workers_needed integer;
  v_road_connected boolean;
BEGIN
  SELECT * INTO v_bt FROM public.building_types WHERE key = p_building_type_key AND is_active;
  IF NOT FOUND THEN RAISE EXCEPTION 'Unknown building type'; END IF;

  SELECT * INTO v_player FROM public.player_profiles WHERE id = v_uid;
  IF NOT FOUND THEN RAISE EXCEPTION 'Player not found'; END IF;

  IF v_bt.industry_key <> 'common' AND v_bt.industry_key <> v_player.industry_key THEN
    RAISE EXCEPTION 'You can only place buildings for your chosen industry';
  END IF;

  IF v_player.money < v_bt.build_cost THEN
    RAISE EXCEPTION 'Not enough money (need %, have %)', v_bt.build_cost, v_player.money;
  END IF;

  SELECT * INTO v_tile FROM public.map_tiles WHERE id = p_tile_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Tile not found'; END IF;
  IF NOT v_tile.buildable THEN RAISE EXCEPTION 'Tile is not buildable'; END IF;
  IF v_tile.occupied_building_id IS NOT NULL THEN RAISE EXCEPTION 'Tile already occupied'; END IF;

  IF v_bt.category = 'extractor' THEN
    IF v_tile.resource_node_key IS NULL OR v_tile.resource_node_key != v_bt.output_resource_key THEN
      RAISE EXCEPTION 'Extractor must be placed on a matching resource tile';
    END IF;
  ELSIF v_bt.category = 'road' THEN
    SELECT (
      (ABS(v_tile.x - 7) + ABS(v_tile.y - 7)) = 1
      OR EXISTS (
        SELECT 1
        FROM public.buildings b2
        JOIN public.building_types bt2 ON bt2.key = b2.building_type_key
        WHERE bt2.category = 'road'
          AND b2.status = 'active'
          AND (
            (b2.x = v_tile.x - 1 AND b2.y = v_tile.y)
            OR (b2.x = v_tile.x + 1 AND b2.y = v_tile.y)
            OR (b2.x = v_tile.x AND b2.y = v_tile.y - 1)
            OR (b2.x = v_tile.x AND b2.y = v_tile.y + 1)
          )
      )
    ) INTO v_road_connected;

    IF NOT v_road_connected THEN
      RAISE EXCEPTION 'Roads must connect to the city center or another road';
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

  UPDATE public.map_tiles SET occupied_building_id = v_building_id WHERE id = p_tile_id;

  SELECT 5 + COALESCE(SUM(htc.workers), 0) INTO v_worker_supply
  FROM public.buildings b2
  JOIN public.building_types bt2 ON bt2.key = b2.building_type_key
  JOIN public.housing_tier_config htc ON htc.tier = b2.housing_tier
  WHERE b2.player_id = v_uid AND b2.status = 'active' AND bt2.category = 'housing'
    AND (NOT htc.needs_road OR public.has_road_access(b2.x, b2.y));

  SELECT COALESCE(SUM(bt2.worker_cost), 0) INTO v_workers_needed
  FROM public.buildings b2
  JOIN public.building_types bt2 ON bt2.key = b2.building_type_key
  WHERE b2.player_id = v_uid AND b2.status = 'active'
    AND (
      bt2.category = 'extractor'
      OR (bt2.category = 'processor' AND public.has_road_access(b2.x, b2.y))
    );

  UPDATE public.player_profiles
  SET money = money - v_bt.build_cost,
      worker_capacity = v_worker_supply,
      workers_used = LEAST(v_worker_supply, v_workers_needed)
  WHERE id = v_uid
  RETURNING * INTO v_player;

  RETURN json_build_object(
    'building_id', v_building_id,
    'money', v_player.money,
    'workers_used', v_player.workers_used,
    'worker_capacity', v_player.worker_capacity,
    'workers_needed', v_workers_needed,
    'labor_shortage', v_workers_needed > v_worker_supply
  );
END;
$$;
