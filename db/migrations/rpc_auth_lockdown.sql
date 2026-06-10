-- ─────────────────────────────────────────────────────────────────────
-- 🚨 SECURITY: lock down RPCs that accept p_player_id without
-- checking auth.uid().
--
-- Found during 2026-05-09 audit:
--   reset_player(p_player_id)         — ANY authenticated user could
--                                       wipe ANY other player. Total
--                                       account takeover/deletion.
--   allocate_district_chunk(p, ...)   — could allocate chunks to
--                                       another player.
--   place_pre_road(p, x, y)            — place a road in another
--                                       player's district.
--   recompute_extractor_paths(p)       — recompute another player's
--                                       paths. Read-only side effect
--                                       on rows owned by p_player_id.
--
-- Fix: prepend `IF p_player_id <> auth.uid() THEN RAISE`. All four
-- ARE called internally with the original caller's id, so existing
-- internal call sites continue to work. Only direct misuse via
-- PostgREST is blocked.
--
-- For allocate_district_chunk + recompute_extractor_paths, we
-- preserve the existing body verbatim — these are large functions
-- and rewriting risks regressing behavior.
-- ─────────────────────────────────────────────────────────────────────


-- (1) reset_player — small body; rewrite cleanly.
CREATE OR REPLACE FUNCTION public.reset_player(p_player_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'auth required';
  END IF;
  IF p_player_id <> auth.uid() THEN
    RAISE EXCEPTION 'not authorized to reset another player';
  END IF;

  DELETE FROM public.buildings
   WHERE EXISTS (
     SELECT 1 FROM public.district_chunks dc
      WHERE dc.owner_player_id = p_player_id
        AND buildings.x BETWEEN dc.chunk_x * 15 AND dc.chunk_x * 15 + 14
        AND buildings.y BETWEEN dc.chunk_y * 15 AND dc.chunk_y * 15 + 14
   );
  DELETE FROM public.buildings WHERE player_id = p_player_id;
  DELETE FROM public.map_tiles
   WHERE EXISTS (
     SELECT 1 FROM public.district_chunks dc
      WHERE dc.owner_player_id = p_player_id
        AND map_tiles.x BETWEEN dc.chunk_x * 15 AND dc.chunk_x * 15 + 14
        AND map_tiles.y BETWEEN dc.chunk_y * 15 AND dc.chunk_y * 15 + 14
   );
  DELETE FROM public.map_tiles WHERE owner_player_id = p_player_id;
  DELETE FROM public.district_chunks WHERE owner_player_id = p_player_id;
  DELETE FROM public.inventories WHERE player_id = p_player_id;
  DELETE FROM public.player_profiles WHERE id = p_player_id;
END;
$function$;


-- (2) place_pre_road — short body; rewrite.
CREATE OR REPLACE FUNCTION public.place_pre_road(p_player_id uuid, p_x integer, p_y integer)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
DECLARE
  v_tile record;
  v_bid uuid;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'auth required';
  END IF;
  IF p_player_id <> auth.uid() THEN
    RAISE EXCEPTION 'not authorized to place a road for another player';
  END IF;

  SELECT * INTO v_tile FROM public.map_tiles
  WHERE x = p_x AND y = p_y AND owner_player_id = p_player_id;
  IF NOT FOUND THEN RETURN; END IF;
  IF v_tile.occupied_building_id IS NOT NULL THEN RETURN; END IF;
  IF v_tile.resource_node_key IS NOT NULL THEN
    UPDATE public.map_tiles SET resource_node_key = NULL WHERE id = v_tile.id;
  END IF;
  INSERT INTO public.buildings (player_id, building_type_key, tile_id, x, y)
  VALUES (p_player_id, 'road', v_tile.id, p_x, p_y)
  RETURNING id INTO v_bid;
  UPDATE public.map_tiles SET occupied_building_id = v_bid WHERE id = v_tile.id;
END;
$function$;


-- (auto-patched) allocate_district_chunk
CREATE OR REPLACE FUNCTION public.allocate_district_chunk(p_player_id uuid, p_chunk_x integer, p_chunk_y integer)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
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
  v_industry_clusters integer;
  v_industry_walk_min integer;
  v_industry_walk_max integer;
  v_food_clusters integer;
  v_food_walk_min integer;
  v_food_walk_max integer;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'auth required';
  END IF;
  IF p_player_id <> auth.uid() THEN
    RAISE EXCEPTION 'not authorized to call allocate_district_chunk for another player';
  END IF;
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

  -- Lay down all 225 ground tiles (clean slate on every allocation).
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

  -- Resource density depends on whether this is the player's first
  -- chunk or an expansion. Starter is a meaningful but limited
  -- production base; expansions are mostly land for buildings, not a
  -- fresh resource jackpot.
  IF v_is_first_chunk THEN
    v_industry_clusters := 2;       -- was 4
    v_industry_walk_min := 2;       -- was 3
    v_industry_walk_max := 5;       -- was 8 → ~7 tiles total (was ~22)
    v_food_clusters := 1;           -- was 2
    v_food_walk_min := 2;           -- was 2
    v_food_walk_max := 3;           -- was 4 → ~3 tiles total (was ~6)
  ELSE
    v_industry_clusters := 1;       -- minimal expansion ore
    v_industry_walk_min := 2;
    v_industry_walk_max := 4;       -- ~3 tiles total
    v_food_clusters := 1;
    v_food_walk_min := 1;
    v_food_walk_max := 2;           -- ~1.5 tiles, often just one
  END IF;

  PERFORM public._seed_resource_clusters(
    p_chunk_x, p_chunk_y, v_player.industry_key,
    v_industry_clusters, v_industry_walk_min, v_industry_walk_max);
  IF v_food_tile_key IS NOT NULL THEN
    PERFORM public._seed_resource_clusters(
      p_chunk_x, p_chunk_y, v_food_tile_key,
      v_food_clusters, v_food_walk_min, v_food_walk_max);
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

  -- Record the chunk allocation + bump player's count.
  INSERT INTO public.district_chunks (chunk_x, chunk_y, owner_player_id)
  VALUES (p_chunk_x, p_chunk_y, p_player_id);

  UPDATE public.player_profiles
  SET chunks_owned = chunks_owned + 1,
      home_x = COALESCE(home_x, v_x_start + 7),
      home_y = COALESCE(home_y, v_y_start + 7)
  WHERE id = p_player_id;

  RETURN json_build_object(
    'chunk_x', p_chunk_x,
    'chunk_y', p_chunk_y,
    'tiles_created', 225
  );
END;
$function$
;


-- (auto-patched) recompute_extractor_paths
CREATE OR REPLACE FUNCTION public.recompute_extractor_paths(p_player_id uuid)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  v_extractor record;
  v_path record;
  v_verify integer;
  v_recomputed integer := 0;
  v_idle integer := 0;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'auth required';
  END IF;
  IF p_player_id <> auth.uid() THEN
    RAISE EXCEPTION 'not authorized to call recompute_extractor_paths for another player';
  END IF;
  FOR v_extractor IN
    SELECT b.id, b.x, b.y, b.target_x, b.target_y
    FROM public.buildings b
    JOIN public.building_types bt ON bt.key = b.building_type_key
    WHERE b.player_id = p_player_id
      AND bt.category = 'extractor'
      AND b.status = 'active'
  LOOP
    IF v_extractor.target_x IS NOT NULL THEN
      -- Verify current path
      v_verify := public.verify_extractor_path(
        p_player_id, v_extractor.x, v_extractor.y,
        v_extractor.target_x, v_extractor.target_y
      );
      IF v_verify IS NOT NULL THEN
        -- Path still valid; refresh path_length in case roads were optimized
        UPDATE public.buildings SET path_length = v_verify WHERE id = v_extractor.id;
        v_recomputed := v_recomputed + 1;
        CONTINUE;
      END IF;
      -- Path broken — release claim
      UPDATE public.map_tiles
      SET claimed_by_building_id = NULL
      WHERE claimed_by_building_id = v_extractor.id;
      UPDATE public.buildings
      SET target_x = NULL, target_y = NULL, path_length = NULL
      WHERE id = v_extractor.id;
    END IF;

    -- Try to find a new target
    SELECT * INTO v_path
    FROM public.find_nearest_unclaimed_resource(
      p_player_id, v_extractor.x, v_extractor.y
    );
    IF v_path IS NOT NULL AND v_path.path_length IS NOT NULL THEN
      UPDATE public.buildings
      SET target_x = v_path.target_x,
          target_y = v_path.target_y,
          path_length = v_path.path_length
      WHERE id = v_extractor.id;
      UPDATE public.map_tiles
      SET claimed_by_building_id = v_extractor.id
      WHERE x = v_path.target_x AND y = v_path.target_y;
      v_recomputed := v_recomputed + 1;
    ELSE
      v_idle := v_idle + 1;
    END IF;
  END LOOP;

  RETURN json_build_object('recomputed', v_recomputed, 'idle', v_idle);
END;
$function$
;
