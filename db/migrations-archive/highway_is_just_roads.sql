-- Replace the terrain='highway' concept with actual pre-placed road
-- buildings owned by the chunk's player. From the game's perspective,
-- highways are no longer special — they're just roads the system put
-- there at chunk allocation. Demolish them via the regular building
-- inspector, walker pathing uses them via the regular road logic, etc.
--
-- Apply: psql "$DB_URL" -f highway_is_just_roads.sql
-- Existing chunks get migrated below: any tile with terrain='highway'
-- becomes a ground tile with a player-owned road building on it.
--
-- Replaces: highway_and_remove_hq.sql, curving_highways.sql,
-- demolish_highway.sql (which all introduced/touched the highway
-- terrain concept).

-- ── 1. Migrate any existing highway tiles to road buildings ────
-- For each tile owned by a player with terrain='highway', clear the
-- resource_node_key (so the trigger passes), insert a road building
-- owned by that player, point the tile at it, and flip the tile to
-- ground/buildable=false (it's now occupied by a road).
DO $$
DECLARE
  v_t record;
  v_bid uuid;
BEGIN
  FOR v_t IN
    SELECT id, x, y, owner_player_id FROM public.map_tiles
    WHERE terrain_type = 'highway' AND owner_player_id IS NOT NULL
  LOOP
    UPDATE public.map_tiles SET resource_node_key = NULL WHERE id = v_t.id;
    INSERT INTO public.buildings (player_id, building_type_key, tile_id, x, y)
    VALUES (v_t.owner_player_id, 'road', v_t.id, v_t.x, v_t.y)
    ON CONFLICT (tile_id) DO NOTHING
    RETURNING id INTO v_bid;
    UPDATE public.map_tiles
    SET terrain_type = 'ground', buildable = true, occupied_building_id = v_bid
    WHERE id = v_t.id;
  END LOOP;
END $$;

-- ── 2. has_road_access reverts: roads only, no highway terrain check ────
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
  );
$function$;

-- ── 3. find_nearest_unclaimed_resource reverts: roads only ────
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
    ORDER BY (value->>'d')::int ASC LIMIT 1;
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
        target_x := v_cur_x; target_y := v_cur_y; path_length := v_cur_dist;
        RETURN NEXT; RETURN;
      END IF;
    END IF;
    FOR v_i IN 1..4 LOOP
      v_neighbor_x := v_cur_x + v_dx[v_i];
      v_neighbor_y := v_cur_y + v_dy[v_i];
      v_neighbor_key := v_neighbor_x || ',' || v_neighbor_y;
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
            AND mt.occupied_building_id IS NULL
        ) INTO v_neighbor_walkable;
        v_neighbor_cost := v_offroad_cost;
      END IF;
      IF NOT v_neighbor_walkable THEN CONTINUE; END IF;
      IF v_state ? v_neighbor_key THEN
        IF NOT ((v_state->v_neighbor_key->>'v')::boolean) THEN
          v_existing_dist := (v_state->v_neighbor_key->>'d')::int;
          IF v_cur_dist + v_neighbor_cost < v_existing_dist THEN
            v_state := jsonb_set(v_state, ARRAY[v_neighbor_key, 'd'],
              to_jsonb(v_cur_dist + v_neighbor_cost));
          END IF;
        END IF;
      ELSE
        v_state := v_state || jsonb_build_object(
          v_neighbor_key,
          jsonb_build_object('x', v_neighbor_x, 'y', v_neighbor_y,
            'd', v_cur_dist + v_neighbor_cost, 'v', false)
        );
      END IF;
    END LOOP;
  END LOOP;
  RETURN;
END;
$function$;

-- ── 4. verify_extractor_path reverts ────
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
    ORDER BY (value->>'d')::int ASC LIMIT 1;
    IF v_cur_key IS NULL THEN RETURN NULL; END IF;
    IF v_cur_x = p_tx AND v_cur_y = p_ty THEN RETURN v_cur_dist; END IF;
    v_state := jsonb_set(v_state, ARRAY[v_cur_key, 'v'], 'true'::jsonb);
    FOR v_i IN 1..4 LOOP
      v_neighbor_x := v_cur_x + v_dx[v_i];
      v_neighbor_y := v_cur_y + v_dy[v_i];
      v_neighbor_key := v_neighbor_x || ',' || v_neighbor_y;
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
      IF NOT v_neighbor_walkable THEN CONTINUE; END IF;
      IF v_state ? v_neighbor_key THEN
        IF NOT ((v_state->v_neighbor_key->>'v')::boolean) THEN
          v_existing_dist := (v_state->v_neighbor_key->>'d')::int;
          IF v_cur_dist + v_neighbor_cost < v_existing_dist THEN
            v_state := jsonb_set(v_state, ARRAY[v_neighbor_key, 'd'],
              to_jsonb(v_cur_dist + v_neighbor_cost));
          END IF;
        END IF;
      ELSE
        v_state := v_state || jsonb_build_object(
          v_neighbor_key,
          jsonb_build_object('x', v_neighbor_x, 'y', v_neighbor_y,
            'd', v_cur_dist + v_neighbor_cost, 'v', false)
        );
      END IF;
    END LOOP;
  END LOOP;
  RETURN NULL;
END;
$function$;
GRANT EXECUTE ON FUNCTION public.verify_extractor_path(uuid, integer, integer, integer, integer) TO authenticated;

-- ── 5. allocate_district_chunk: pre-place roads on the curving path ────
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
  v_axis_pos integer;
  v_cur_off integer;
  v_steps_left integer;
  v_can_drift boolean;
  v_drift_dir integer;
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

  -- Lay down 225 ground tiles.
  FOR v_dx IN 0..14 LOOP
    FOR v_dy IN 0..14 LOOP
      INSERT INTO public.map_tiles (
        x, y, terrain_type, resource_node_key, buildable, owner_player_id
      ) VALUES (
        v_x_start + v_dx, v_y_start + v_dy,
        'ground', NULL, true, p_player_id
      )
      ON CONFLICT (x, y) DO UPDATE SET
        owner_player_id = p_player_id,
        terrain_type = 'ground',
        buildable = true;
    END LOOP;
  END LOOP;

  -- Resource clusters via random walk (avoiding already-placed tiles).
  FOR v_cluster_idx IN 1..v_cluster_count LOOP
    v_seed_dx := floor(random() * 15)::integer;
    v_seed_dy := floor(random() * 15)::integer;
    v_walk_steps := 6 + floor(random() * 10)::integer;
    v_curr_dx := v_seed_dx; v_curr_dy := v_seed_dy;
    UPDATE public.map_tiles
    SET resource_node_key = v_resource_key
    WHERE x = v_x_start + v_curr_dx AND y = v_y_start + v_curr_dy
      AND resource_node_key IS NULL;
    FOR v_step_idx IN 1..v_walk_steps LOOP
      v_dir := floor(random() * 4)::integer;
      v_new_dx := v_curr_dx + CASE v_dir WHEN 0 THEN 1 WHEN 1 THEN -1 ELSE 0 END;
      v_new_dy := v_curr_dy + CASE v_dir WHEN 2 THEN 1 WHEN 3 THEN -1 ELSE 0 END;
      IF v_new_dx < 0 OR v_new_dx > 14 OR v_new_dy < 0 OR v_new_dy > 14 THEN
        v_curr_dx := v_seed_dx; v_curr_dy := v_seed_dy; CONTINUE;
      END IF;
      UPDATE public.map_tiles
      SET resource_node_key = v_resource_key
      WHERE x = v_x_start + v_new_dx AND y = v_y_start + v_new_dy
        AND resource_node_key IS NULL;
      v_curr_dx := v_new_dx; v_curr_dy := v_new_dy;
    END LOOP;
  END LOOP;

  -- Curving horizontal pre-road from (0,7) to (14,7).
  v_axis_pos := 0; v_cur_off := 0;
  PERFORM public.place_pre_road(p_player_id, v_x_start + 0, v_y_start + 7);
  WHILE v_axis_pos < 14 LOOP
    v_steps_left := 14 - v_axis_pos;
    v_can_drift := abs(v_cur_off) + 1 < v_steps_left;
    IF v_can_drift AND random() < 0.35 THEN
      IF v_cur_off > 0 THEN
        v_drift_dir := CASE WHEN random() < 0.65 THEN -1 ELSE 1 END;
      ELSIF v_cur_off < 0 THEN
        v_drift_dir := CASE WHEN random() < 0.65 THEN 1 ELSE -1 END;
      ELSE
        v_drift_dir := CASE WHEN random() < 0.5 THEN 1 ELSE -1 END;
      END IF;
      IF abs(v_cur_off + v_drift_dir) > 3 THEN v_drift_dir := -v_drift_dir; END IF;
      v_cur_off := v_cur_off + v_drift_dir;
      PERFORM public.place_pre_road(p_player_id,
        v_x_start + v_axis_pos, v_y_start + 7 + v_cur_off);
    ELSE
      IF NOT v_can_drift AND v_cur_off != 0 THEN
        v_cur_off := v_cur_off - sign(v_cur_off);
        PERFORM public.place_pre_road(p_player_id,
          v_x_start + v_axis_pos, v_y_start + 7 + v_cur_off);
      ELSE
        v_axis_pos := v_axis_pos + 1;
        PERFORM public.place_pre_road(p_player_id,
          v_x_start + v_axis_pos, v_y_start + 7 + v_cur_off);
      END IF;
    END IF;
  END LOOP;
  WHILE v_cur_off != 0 LOOP
    v_cur_off := v_cur_off - sign(v_cur_off);
    PERFORM public.place_pre_road(p_player_id,
      v_x_start + 14, v_y_start + 7 + v_cur_off);
  END LOOP;

  -- Curving vertical pre-road from (7,0) to (7,14).
  v_axis_pos := 0; v_cur_off := 0;
  PERFORM public.place_pre_road(p_player_id, v_x_start + 7, v_y_start + 0);
  WHILE v_axis_pos < 14 LOOP
    v_steps_left := 14 - v_axis_pos;
    v_can_drift := abs(v_cur_off) + 1 < v_steps_left;
    IF v_can_drift AND random() < 0.35 THEN
      IF v_cur_off > 0 THEN
        v_drift_dir := CASE WHEN random() < 0.65 THEN -1 ELSE 1 END;
      ELSIF v_cur_off < 0 THEN
        v_drift_dir := CASE WHEN random() < 0.65 THEN 1 ELSE -1 END;
      ELSE
        v_drift_dir := CASE WHEN random() < 0.5 THEN 1 ELSE -1 END;
      END IF;
      IF abs(v_cur_off + v_drift_dir) > 3 THEN v_drift_dir := -v_drift_dir; END IF;
      v_cur_off := v_cur_off + v_drift_dir;
      PERFORM public.place_pre_road(p_player_id,
        v_x_start + 7 + v_cur_off, v_y_start + v_axis_pos);
    ELSE
      IF NOT v_can_drift AND v_cur_off != 0 THEN
        v_cur_off := v_cur_off - sign(v_cur_off);
        PERFORM public.place_pre_road(p_player_id,
          v_x_start + 7 + v_cur_off, v_y_start + v_axis_pos);
      ELSE
        v_axis_pos := v_axis_pos + 1;
        PERFORM public.place_pre_road(p_player_id,
          v_x_start + 7 + v_cur_off, v_y_start + v_axis_pos);
      END IF;
    END IF;
  END LOOP;
  WHILE v_cur_off != 0 LOOP
    v_cur_off := v_cur_off - sign(v_cur_off);
    PERFORM public.place_pre_road(p_player_id,
      v_x_start + 7 + v_cur_off, v_y_start + 14);
  END LOOP;

  IF v_is_first_chunk THEN
    UPDATE public.player_profiles
    SET home_x = v_x_start + 7, home_y = v_y_start + 7
    WHERE id = p_player_id;
  END IF;

  INSERT INTO public.district_chunks (chunk_x, chunk_y, owner_player_id)
  VALUES (p_chunk_x, p_chunk_y, p_player_id);
  UPDATE public.player_profiles SET chunks_owned = chunks_owned + 1
  WHERE id = p_player_id;
  SELECT COUNT(*) INTO v_resource_count
  FROM public.map_tiles
  WHERE owner_player_id = p_player_id
    AND x >= v_x_start AND x < v_x_start + 15
    AND y >= v_y_start AND y < v_y_start + 15
    AND resource_node_key IS NOT NULL;
  RETURN json_build_object(
    'chunk_x', p_chunk_x, 'chunk_y', p_chunk_y,
    'tile_x_start', v_x_start, 'tile_y_start', v_y_start,
    'resource_tiles', v_resource_count,
    'is_first_chunk', v_is_first_chunk
  );
END;
$function$;

-- ── 6. place_pre_road helper: insert a system-pre-placed road ────
CREATE OR REPLACE FUNCTION public.place_pre_road(
  p_player_id uuid, p_x integer, p_y integer
) RETURNS void
LANGUAGE plpgsql
AS $function$
DECLARE
  v_tile record;
  v_bid uuid;
BEGIN
  SELECT * INTO v_tile FROM public.map_tiles
  WHERE x = p_x AND y = p_y AND owner_player_id = p_player_id;
  IF NOT FOUND THEN RETURN; END IF;
  IF v_tile.occupied_building_id IS NOT NULL THEN RETURN; END IF;
  -- Clear any resource cluster that landed on the path before inserting
  -- the road (the reject_build_on_resource trigger would otherwise block).
  IF v_tile.resource_node_key IS NOT NULL THEN
    UPDATE public.map_tiles SET resource_node_key = NULL WHERE id = v_tile.id;
  END IF;
  INSERT INTO public.buildings (player_id, building_type_key, tile_id, x, y)
  VALUES (p_player_id, 'road', v_tile.id, p_x, p_y)
  RETURNING id INTO v_bid;
  UPDATE public.map_tiles SET occupied_building_id = v_bid WHERE id = v_tile.id;
END;
$function$;

-- ── 7. place_building (road category) reverts: roads connect to roads ────
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
  SELECT NULL::integer AS target_x, NULL::integer AS target_y, NULL::integer AS path_length
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
    RAISE EXCEPTION 'Not enough money (need %, have %)', v_bt.build_cost, v_player.money;
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
    SELECT EXISTS (
      SELECT 1
      FROM public.buildings b2
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

  UPDATE public.map_tiles SET occupied_building_id = v_building_id WHERE id = p_tile_id;

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

  SELECT 5 + COALESCE(SUM(htc.workers), 0) INTO v_worker_supply
  FROM public.buildings b2
  JOIN public.building_types bt2 ON bt2.key = b2.building_type_key
  JOIN public.housing_tier_config htc ON htc.tier = b2.housing_tier
  WHERE b2.player_id = v_uid AND b2.status = 'active' AND bt2.category = 'housing'
    AND (NOT htc.needs_road OR public.has_road_access(v_uid, b2.x, b2.y));
  SELECT COALESCE(SUM(bt2.worker_cost), 0) INTO v_workers_needed
  FROM public.buildings b2
  JOIN public.building_types bt2 ON bt2.key = b2.building_type_key
  WHERE b2.player_id = v_uid AND b2.status = 'active'
    AND (bt2.category = 'extractor'
         OR (bt2.category = 'processor' AND public.has_road_access(v_uid, b2.x, b2.y)));

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
$function$;

-- ── 8. Drop the highway-specific helpers; no longer needed ────
DROP FUNCTION IF EXISTS public.demolish_highway_tile(uuid);
DROP FUNCTION IF EXISTS public.mark_highway_tile(uuid, integer, integer);

-- ── 9. reset_player(uuid): wipe all the player's game state in one
--      idempotent call. Atlas uses this for testing; future work could
--      expose it as an in-app "Restart" button. Doesn't touch auth.users
--      so the player can re-register with the same email.
CREATE OR REPLACE FUNCTION public.reset_player(p_player_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
BEGIN
  DELETE FROM public.buildings WHERE player_id = p_player_id;
  DELETE FROM public.map_tiles WHERE owner_player_id = p_player_id;
  DELETE FROM public.district_chunks WHERE owner_player_id = p_player_id;
  DELETE FROM public.inventories WHERE player_id = p_player_id;
  DELETE FROM public.player_profiles WHERE id = p_player_id;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.reset_player(uuid) TO authenticated;
