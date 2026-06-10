-- Curving highways. The highway entry/exit points stay fixed so chunks
-- connect across edges:
--   horizontal: enters at (0, 7), exits at (14, 7)
--   vertical:   enters at (7, 0), exits at (7, 14)
-- Inside the chunk, each path is allowed to drift up to ~3 tiles off
-- the centerline before being forced back to the edge target. Drift is
-- always orthogonal so the resulting tile sequence forms a connected
-- path of tiles for walker pathing.
--
-- Apply: psql "$DB_URL" -f curving_highways.sql

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
  -- Highway curve generation
  v_cur_off integer;     -- current perpendicular offset from centerline
  v_axis_pos integer;    -- progress along the highway (0..14)
  v_steps_left integer;  -- east/south steps remaining
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

  -- Resource clusters via random walk.
  FOR v_cluster_idx IN 1..v_cluster_count LOOP
    v_seed_dx := floor(random() * 15)::integer;
    v_seed_dy := floor(random() * 15)::integer;
    v_walk_steps := 6 + floor(random() * 10)::integer;
    v_curr_dx := v_seed_dx;
    v_curr_dy := v_seed_dy;
    UPDATE public.map_tiles
    SET resource_node_key = v_resource_key
    WHERE x = v_x_start + v_curr_dx AND y = v_y_start + v_curr_dy
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
      WHERE x = v_x_start + v_new_dx AND y = v_y_start + v_new_dy
        AND resource_node_key IS NULL;
      v_curr_dx := v_new_dx;
      v_curr_dy := v_new_dy;
    END LOOP;
  END LOOP;

  -- ── Curving horizontal highway ──────────────────────────
  -- Walks from (0, 7) to (14, 7). At each axis position the path can
  -- drift north/south by 1, but only if doing so leaves enough room to
  -- correct back to y=7 before reaching x=14. Drift never exceeds ±3.
  v_axis_pos := 0;
  v_cur_off := 0;
  PERFORM public.mark_highway_tile(p_player_id, v_x_start + 0, v_y_start + 7);
  WHILE v_axis_pos < 14 LOOP
    v_steps_left := 14 - v_axis_pos;
    -- Can only drift if we still have slack to correct: steps_left must
    -- exceed |cur_off| + 1 (the +1 for taking a drift step right now).
    v_can_drift := abs(v_cur_off) + 1 < v_steps_left;
    IF v_can_drift AND random() < 0.35 THEN
      -- Drift north or south, biased back toward the centerline once
      -- we're already off-axis.
      IF v_cur_off > 0 THEN
        v_drift_dir := CASE WHEN random() < 0.65 THEN -1 ELSE 1 END;
      ELSIF v_cur_off < 0 THEN
        v_drift_dir := CASE WHEN random() < 0.65 THEN 1 ELSE -1 END;
      ELSE
        v_drift_dir := CASE WHEN random() < 0.5 THEN 1 ELSE -1 END;
      END IF;
      -- Clamp drift to ±3
      IF abs(v_cur_off + v_drift_dir) > 3 THEN
        v_drift_dir := -v_drift_dir;
      END IF;
      v_cur_off := v_cur_off + v_drift_dir;
      PERFORM public.mark_highway_tile(p_player_id,
        v_x_start + v_axis_pos, v_y_start + 7 + v_cur_off);
    ELSE
      -- If forced to correct: take the y-correction step first (only
      -- happens when can_drift is false).
      IF NOT v_can_drift AND v_cur_off != 0 THEN
        v_cur_off := v_cur_off - sign(v_cur_off);
        PERFORM public.mark_highway_tile(p_player_id,
          v_x_start + v_axis_pos, v_y_start + 7 + v_cur_off);
      ELSE
        -- Step east
        v_axis_pos := v_axis_pos + 1;
        PERFORM public.mark_highway_tile(p_player_id,
          v_x_start + v_axis_pos, v_y_start + 7 + v_cur_off);
      END IF;
    END IF;
  END LOOP;
  -- v_axis_pos = 14 now. Force-correct any leftover y-offset to land on
  -- (14, 7) for the cross-chunk match.
  WHILE v_cur_off != 0 LOOP
    v_cur_off := v_cur_off - sign(v_cur_off);
    PERFORM public.mark_highway_tile(p_player_id,
      v_x_start + 14, v_y_start + 7 + v_cur_off);
  END LOOP;

  -- ── Curving vertical highway ────────────────────────────
  -- Same algorithm transposed: walks from (7, 0) to (7, 14) with x-drift.
  v_axis_pos := 0;
  v_cur_off := 0;
  PERFORM public.mark_highway_tile(p_player_id, v_x_start + 7, v_y_start + 0);
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
      IF abs(v_cur_off + v_drift_dir) > 3 THEN
        v_drift_dir := -v_drift_dir;
      END IF;
      v_cur_off := v_cur_off + v_drift_dir;
      PERFORM public.mark_highway_tile(p_player_id,
        v_x_start + 7 + v_cur_off, v_y_start + v_axis_pos);
    ELSE
      IF NOT v_can_drift AND v_cur_off != 0 THEN
        v_cur_off := v_cur_off - sign(v_cur_off);
        PERFORM public.mark_highway_tile(p_player_id,
          v_x_start + 7 + v_cur_off, v_y_start + v_axis_pos);
      ELSE
        v_axis_pos := v_axis_pos + 1;
        PERFORM public.mark_highway_tile(p_player_id,
          v_x_start + 7 + v_cur_off, v_y_start + v_axis_pos);
      END IF;
    END IF;
  END LOOP;
  WHILE v_cur_off != 0 LOOP
    v_cur_off := v_cur_off - sign(v_cur_off);
    PERFORM public.mark_highway_tile(p_player_id,
      v_x_start + 7 + v_cur_off, v_y_start + 14);
  END LOOP;

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


-- Helper: stamp a single highway tile on an owned ground tile. Idempotent.
-- Resource clusters that happened to seed onto the path get cleared
-- because highway tiles can't carry a resource.
CREATE OR REPLACE FUNCTION public.mark_highway_tile(
  p_player_id uuid, p_x integer, p_y integer
) RETURNS void
LANGUAGE sql
AS $$
  UPDATE public.map_tiles
  SET terrain_type = 'highway',
      buildable = false,
      resource_node_key = NULL
  WHERE owner_player_id = p_player_id
    AND x = p_x AND y = p_y;
$$;
