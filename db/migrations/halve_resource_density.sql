-- ====================================================================
-- Halve resource density on newly-allocated chunks
-- ====================================================================
-- Atlas: "we should probably have about half the resources we have now.
--         that shouldn't be a concrete number but just fewer in general."
--
-- _seed_resource_clusters does a random walk; cluster_count picks the
-- number of seed points and (min_walk, max_walk) bracket the walk
-- length per cluster. The walk drops resource_node_key on each step
-- when the tile is empty, so total tile count ≈ cluster_count × mean(walk).
--
-- Before: industry 4 × U(6, 15) ≈ 42 tiles | food 2 × U(4, 8) ≈ 12 tiles
-- After:  industry 4 × U(3, 8)  ≈ 22 tiles | food 2 × U(2, 4) ≈ 6 tiles
--
-- Halves the tile count while preserving cluster count (still 4 patches
-- of industry / 2 patches of food per chunk — just smaller). Random
-- walk preserves the "patches feel discovered, not gridded" vibe.
--
-- Existing chunks are NOT touched. Players keep what they have.

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
  v_resource_count integer;
  v_food_tile_key text;
  v_is_first_chunk boolean;
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

  v_is_first_chunk := (v_player.chunks_owned = 0);
  v_food_tile_key := CASE v_player.industry_key
    WHEN 'timber' THEN 'orchard_grove'
    WHEN 'stone'  THEN 'pond'
    WHEN 'clay'   THEN 'garden_plot'
    WHEN 'iron'   THEN 'farmland'
  END;

  -- Lay down all 225 ground tiles. Critically: also wipe any leftover
  -- resource_node_key from a previous owner so the chunk reseeds clean.
  FOR v_dx IN 0..14 LOOP
    FOR v_dy IN 0..14 LOOP
      INSERT INTO public.map_tiles (
        x, y, terrain_type, resource_node_key, buildable, owner_player_id
      ) VALUES (
        v_x_start + v_dx, v_y_start + v_dy, 'ground', NULL, true, p_player_id
      )
      ON CONFLICT (x, y) DO UPDATE SET
        owner_player_id = p_player_id,
        terrain_type = 'ground',
        buildable = true,
        resource_node_key = NULL,
        claimed_by_building_id = NULL;
    END LOOP;
  END LOOP;

  -- Ore + food cluster seeding. Walks halved 2026-05-06 — see header.
  PERFORM public._seed_resource_clusters(
    p_chunk_x, p_chunk_y, v_player.industry_key, 4, 3, 8);
  IF v_food_tile_key IS NOT NULL THEN
    PERFORM public._seed_resource_clusters(
      p_chunk_x, p_chunk_y, v_food_tile_key, 2, 2, 4);
  END IF;

  -- ── Curving horizontal highway: (0,7) → (14,7) ──
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

  -- ── Curving vertical highway: (7,0) → (7,14) ──
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
    UPDATE public.map_tiles
    SET terrain_type = 'city_center', buildable = false, resource_node_key = NULL
    WHERE x = v_x_start + 7 AND y = v_y_start + 7;
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
