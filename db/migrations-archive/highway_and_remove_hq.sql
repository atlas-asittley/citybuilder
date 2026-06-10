-- Highway + remove HQ tile.
--
-- Replaces the per-starter "city center" tile with a global highway
-- network that threads through every chunk: a horizontal strip at
-- y_offset = 7 and a vertical strip at x_offset = 7. The two strips
-- cross at the chunk center and connect adjacent chunks via the row /
-- column they share.
--
-- The highway is conceptually owned by the game (no player can demolish
-- it, no player can build on it). The data model keeps it owned by the
-- player whose chunk it sits in (so RLS still works), but the tile is
-- marked unbuildable + walkable so it functions as a shared road.
--
-- Walker pathing and road-access checks now treat highway tiles as
-- cost-1 walkable, regardless of which player owns them — so the
-- highway lets walkers cross into another player's district without
-- breaking the existing "you can't walk through other players' regular
-- tiles" rule.
--
-- Road placement: roads must now be adjacent to a road OR a highway
-- tile (drops the old "adjacent to home tile" rule, which was the same
-- thing back when the home tile was the only seed).
--
-- Apply: psql "$DB_URL" -f highway_and_remove_hq.sql

-- 1. Update allocate_district_chunk: stamp highway in every chunk,
--    drop the city_center stamping. Set home_x/home_y on the first
--    chunk to the highway intersection (still a useful logical anchor).
CREATE OR REPLACE FUNCTION public.allocate_district_chunk(p_player_id uuid, p_chunk_x integer, p_chunk_y integer)
 RETURNS json
 LANGUAGE plpgsql
AS $function$
DECLARE
  v_player record;
  v_x_start integer := p_chunk_x * 15;
  v_y_start integer := p_chunk_y * 15;
  v_dx integer;
  v_dy integer;
  v_resource_key text;
  v_resource_count integer;
  v_is_first_chunk boolean;
  v_cluster_count constant integer := 4;
  v_cluster_idx integer;
  v_walk_steps integer;
  v_step_idx integer;
  v_seed_dx integer;
  v_seed_dy integer;
  v_curr_dx integer;
  v_curr_dy integer;
  v_new_dx integer;
  v_new_dy integer;
  v_dir integer;
BEGIN
  IF EXISTS (
    SELECT 1 FROM public.district_chunks
    WHERE chunk_x = p_chunk_x AND chunk_y = p_chunk_y
  ) THEN
    RAISE EXCEPTION 'Chunk (%, %) is already allocated', p_chunk_x, p_chunk_y;
  END IF;

  SELECT * INTO v_player FROM public.player_profiles WHERE id = p_player_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Player not found'; END IF;

  v_resource_key := v_player.industry_key;
  v_is_first_chunk := (v_player.chunks_owned = 0);

  -- Lay down all 225 ground tiles with no resource.
  FOR v_dx IN 0..14 LOOP
    FOR v_dy IN 0..14 LOOP
      INSERT INTO public.map_tiles (
        x, y, terrain_type, resource_node_key, buildable, owner_player_id
      ) VALUES (
        v_x_start + v_dx,
        v_y_start + v_dy,
        'ground',
        NULL,
        true,
        p_player_id
      )
      ON CONFLICT (x, y) DO UPDATE SET
        owner_player_id = p_player_id,
        terrain_type = 'ground',
        buildable = true;
    END LOOP;
  END LOOP;

  -- Seed resource clusters via random walk.
  FOR v_cluster_idx IN 1..v_cluster_count LOOP
    v_seed_dx := floor(random() * 15)::integer;
    v_seed_dy := floor(random() * 15)::integer;
    v_walk_steps := 6 + floor(random() * 10)::integer;
    v_curr_dx := v_seed_dx;
    v_curr_dy := v_seed_dy;

    UPDATE public.map_tiles
    SET resource_node_key = v_resource_key
    WHERE x = v_x_start + v_curr_dx
      AND y = v_y_start + v_curr_dy
      AND resource_node_key IS NULL;

    FOR v_step_idx IN 1..v_walk_steps LOOP
      v_dir := floor(random() * 4)::integer;
      v_new_dx := v_curr_dx + CASE v_dir WHEN 0 THEN 1 WHEN 1 THEN -1 ELSE 0 END;
      v_new_dy := v_curr_dy + CASE v_dir WHEN 2 THEN 1 WHEN 3 THEN -1 ELSE 0 END;
      IF v_new_dx < 0 OR v_new_dx > 14 OR v_new_dy < 0 OR v_new_dy > 14 THEN
        v_curr_dx := v_seed_dx;
        v_curr_dy := v_seed_dy;
        CONTINUE;
      END IF;
      UPDATE public.map_tiles
      SET resource_node_key = v_resource_key
      WHERE x = v_x_start + v_new_dx
        AND y = v_y_start + v_new_dy
        AND resource_node_key IS NULL;
      v_curr_dx := v_new_dx;
      v_curr_dy := v_new_dy;
    END LOOP;
  END LOOP;

  -- Stamp highway: horizontal strip at y_offset = 7, vertical strip at
  -- x_offset = 7. Unbuildable, no resource, distinct terrain_type so
  -- the client and walker code can recognize it.
  UPDATE public.map_tiles
  SET terrain_type = 'highway',
      buildable = false,
      resource_node_key = NULL
  WHERE owner_player_id = p_player_id
    AND x >= v_x_start AND x < v_x_start + 15
    AND y >= v_y_start AND y < v_y_start + 15
    AND (x = v_x_start + 7 OR y = v_y_start + 7);

  -- Player home anchors the player's "starter intersection" on the
  -- first chunk. Still useful for map-centering and as a return point
  -- in the UI; no longer marks a special unbuildable tile (that's the
  -- highway now).
  IF v_is_first_chunk THEN
    UPDATE public.player_profiles
    SET home_x = v_x_start + 7, home_y = v_y_start + 7
    WHERE id = p_player_id;
  END IF;

  INSERT INTO public.district_chunks (chunk_x, chunk_y, owner_player_id)
  VALUES (p_chunk_x, p_chunk_y, p_player_id);

  UPDATE public.player_profiles
  SET chunks_owned = chunks_owned + 1
  WHERE id = p_player_id;

  SELECT COUNT(*) INTO v_resource_count
  FROM public.map_tiles
  WHERE owner_player_id = p_player_id
    AND x >= v_x_start AND x < v_x_start + 15
    AND y >= v_y_start AND y < v_y_start + 15
    AND resource_node_key IS NOT NULL;

  RETURN json_build_object(
    'chunk_x', p_chunk_x,
    'chunk_y', p_chunk_y,
    'tile_x_start', v_x_start,
    'tile_y_start', v_y_start,
    'resource_tiles', v_resource_count,
    'is_first_chunk', v_is_first_chunk
  );
END;
$function$;


-- 2. has_road_access: a tile counts as having road access if an
--    orthogonal neighbor is either a player-owned road building or a
--    highway tile. Highway is shared infrastructure — anyone can use
--    it as a road-attachment seed.
CREATE OR REPLACE FUNCTION public.has_road_access(p_x integer, p_y integer)
 RETURNS boolean
 LANGUAGE sql
 STABLE
AS $function$
  SELECT EXISTS (
    SELECT 1 FROM public.buildings b
    JOIN public.building_types bt ON bt.key = b.building_type_key
    WHERE bt.category = 'road' AND b.status = 'active'
      AND ((b.x = p_x - 1 AND b.y = p_y) OR (b.x = p_x + 1 AND b.y = p_y)
           OR (b.x = p_x AND b.y = p_y - 1) OR (b.x = p_x AND b.y = p_y + 1))
  ) OR EXISTS (
    SELECT 1 FROM public.map_tiles mt
    WHERE mt.terrain_type = 'highway'
      AND ((mt.x = p_x - 1 AND mt.y = p_y) OR (mt.x = p_x + 1 AND mt.y = p_y)
           OR (mt.x = p_x AND mt.y = p_y - 1) OR (mt.x = p_x AND mt.y = p_y + 1))
  );
$function$;

CREATE OR REPLACE FUNCTION public.has_road_access(p_player_id uuid, p_x integer, p_y integer)
 RETURNS boolean
 LANGUAGE sql
 STABLE
AS $function$
  SELECT EXISTS (
    SELECT 1 FROM public.buildings b
    JOIN public.building_types bt ON bt.key = b.building_type_key
    WHERE bt.category = 'road' AND b.status = 'active'
      AND b.player_id = p_player_id
      AND ((b.x = p_x - 1 AND b.y = p_y) OR (b.x = p_x + 1 AND b.y = p_y)
           OR (b.x = p_x AND b.y = p_y - 1) OR (b.x = p_x AND b.y = p_y + 1))
  ) OR EXISTS (
    SELECT 1 FROM public.map_tiles mt
    WHERE mt.terrain_type = 'highway'
      AND ((mt.x = p_x - 1 AND mt.y = p_y) OR (mt.x = p_x + 1 AND mt.y = p_y)
           OR (mt.x = p_x AND mt.y = p_y - 1) OR (mt.x = p_x AND mt.y = p_y + 1))
  );
$function$;


-- 3. find_nearest_unclaimed_resource: highway tiles are walkable at
--    cost 1 (same as roads), regardless of who owns them. This lets
--    walkers cross into another player's chunk via the highway without
--    breaking the rule that they can't walk over other players'
--    regular ground.
CREATE OR REPLACE FUNCTION public.find_nearest_unclaimed_resource(p_player_id uuid, p_ex integer, p_ey integer)
 RETURNS TABLE(target_x integer, target_y integer, path_length integer)
 LANGUAGE plpgsql
AS $function$
DECLARE
  v_player record;
  v_resource_key text;
  v_state jsonb := '{}'::jsonb;
  v_cur_key text;
  v_cur_dist integer;
  v_cur_x integer;
  v_cur_y integer;
  v_neighbor_x integer;
  v_neighbor_y integer;
  v_neighbor_key text;
  v_neighbor_cost integer;
  v_existing_dist integer;
  v_is_road boolean;
  v_is_highway boolean;
  v_neighbor_walkable boolean;
  v_is_resource boolean;
  v_dx int[] := ARRAY[-1, 1, 0, 0];
  v_dy int[] := ARRAY[0, 0, -1, 1];
  v_i integer;
  v_iters integer := 0;
  v_road_cost constant integer := 1;
  v_offroad_cost constant integer := 3;
BEGIN
  SELECT * INTO v_player FROM public.player_profiles WHERE id = p_player_id;
  IF NOT FOUND THEN RETURN; END IF;
  v_resource_key := v_player.industry_key;

  v_state := jsonb_build_object(
    p_ex || ',' || p_ey,
    jsonb_build_object('x', p_ex, 'y', p_ey, 'd', 0, 'v', false)
  );

  WHILE v_iters < 2000 LOOP
    v_iters := v_iters + 1;

    SELECT key, (value->>'x')::int, (value->>'y')::int, (value->>'d')::int
    INTO v_cur_key, v_cur_x, v_cur_y, v_cur_dist
    FROM jsonb_each(v_state)
    WHERE (value->>'v')::boolean = false
    ORDER BY (value->>'d')::int ASC
    LIMIT 1;

    IF v_cur_key IS NULL THEN RETURN; END IF;

    v_state := jsonb_set(v_state, ARRAY[v_cur_key, 'v'], 'true'::jsonb);

    IF NOT (v_cur_x = p_ex AND v_cur_y = p_ey) THEN
      SELECT EXISTS (
        SELECT 1 FROM public.map_tiles mt
        WHERE mt.x = v_cur_x AND mt.y = v_cur_y
          AND mt.owner_player_id = p_player_id
          AND mt.resource_node_key = v_resource_key
          AND mt.claimed_by_building_id IS NULL
          AND mt.occupied_building_id IS NULL
      ) INTO v_is_resource;
      IF v_is_resource THEN
        target_x := v_cur_x;
        target_y := v_cur_y;
        path_length := v_cur_dist;
        RETURN NEXT;
        RETURN;
      END IF;
    END IF;

    FOR v_i IN 1..4 LOOP
      v_neighbor_x := v_cur_x + v_dx[v_i];
      v_neighbor_y := v_cur_y + v_dy[v_i];
      v_neighbor_key := v_neighbor_x || ',' || v_neighbor_y;

      -- Highway tile (any owner): cost 1.
      SELECT EXISTS (
        SELECT 1 FROM public.map_tiles mt
        WHERE mt.x = v_neighbor_x AND mt.y = v_neighbor_y
          AND mt.terrain_type = 'highway'
      ) INTO v_is_highway;

      IF v_is_highway THEN
        v_neighbor_cost := v_road_cost;
        v_neighbor_walkable := true;
      ELSE
        -- Player-owned road building: cost 1.
        SELECT EXISTS (
          SELECT 1 FROM public.buildings b
          JOIN public.building_types bt ON bt.key = b.building_type_key
          WHERE b.x = v_neighbor_x AND b.y = v_neighbor_y
            AND bt.category = 'road' AND b.status = 'active'
            AND b.player_id = p_player_id
        ) INTO v_is_road;

        IF v_is_road THEN
          v_neighbor_cost := v_road_cost;
          v_neighbor_walkable := true;
        ELSE
          -- Off-road: must be owned by player AND no building on it.
          SELECT EXISTS (
            SELECT 1 FROM public.map_tiles mt
            WHERE mt.x = v_neighbor_x AND mt.y = v_neighbor_y
              AND mt.owner_player_id = p_player_id
              AND mt.occupied_building_id IS NULL
          ) INTO v_neighbor_walkable;
          v_neighbor_cost := v_offroad_cost;
        END IF;
      END IF;

      IF NOT v_neighbor_walkable THEN CONTINUE; END IF;

      IF v_state ? v_neighbor_key THEN
        IF NOT ((v_state->v_neighbor_key->>'v')::boolean) THEN
          v_existing_dist := (v_state->v_neighbor_key->>'d')::int;
          IF v_cur_dist + v_neighbor_cost < v_existing_dist THEN
            v_state := jsonb_set(
              v_state, ARRAY[v_neighbor_key, 'd'],
              to_jsonb(v_cur_dist + v_neighbor_cost)
            );
          END IF;
        END IF;
      ELSE
        v_state := v_state || jsonb_build_object(
          v_neighbor_key,
          jsonb_build_object(
            'x', v_neighbor_x, 'y', v_neighbor_y,
            'd', v_cur_dist + v_neighbor_cost, 'v', false
          )
        );
      END IF;
    END LOOP;
  END LOOP;
  RETURN;
END;
$function$;


-- 4. verify_extractor_path: same Dijkstra logic as
--    find_nearest_unclaimed_resource but verifies a specific target.
--    Update to also count highway as cost-1 walkable.
-- Keep the original RETURNS integer signature so recompute_extractor_paths'
-- existing `v_verify := public.verify_extractor_path(...)` assignment still
-- works.
DROP FUNCTION IF EXISTS public.verify_extractor_path(uuid, integer, integer, integer, integer);
CREATE FUNCTION public.verify_extractor_path(p_player_id uuid, p_ex integer, p_ey integer, p_tx integer, p_ty integer)
 RETURNS integer
 LANGUAGE plpgsql
AS $function$
DECLARE
  v_state jsonb := '{}'::jsonb;
  v_cur_key text;
  v_cur_dist integer;
  v_cur_x integer;
  v_cur_y integer;
  v_neighbor_x integer;
  v_neighbor_y integer;
  v_neighbor_key text;
  v_neighbor_cost integer;
  v_existing_dist integer;
  v_is_road boolean;
  v_is_highway boolean;
  v_neighbor_walkable boolean;
  v_dx int[] := ARRAY[-1, 1, 0, 0];
  v_dy int[] := ARRAY[0, 0, -1, 1];
  v_i integer;
  v_iters integer := 0;
  v_road_cost constant integer := 1;
  v_offroad_cost constant integer := 3;
BEGIN
  v_state := jsonb_build_object(
    p_ex || ',' || p_ey,
    jsonb_build_object('x', p_ex, 'y', p_ey, 'd', 0, 'v', false)
  );

  WHILE v_iters < 2000 LOOP
    v_iters := v_iters + 1;

    SELECT key, (value->>'x')::int, (value->>'y')::int, (value->>'d')::int
    INTO v_cur_key, v_cur_x, v_cur_y, v_cur_dist
    FROM jsonb_each(v_state)
    WHERE (value->>'v')::boolean = false
    ORDER BY (value->>'d')::int ASC
    LIMIT 1;

    IF v_cur_key IS NULL THEN RETURN NULL; END IF;
    IF v_cur_x = p_tx AND v_cur_y = p_ty THEN RETURN v_cur_dist; END IF;

    v_state := jsonb_set(v_state, ARRAY[v_cur_key, 'v'], 'true'::jsonb);

    FOR v_i IN 1..4 LOOP
      v_neighbor_x := v_cur_x + v_dx[v_i];
      v_neighbor_y := v_cur_y + v_dy[v_i];
      v_neighbor_key := v_neighbor_x || ',' || v_neighbor_y;

      SELECT EXISTS (
        SELECT 1 FROM public.map_tiles mt
        WHERE mt.x = v_neighbor_x AND mt.y = v_neighbor_y
          AND mt.terrain_type = 'highway'
      ) INTO v_is_highway;

      IF v_is_highway THEN
        v_neighbor_cost := v_road_cost;
        v_neighbor_walkable := true;
      ELSE
        SELECT EXISTS (
          SELECT 1 FROM public.buildings b
          JOIN public.building_types bt ON bt.key = b.building_type_key
          WHERE b.x = v_neighbor_x AND b.y = v_neighbor_y
            AND bt.category = 'road' AND b.status = 'active'
            AND b.player_id = p_player_id
        ) INTO v_is_road;

        IF v_is_road THEN
          v_neighbor_cost := v_road_cost;
          v_neighbor_walkable := true;
        ELSE
          SELECT EXISTS (
            SELECT 1 FROM public.map_tiles mt
            WHERE mt.x = v_neighbor_x AND mt.y = v_neighbor_y
              AND mt.owner_player_id = p_player_id
              AND (mt.occupied_building_id IS NULL OR (mt.x = p_tx AND mt.y = p_ty))
          ) INTO v_neighbor_walkable;
          v_neighbor_cost := v_offroad_cost;
        END IF;
      END IF;

      IF NOT v_neighbor_walkable THEN CONTINUE; END IF;

      IF v_state ? v_neighbor_key THEN
        IF NOT ((v_state->v_neighbor_key->>'v')::boolean) THEN
          v_existing_dist := (v_state->v_neighbor_key->>'d')::int;
          IF v_cur_dist + v_neighbor_cost < v_existing_dist THEN
            v_state := jsonb_set(
              v_state, ARRAY[v_neighbor_key, 'd'],
              to_jsonb(v_cur_dist + v_neighbor_cost)
            );
          END IF;
        END IF;
      ELSE
        v_state := v_state || jsonb_build_object(
          v_neighbor_key,
          jsonb_build_object(
            'x', v_neighbor_x, 'y', v_neighbor_y,
            'd', v_cur_dist + v_neighbor_cost, 'v', false
          )
        );
      END IF;
    END LOOP;
  END LOOP;
  RETURN NULL;
END;
$function$;


-- 5. Road placement: drop the "adjacent to home" seed rule, replace
--    with "adjacent to highway tile or your road." Same effective
--    behavior in the starter chunk (home sits on the highway
--    intersection) but extends naturally to expansion chunks where
--    the highway threads through every chunk. All other place_building
--    logic preserved verbatim.
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
BEGIN
  SELECT NULL::integer AS target_x,
         NULL::integer AS target_y,
         NULL::integer AS path_length
  INTO v_path;

  SELECT * INTO v_bt FROM public.building_types
  WHERE key = p_building_type_key AND is_active;
  IF NOT FOUND THEN RAISE EXCEPTION 'Unknown building type'; END IF;

  SELECT * INTO v_player FROM public.player_profiles WHERE id = v_uid;
  IF NOT FOUND THEN RAISE EXCEPTION 'Player not found'; END IF;

  IF v_bt.industry_key <> 'common' AND v_bt.industry_key <> v_player.industry_key THEN
    RAISE EXCEPTION 'You can only place buildings for your chosen industry';
  END IF;

  IF v_player.money < v_bt.build_cost THEN
    RAISE EXCEPTION 'Not enough money (need %, have %)',
      v_bt.build_cost, v_player.money;
  END IF;

  SELECT * INTO v_tile FROM public.map_tiles WHERE id = p_tile_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Tile not found'; END IF;

  IF v_tile.owner_player_id IS NULL THEN
    RAISE EXCEPTION 'Cannot build on wilderness — expand your district first';
  END IF;
  IF v_tile.owner_player_id <> v_uid THEN
    RAISE EXCEPTION 'Cannot build on another player''s district';
  END IF;

  IF NOT v_tile.buildable THEN RAISE EXCEPTION 'Tile is not buildable'; END IF;
  IF v_tile.occupied_building_id IS NOT NULL THEN
    RAISE EXCEPTION 'Tile already occupied';
  END IF;

  IF v_bt.category = 'road' THEN
    SELECT (
      EXISTS (
        SELECT 1 FROM public.map_tiles mt
        WHERE mt.terrain_type = 'highway'
          AND ((mt.x = v_tile.x - 1 AND mt.y = v_tile.y)
               OR (mt.x = v_tile.x + 1 AND mt.y = v_tile.y)
               OR (mt.x = v_tile.x AND mt.y = v_tile.y - 1)
               OR (mt.x = v_tile.x AND mt.y = v_tile.y + 1))
      )
      OR EXISTS (
        SELECT 1
        FROM public.buildings b2
        JOIN public.building_types bt2 ON bt2.key = b2.building_type_key
        WHERE bt2.category = 'road'
          AND b2.status = 'active'
          AND b2.player_id = v_uid
          AND (
            (b2.x = v_tile.x - 1 AND b2.y = v_tile.y)
            OR (b2.x = v_tile.x + 1 AND b2.y = v_tile.y)
            OR (b2.x = v_tile.x AND b2.y = v_tile.y - 1)
            OR (b2.x = v_tile.x AND b2.y = v_tile.y + 1)
          )
      )
    ) INTO v_road_connected;
    IF NOT v_road_connected THEN
      RAISE EXCEPTION 'Roads must connect to the highway or another of your roads';
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

  IF v_bt.category = 'extractor' THEN
    SELECT * INTO v_path
    FROM public.find_nearest_unclaimed_resource(v_uid, v_tile.x, v_tile.y);
    IF v_path.path_length IS NOT NULL THEN
      UPDATE public.buildings
      SET target_x = v_path.target_x,
          target_y = v_path.target_y,
          path_length = v_path.path_length
      WHERE id = v_building_id;
      UPDATE public.map_tiles
      SET claimed_by_building_id = v_building_id
      WHERE x = v_path.target_x AND y = v_path.target_y;
    END IF;
  END IF;

  IF v_bt.category = 'road' THEN
    PERFORM public.recompute_extractor_paths(v_uid);
  END IF;

  SELECT 5 + COALESCE(SUM(htc.workers), 0) INTO v_worker_supply
  FROM public.buildings b2
  JOIN public.building_types bt2 ON bt2.key = b2.building_type_key
  JOIN public.housing_tier_config htc ON htc.tier = b2.housing_tier
  WHERE b2.player_id = v_uid
    AND b2.status = 'active'
    AND bt2.category = 'housing'
    AND (NOT htc.needs_road OR public.has_road_access(v_uid, b2.x, b2.y));

  SELECT COALESCE(SUM(bt2.worker_cost), 0) INTO v_workers_needed
  FROM public.buildings b2
  JOIN public.building_types bt2 ON bt2.key = b2.building_type_key
  WHERE b2.player_id = v_uid
    AND b2.status = 'active'
    AND (
      bt2.category = 'extractor'
      OR (bt2.category = 'processor' AND public.has_road_access(v_uid, b2.x, b2.y))
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
    'labor_shortage', v_workers_needed > v_worker_supply,
    'extractor_target', CASE WHEN v_path.path_length IS NOT NULL
      THEN json_build_object('x', v_path.target_x, 'y', v_path.target_y, 'path_length', v_path.path_length)
      ELSE NULL END
  );
END;
$function$;

-- Re-grant verify_extractor_path: DROP/CREATE wipes grants.
GRANT EXECUTE ON FUNCTION public.verify_extractor_path(uuid, integer, integer, integer, integer) TO authenticated;
