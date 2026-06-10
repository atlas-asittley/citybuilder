-- ── Scarcer chunks + costlier expansion (2026-05-07) ──
-- Atlas: production is currently too easy. Each chunk drops ~22 ore tiles
-- and ~6 food tiles, and the second chunk costs $1000 — players just keep
-- expanding and over-producing one resource. Push the game toward
-- TRADE BALANCE, not autarky:
--
-- 1. Starter chunk drops to ~7 ore tiles + ~3 food tiles (~1/3 of prior).
--    Enough to bootstrap one extractor + one food extractor.
-- 2. Subsequent chunks drop to ~3 ore tiles + ~1-2 food tiles (sparse).
--    Players who want raw goods at scale must trade for them.
-- 3. Expansion base cost $1000 → $10,000. Now 2nd chunk costs $10k,
--    3rd $40k, 4th $90k. Slows the autarky-by-expansion path even
--    further; you'd need a healthy trade economy to afford expansion.

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
  v_industry_clusters integer;
  v_industry_walk_min integer;
  v_industry_walk_max integer;
  v_food_clusters integer;
  v_food_walk_min integer;
  v_food_walk_max integer;
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
$function$;

-- Expansion cost: $1000 base × chunks_owned² → $10,000 base × chunks_owned².
-- 2nd chunk: $10,000 (was $1,000)
-- 3rd chunk: $40,000 (was $4,000)
-- 4th chunk: $90,000 (was $9,000)
CREATE OR REPLACE FUNCTION public.expand_district(p_chunk_x integer, p_chunk_y integer)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_player record;
  v_cost integer;
  v_alloc json;
  v_base_cost integer := 10000;     -- was 1000
  v_is_candidate boolean;
BEGIN
  SELECT * INTO v_player FROM public.player_profiles WHERE id = v_uid;
  IF NOT FOUND THEN RAISE EXCEPTION 'Player not found'; END IF;

  v_cost := v_base_cost * v_player.chunks_owned * v_player.chunks_owned;

  IF v_player.money < v_cost THEN
    RAISE EXCEPTION 'Not enough money to expand (need %, have %)',
      v_cost, v_player.money;
  END IF;

  SELECT EXISTS (
    SELECT 1 FROM public.expansion_candidates(v_uid) ec
    WHERE ec.chunk_x = p_chunk_x AND ec.chunk_y = p_chunk_y
  ) INTO v_is_candidate;

  IF NOT v_is_candidate THEN
    RAISE EXCEPTION 'Chunk (%, %) is not a valid expansion candidate', p_chunk_x, p_chunk_y;
  END IF;

  v_alloc := public.allocate_district_chunk(v_uid, p_chunk_x, p_chunk_y);

  UPDATE public.player_profiles
  SET money = money - v_cost
  WHERE id = v_uid
  RETURNING * INTO v_player;

  INSERT INTO public.cash_transactions (player_id, source, amount, context)
  VALUES (v_uid, 'expansion_cost', -v_cost,
          jsonb_build_object('chunk_x', p_chunk_x, 'chunk_y', p_chunk_y));

  RETURN json_build_object(
    'chunk_x', p_chunk_x,
    'chunk_y', p_chunk_y,
    'cost', v_cost,
    'money', v_player.money,
    'chunks_owned', v_player.chunks_owned,
    'allocation', v_alloc
  );
END;
$function$;
