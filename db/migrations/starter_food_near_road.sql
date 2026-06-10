-- ─────────────────────────────────────────────────────────────────────
-- Starter parcel: guarantee one food tile is adjacent to a road.
-- (2026-05-09)
--
-- Atlas: "when a player starts, they should always have a farm that's
-- near a road. that way they'll at least have a way to get food without
-- having to build a road out to the farm."
--
-- The cluster random walk doesn't guarantee road-adjacency. New players
-- who happen to roll a far-corner food cluster face an early-game
-- friction wall: build a long road to your one food source. Fix:
-- after road + cluster seeding, ensure at least one food tile in the
-- first chunk is one step from a road. If none is, stamp the food key
-- on an empty road-adjacent tile.
--
-- First-chunk only. Existing parcels are not retroactively touched.
-- ─────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public._guarantee_food_near_road(
  p_chunk_x integer,
  p_chunk_y integer,
  p_food_key text
)
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
  v_x_start integer := p_chunk_x * 15;
  v_y_start integer := p_chunk_y * 15;
  v_already_road_adjacent boolean;
  v_pick_x integer;
  v_pick_y integer;
BEGIN
  IF p_food_key IS NULL THEN RETURN; END IF;

  -- Check whether any existing food tile in this chunk already has a
  -- road as a 4-neighbor. If yes, the parcel already passes the bar.
  SELECT EXISTS (
    SELECT 1
    FROM public.map_tiles m
    WHERE m.x BETWEEN v_x_start AND v_x_start + 14
      AND m.y BETWEEN v_y_start AND v_y_start + 14
      AND m.resource_node_key = p_food_key
      AND EXISTS (
        SELECT 1
        FROM public.buildings b
        JOIN public.building_types bt ON bt.key = b.building_type_key
        WHERE bt.category = 'road'
          AND ABS(b.x - m.x) + ABS(b.y - m.y) = 1
      )
  ) INTO v_already_road_adjacent;

  IF v_already_road_adjacent THEN RETURN; END IF;

  -- No food tile is road-adjacent yet — pick a random empty cell that
  -- IS adjacent to a road and stamp the food key on it.
  SELECT m.x, m.y INTO v_pick_x, v_pick_y
  FROM public.map_tiles m
  WHERE m.x BETWEEN v_x_start AND v_x_start + 14
    AND m.y BETWEEN v_y_start AND v_y_start + 14
    AND m.resource_node_key IS NULL
    AND m.claimed_by_building_id IS NULL
    AND EXISTS (
      SELECT 1 FROM public.buildings b
      JOIN public.building_types bt ON bt.key = b.building_type_key
      WHERE bt.category = 'road'
        AND ABS(b.x - m.x) + ABS(b.y - m.y) = 1
    )
  ORDER BY random()
  LIMIT 1;

  IF v_pick_x IS NOT NULL THEN
    UPDATE public.map_tiles
    SET resource_node_key = p_food_key
    WHERE x = v_pick_x AND y = v_pick_y;
  END IF;
END;
$$;


-- Patch allocate_district_chunk to call the guarantee for first-chunk
-- allocations, after roads + clusters are placed. Re-create with the
-- existing body (verbatim from the 2026-05-09 doubling migration) plus
-- the new call near the end.

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

  IF v_is_first_chunk THEN
    v_industry_clusters := 4;
    v_industry_walk_min := 2;
    v_industry_walk_max := 5;
    v_food_clusters := 2;
    v_food_walk_min := 2;
    v_food_walk_max := 3;
  ELSE
    v_industry_clusters := 2;
    v_industry_walk_min := 2;
    v_industry_walk_max := 4;
    v_food_clusters := 2;
    v_food_walk_min := 1;
    v_food_walk_max := 2;
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
  PERFORM public._place_pre_road(p_player_id, v_x_start + 0, v_y_start + 7);
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
      PERFORM public._place_pre_road(p_player_id,
        v_x_start + v_axis_pos, v_y_start + 7 + v_cur_off);
    ELSE
      IF NOT v_can_drift AND v_cur_off != 0 THEN
        v_cur_off := v_cur_off - sign(v_cur_off);
        PERFORM public._place_pre_road(p_player_id,
          v_x_start + v_axis_pos, v_y_start + 7 + v_cur_off);
      ELSE
        v_axis_pos := v_axis_pos + 1;
        PERFORM public._place_pre_road(p_player_id,
          v_x_start + v_axis_pos, v_y_start + 7 + v_cur_off);
      END IF;
    END IF;
  END LOOP;
  WHILE v_cur_off != 0 LOOP
    v_cur_off := v_cur_off - sign(v_cur_off);
    PERFORM public._place_pre_road(p_player_id,
      v_x_start + 14, v_y_start + 7 + v_cur_off);
  END LOOP;

  -- ── Curving vertical highway: (7,0) → (7,14) ──
  v_axis_pos := 0; v_cur_off := 0;
  PERFORM public._place_pre_road(p_player_id, v_x_start + 7, v_y_start + 0);
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
      PERFORM public._place_pre_road(p_player_id,
        v_x_start + 7 + v_cur_off, v_y_start + v_axis_pos);
    ELSE
      IF NOT v_can_drift AND v_cur_off != 0 THEN
        v_cur_off := v_cur_off - sign(v_cur_off);
        PERFORM public._place_pre_road(p_player_id,
          v_x_start + 7 + v_cur_off, v_y_start + v_axis_pos);
      ELSE
        v_axis_pos := v_axis_pos + 1;
        PERFORM public._place_pre_road(p_player_id,
          v_x_start + 7 + v_cur_off, v_y_start + v_axis_pos);
      END IF;
    END IF;
  END LOOP;
  WHILE v_cur_off != 0 LOOP
    v_cur_off := v_cur_off - sign(v_cur_off);
    PERFORM public._place_pre_road(p_player_id,
      v_x_start + 7 + v_cur_off, v_y_start + 14);
  END LOOP;

  -- After roads are placed: guarantee at least one food tile is
  -- road-adjacent on the starter parcel so new players don't have to
  -- run a long road just to reach food. Expansion chunks skip this —
  -- by then the player can plan their own road layout.
  IF v_is_first_chunk AND v_food_tile_key IS NOT NULL THEN
    PERFORM public._guarantee_food_near_road(p_chunk_x, p_chunk_y, v_food_tile_key);
  END IF;

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
$function$;


-- Changelog entry — required for any player-visible change.
INSERT INTO public.changelog_entries (slug, title, body)
VALUES (
  '2026-05-09-starter-food-near-road',
  'Starter parcel: a farm next to the road, guaranteed',
  E'New players now always start with at least one food tile (orchard / pond / garden / farmland, depending on industry) adjacent to the pre-placed roads. No more spending your first 10 minutes building a road out to a farm patch in the corner of the map.\n\nThis only affects newly-allocated starter parcels — existing players are unchanged.'
)
ON CONFLICT (slug) DO NOTHING;
