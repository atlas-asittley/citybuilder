-- Cluster resource tiles into forest/quarry/field/pit blobs instead of
-- sprinkling them uniformly. Random-walk algorithm: drop N cluster seeds,
-- walk outward, mark visited tiles as resource.
--
-- Apply: psql "$DB_URL" -f cluster_resources_in_chunks.sql
-- Affects new chunks only — existing allocated chunks keep their layout.

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

  -- Cluster generator state
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

  -- Lay down all 225 ground tiles with no resource. Cluster seeding fills
  -- them in below. The upsert preserves any pre-existing resource on a
  -- tile, which can happen if a neighbouring chunk's cluster has spilled
  -- in (not currently possible with the in-bounds restart logic, but kept
  -- for safety).
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

  -- Drop N cluster seeds at random points and random-walk each one out
  -- 6-15 steps. Steps that would leave the chunk rewind to the seed,
  -- so clusters stay in-chunk. Revisits are no-ops (the WHERE filters on
  -- resource_node_key IS NULL), so actual cluster sizes are organic.
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
      v_new_dx := v_curr_dx
                  + CASE v_dir WHEN 0 THEN 1 WHEN 1 THEN -1 ELSE 0 END;
      v_new_dy := v_curr_dy
                  + CASE v_dir WHEN 2 THEN 1 WHEN 3 THEN -1 ELSE 0 END;
      IF v_new_dx < 0 OR v_new_dx > 14
         OR v_new_dy < 0 OR v_new_dy > 14 THEN
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

  -- Stamp city center for the player's first chunk (overwrites any
  -- resource that randomly seeded onto (7,7) — fine, city center has
  -- priority).
  IF v_is_first_chunk THEN
    UPDATE public.map_tiles
    SET terrain_type = 'city_center',
        buildable = false,
        resource_node_key = NULL
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
