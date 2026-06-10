-- ─────────────────────────────────────────────────────────────────────
-- Double resource density on newly-allocated parcels (2026-05-09).
--
-- Atlas: "double the amount of resources in each parcel. not what is
-- on the map currently, but just for the future when it generates a
-- new parcel."
--
-- Doubling the cluster count (vs. doubling walk lengths) preserves
-- average patch size and just adds more patches — keeps the "patches
-- feel discovered, not gridded" character.
--
-- First-chunk:    industry 2 → 4 clusters | food 1 → 2 clusters
-- Expansion:      industry 1 → 2 clusters | food 1 → 2 clusters
-- Walk lengths unchanged.
--
-- Existing chunks are NOT touched. Only chunks allocated AFTER this
-- migration get the new density.
-- ─────────────────────────────────────────────────────────────────────

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

  -- Resource density. Doubled 2026-05-09 (cluster counts × 2; walk
  -- lengths unchanged so each patch is the same size, there are just
  -- twice as many).
  IF v_is_first_chunk THEN
    v_industry_clusters := 4;       -- was 2 (and 4 before halving in 2026-05-06)
    v_industry_walk_min := 2;
    v_industry_walk_max := 5;
    v_food_clusters := 2;           -- was 1
    v_food_walk_min := 2;
    v_food_walk_max := 3;
  ELSE
    v_industry_clusters := 2;       -- was 1
    v_industry_walk_min := 2;
    v_industry_walk_max := 4;
    v_food_clusters := 2;           -- was 1
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
  '2026-05-09-double-parcel-resources',
  'New parcels now have ~2× more resource patches',
  E'Newly-claimed parcels arrive with about twice as many resource patches as before — both your starter parcel and any expansion you buy from here forward.\n\nExisting parcels are unchanged. The bump kicks in only when a new parcel is allocated.\n\nUnder the hood: cluster count doubled, patch size kept the same, so the visual feel ("patches you discover") is preserved — there are just more of them per parcel.'
)
ON CONFLICT (slug) DO NOTHING;
