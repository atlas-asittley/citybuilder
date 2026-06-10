-- Food extractors must now be placed on a matching food tile.
-- Adds 4 new resource_node_key values:
--   orchard_grove   — required by `orchard`      (timber industry)
--   pond            — required by `fishing_pier` (stone industry)
--   garden_plot     — required by `garden`       (clay industry)
--   farmland        — required by `grain_farm`   (iron industry)
--
-- Schema:
--   building_types.placement_resource_node_key — set for the 4 food
--     extractors. The reject_build_on_resource trigger consults this
--     to allow placement on the matching food tile (every other resource
--     tile still rejects every building, as before).
--
-- The food tile stays under the building during its lifetime — the
-- resource_node_key is *not* consumed at placement. Demolish the
-- building → tile reverts to its food-tile appearance and a new food
-- extractor can be placed there. To turn a food tile into plain grass,
-- use clear_resource_tile (which now also rejects tiles that already
-- have a building on top, symmetric to its existing extractor-target
-- rule).
--
-- Seeding: allocate_district_chunk continues to drop 4 ore clusters
-- (6-15 walk steps) and now also drops 2 smaller food clusters
-- (4-8 walk steps) of the player's industry-matching food tile. Seeding
-- is industry-locked exactly like the ore clusters — a stone player only
-- gets ponds, a timber player only gets orchard_groves, etc. Existing
-- chunks are back-filled by the DO block at the bottom.
--
-- Apply: psql "$DB_URL" -f food_tiles.sql

-- ── 1. resources rows for the food tile types ──
-- map_tiles.resource_node_key has a FK to resources(key), so the new
-- tile types need rows here even though they're terrain markers, not
-- inventory items. The kind constraint is widened to allow 'terrain';
-- is_active=false suppresses them from any trade-good UI.
ALTER TABLE public.resources DROP CONSTRAINT IF EXISTS resources_kind_check;
ALTER TABLE public.resources
  ADD CONSTRAINT resources_kind_check
  CHECK (kind IN ('raw', 'processed', 'terrain'));

INSERT INTO public.resources (key, name, kind, industry_key, is_active)
VALUES
  ('orchard_grove', 'Orchard Grove', 'terrain', 'timber', false),
  ('pond',          'Pond',          'terrain', 'stone',  false),
  ('garden_plot',   'Garden Plot',   'terrain', 'clay',   false),
  ('farmland',      'Farmland',      'terrain', 'iron',   false)
ON CONFLICT (key) DO UPDATE SET
  name = EXCLUDED.name, kind = EXCLUDED.kind,
  industry_key = EXCLUDED.industry_key, is_active = EXCLUDED.is_active;

-- ── 2. building_types column + values ──
ALTER TABLE public.building_types
  ADD COLUMN IF NOT EXISTS placement_resource_node_key text;

UPDATE public.building_types
SET placement_resource_node_key = CASE key
  WHEN 'orchard'      THEN 'orchard_grove'
  WHEN 'fishing_pier' THEN 'pond'
  WHEN 'garden'       THEN 'garden_plot'
  WHEN 'grain_farm'   THEN 'farmland'
END
WHERE key IN ('orchard', 'fishing_pier', 'garden', 'grain_farm');

-- ── 2. Trigger: allow food extractors on their matching food tile ──
CREATE OR REPLACE FUNCTION public.reject_build_on_resource()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  v_resource text;
  v_required text;
BEGIN
  SELECT mt.resource_node_key INTO v_resource
  FROM public.map_tiles mt WHERE mt.id = NEW.tile_id;

  SELECT placement_resource_node_key INTO v_required
  FROM public.building_types WHERE key = NEW.building_type_key;

  IF v_required IS NOT NULL THEN
    -- Positive requirement: this building MUST go on its matching tile.
    IF v_resource IS DISTINCT FROM v_required THEN
      RAISE EXCEPTION '% needs to be placed on a % tile', NEW.building_type_key, v_required;
    END IF;
    RETURN NEW;
  END IF;

  -- Default: any other building on a resource tile is rejected.
  IF v_resource IS NOT NULL THEN
    RAISE EXCEPTION 'Cannot build on a % tile — clear it first', v_resource;
  END IF;
  RETURN NEW;
END;
$$;

-- ── 3. clear_resource_tile: also reject if a building is on the tile ──
CREATE OR REPLACE FUNCTION public.clear_resource_tile(p_tile_id uuid)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_tile record;
BEGIN
  SELECT * INTO v_tile FROM public.map_tiles WHERE id = p_tile_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Tile not found'; END IF;
  IF v_tile.owner_player_id IS NULL OR v_tile.owner_player_id <> v_uid THEN
    RAISE EXCEPTION 'Cannot clear a resource tile you do not own';
  END IF;
  IF v_tile.resource_node_key IS NULL THEN
    RAISE EXCEPTION 'Tile has no resource to clear';
  END IF;
  IF v_tile.claimed_by_building_id IS NOT NULL THEN
    RAISE EXCEPTION 'Demolish the extractor targeting this tile before clearing it';
  END IF;
  IF v_tile.occupied_building_id IS NOT NULL THEN
    RAISE EXCEPTION 'Demolish the building on this tile before clearing it';
  END IF;
  UPDATE public.map_tiles SET resource_node_key = NULL WHERE id = p_tile_id;
  RETURN json_build_object(
    'tile_id', p_tile_id,
    'cleared_resource', v_tile.resource_node_key,
    'x', v_tile.x,
    'y', v_tile.y
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.clear_resource_tile(uuid) TO authenticated;

-- ── 4. Cluster-seeding helper (factored out of allocate_district_chunk) ──
CREATE OR REPLACE FUNCTION public._seed_resource_clusters(
  p_chunk_x integer,
  p_chunk_y integer,
  p_resource_key text,
  p_cluster_count integer,
  p_min_walk integer,
  p_max_walk integer
) RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
  v_x_start integer := p_chunk_x * 15;
  v_y_start integer := p_chunk_y * 15;
  v_idx integer;
  v_seed_dx integer;
  v_seed_dy integer;
  v_walk_steps integer;
  v_step integer;
  v_curr_dx integer;
  v_curr_dy integer;
  v_new_dx integer;
  v_new_dy integer;
  v_dir integer;
BEGIN
  FOR v_idx IN 1..p_cluster_count LOOP
    v_seed_dx := floor(random() * 15)::integer;
    v_seed_dy := floor(random() * 15)::integer;
    v_walk_steps := p_min_walk + floor(random() * (p_max_walk - p_min_walk + 1))::integer;
    v_curr_dx := v_seed_dx;
    v_curr_dy := v_seed_dy;

    UPDATE public.map_tiles
    SET resource_node_key = p_resource_key
    WHERE x = v_x_start + v_curr_dx AND y = v_y_start + v_curr_dy
      AND resource_node_key IS NULL;

    FOR v_step IN 1..v_walk_steps LOOP
      v_dir := floor(random() * 4)::integer;
      v_new_dx := v_curr_dx + CASE v_dir WHEN 0 THEN 1 WHEN 1 THEN -1 ELSE 0 END;
      v_new_dy := v_curr_dy + CASE v_dir WHEN 2 THEN 1 WHEN 3 THEN -1 ELSE 0 END;
      IF v_new_dx < 0 OR v_new_dx > 14 OR v_new_dy < 0 OR v_new_dy > 14 THEN
        v_curr_dx := v_seed_dx;
        v_curr_dy := v_seed_dy;
        CONTINUE;
      END IF;
      UPDATE public.map_tiles
      SET resource_node_key = p_resource_key
      WHERE x = v_x_start + v_new_dx AND y = v_y_start + v_new_dy
        AND resource_node_key IS NULL;
      v_curr_dx := v_new_dx;
      v_curr_dy := v_new_dy;
    END LOOP;
  END LOOP;
END;
$$;

-- ── 5. allocate_district_chunk: also seed food clusters ──
CREATE OR REPLACE FUNCTION public.allocate_district_chunk(
  p_player_id uuid, p_chunk_x integer, p_chunk_y integer
) RETURNS json
LANGUAGE plpgsql
AS $$
DECLARE
  v_player record;
  v_x_start integer := p_chunk_x * 15;
  v_y_start integer := p_chunk_y * 15;
  v_dx integer;
  v_dy integer;
  v_resource_count integer;
  v_food_tile_key text;
  v_is_first_chunk boolean;
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
        buildable = true;
    END LOOP;
  END LOOP;

  PERFORM public._seed_resource_clusters(
    p_chunk_x, p_chunk_y, v_player.industry_key, 4, 6, 15);

  IF v_food_tile_key IS NOT NULL THEN
    PERFORM public._seed_resource_clusters(
      p_chunk_x, p_chunk_y, v_food_tile_key, 2, 4, 8);
  END IF;

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
$$;

-- ── 6. Back-fill food clusters into existing chunks ──
DO $back$
DECLARE
  v_chunk record;
  v_food_tile_key text;
  v_existing integer;
BEGIN
  FOR v_chunk IN
    SELECT dc.chunk_x, dc.chunk_y, pp.industry_key
    FROM public.district_chunks dc
    JOIN public.player_profiles pp ON pp.id = dc.owner_player_id
  LOOP
    v_food_tile_key := CASE v_chunk.industry_key
      WHEN 'timber' THEN 'orchard_grove'
      WHEN 'stone'  THEN 'pond'
      WHEN 'clay'   THEN 'garden_plot'
      WHEN 'iron'   THEN 'farmland'
    END;
    IF v_food_tile_key IS NULL THEN CONTINUE; END IF;

    SELECT COUNT(*) INTO v_existing
    FROM public.map_tiles
    WHERE x >= v_chunk.chunk_x * 15 AND x < v_chunk.chunk_x * 15 + 15
      AND y >= v_chunk.chunk_y * 15 AND y < v_chunk.chunk_y * 15 + 15
      AND resource_node_key = v_food_tile_key;

    IF v_existing = 0 THEN
      PERFORM public._seed_resource_clusters(
        v_chunk.chunk_x, v_chunk.chunk_y, v_food_tile_key, 2, 4, 8);
    END IF;
  END LOOP;
END
$back$;
