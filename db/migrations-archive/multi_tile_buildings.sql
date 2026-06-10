-- Multi-tile building footprints. Buildings can now occupy more than
-- a single tile — building.x, building.y is the anchor (top-left), and
-- the footprint covers (x..x+w-1, y..y+h-1). Default w=h=1 so existing
-- buildings are unaffected.
--
-- Schema:
--   building_types.footprint_w / footprint_h  smallint, default 1
--   map_tiles.occupied_building_id            UNIQUE constraint dropped
--     so multiple tiles can point to the same building
--
-- place_building now validates every tile in the footprint (ownership,
-- buildable, unoccupied, no resource clash) and marks every footprint
-- tile with occupied_building_id. Demolish flow needs no change — the
-- existing FK ON DELETE SET NULL on map_tiles.occupied_building_id
-- already cascades cleanup to all footprint tiles.
--
-- First multi-tile picks: tax_man, school, temple at 2x2 (the civic
-- buildings whose facades visually deserve more space) and brewery at
-- 2x1 (a long horizontal brewing hall).
--
-- Apply: psql "$DB_URL" -f multi_tile_buildings.sql

-- ── 1. Schema additions ──
ALTER TABLE public.building_types
  ADD COLUMN IF NOT EXISTS footprint_w smallint NOT NULL DEFAULT 1,
  ADD COLUMN IF NOT EXISTS footprint_h smallint NOT NULL DEFAULT 1;

ALTER TABLE public.building_types
  ADD CONSTRAINT building_types_footprint_w_check CHECK (footprint_w BETWEEN 1 AND 4),
  ADD CONSTRAINT building_types_footprint_h_check CHECK (footprint_h BETWEEN 1 AND 4);

-- Drop the per-tile UNIQUE constraint — multiple tiles point to one
-- building when the building is multi-tile. (Each tile still has at
-- most one building, but the constraint we want lives in the placement
-- logic, not the column.)
ALTER TABLE public.map_tiles
  DROP CONSTRAINT IF EXISTS map_tiles_occupied_building_id_key;

-- ── 2. Set footprints for the chosen multi-tile buildings ──
UPDATE public.building_types SET footprint_w = 2, footprint_h = 2
  WHERE key IN ('tax_man', 'school', 'temple');
UPDATE public.building_types SET footprint_w = 2, footprint_h = 1
  WHERE key = 'brewery';

-- ── 3. place_building: validate + claim footprint ──
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
  v_w int;
  v_h int;
  v_dx int;
  v_dy int;
  v_check_tile record;
  v_footprint_tile_ids uuid[] := ARRAY[]::uuid[];
BEGIN
  SELECT NULL::integer AS target_x, NULL::integer AS target_y, NULL::integer AS path_length
  INTO v_path;
  SELECT * INTO v_bt FROM public.building_types WHERE key = p_building_type_key AND is_active;
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

  v_w := COALESCE(v_bt.footprint_w, 1);
  v_h := COALESCE(v_bt.footprint_h, 1);

  -- Validate every tile in the footprint (anchor + interior).
  FOR v_dx IN 0..(v_w - 1) LOOP
    FOR v_dy IN 0..(v_h - 1) LOOP
      SELECT * INTO v_check_tile FROM public.map_tiles
        WHERE x = v_tile.x + v_dx AND y = v_tile.y + v_dy
        FOR UPDATE;
      IF NOT FOUND THEN
        RAISE EXCEPTION 'Footprint extends off the map at (%, %)', v_tile.x + v_dx, v_tile.y + v_dy;
      END IF;
      IF v_check_tile.owner_player_id IS NULL THEN
        RAISE EXCEPTION 'Cannot build on wilderness — expand your district first';
      END IF;
      IF v_check_tile.owner_player_id <> v_uid THEN
        RAISE EXCEPTION 'Cannot build on another player''s district';
      END IF;
      IF NOT v_check_tile.buildable THEN
        RAISE EXCEPTION 'Tile (%, %) is not buildable', v_check_tile.x, v_check_tile.y;
      END IF;
      IF v_check_tile.occupied_building_id IS NOT NULL THEN
        RAISE EXCEPTION 'Tile (%, %) is already occupied', v_check_tile.x, v_check_tile.y;
      END IF;
      v_footprint_tile_ids := v_footprint_tile_ids || v_check_tile.id;
    END LOOP;
  END LOOP;

  IF v_bt.category = 'road' THEN
    SELECT EXISTS (
      SELECT 1 FROM public.buildings b2
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
  -- Claim every tile in the footprint.
  UPDATE public.map_tiles SET occupied_building_id = v_building_id
    WHERE id = ANY(v_footprint_tile_ids);

  IF v_bt.category = 'extractor' THEN
    SELECT * INTO v_path FROM public.find_nearest_unclaimed_resource(v_uid, v_tile.x, v_tile.y);
    IF v_path.path_length IS NOT NULL THEN
      UPDATE public.buildings SET target_x = v_path.target_x, target_y = v_path.target_y, path_length = v_path.path_length
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
    AND (NOT htc.needs_road OR public.has_road_access(v_uid, b2.x, b2.y))
    AND (NOT htc.needs_well OR public.has_well_access(v_uid, b2.x, b2.y));
  SELECT COALESCE(SUM(bt2.worker_cost), 0) INTO v_workers_needed
  FROM public.buildings b2
  JOIN public.building_types bt2 ON bt2.key = b2.building_type_key
  WHERE b2.player_id = v_uid AND b2.status = 'active'
    AND (
      bt2.category = 'extractor'
      OR (bt2.category = 'processor' AND public.has_road_access(v_uid, b2.x, b2.y))
      OR (bt2.category = 'tax'       AND public.has_road_access(v_uid, b2.x, b2.y))
      OR (bt2.category = 'service'   AND public.has_road_access(v_uid, b2.x, b2.y))
    );
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

GRANT EXECUTE ON FUNCTION public.place_building(uuid, text) TO authenticated;
