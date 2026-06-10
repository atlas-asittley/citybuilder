-- ============================================================
-- City Builder — Distance-Based Resource Collection (M2)
-- ============================================================
-- Run AFTER district_scaffolding_migration.sql.
--
-- Replaces the "extractor must be placed on a matching resource
-- tile" rule with a distance-based collection model:
--
--   * Extractors place on any road-adjacent tile in their district
--   * Server BFS finds the shortest path through the player's roads
--     to a road tile orthogonally adjacent to a matching unclaimed
--     resource tile, claims it, and stores path_length
--   * process_production scales each extractor's output_rate by
--     min(1, 4 / path_length) — canonical 4-tile path = full rate
--   * Hybrid sticky re-targeting: claims hold until the path
--     breaks, then re-BFS finds a fresh target. New roads do NOT
--     reshuffle existing claims unless an extractor is idle.
--
-- See GAME_DESIGN.md for the design rationale.
--
-- Wiped data is fine — the migration adds nullable columns; existing
-- buildings just become idle until they're re-placed (and given
-- the M1 wipe, you'll be re-placing anyway).
-- ============================================================

-- ────────────────────────────────────────────────────────────
-- 1. SCHEMA ADDITIONS
-- ────────────────────────────────────────────────────────────

ALTER TABLE public.buildings
  ADD COLUMN IF NOT EXISTS target_x integer;
ALTER TABLE public.buildings
  ADD COLUMN IF NOT EXISTS target_y integer;
ALTER TABLE public.buildings
  ADD COLUMN IF NOT EXISTS path_length integer;

CREATE INDEX IF NOT EXISTS idx_buildings_target_xy
  ON public.buildings (target_x, target_y) WHERE target_x IS NOT NULL;

ALTER TABLE public.map_tiles
  ADD COLUMN IF NOT EXISTS claimed_by_building_id uuid;

-- Defer the FK so the column can reference buildings safely
DO $$ BEGIN
  ALTER TABLE public.map_tiles
    ADD CONSTRAINT map_tiles_claimed_by_building_fkey
    FOREIGN KEY (claimed_by_building_id)
    REFERENCES public.buildings(id) ON DELETE SET NULL;
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

CREATE UNIQUE INDEX IF NOT EXISTS idx_map_tiles_claimed_by
  ON public.map_tiles (claimed_by_building_id)
  WHERE claimed_by_building_id IS NOT NULL;

-- ────────────────────────────────────────────────────────────
-- 2. BFS — find nearest unclaimed resource for an extractor
-- ────────────────────────────────────────────────────────────
-- Walks the player's road graph from a road tile adjacent to the
-- extractor at (p_ex, p_ey). Returns the first matching unclaimed
-- resource tile reachable (which is the closest by definition,
-- since BFS is FIFO).
--
-- Returns (target_x, target_y, path_length) where path_length is
-- the number of road tiles traversed (extractor → first road = 1).
-- Returns no rows if no path exists.
--
-- Bounded by a safety cap of 1000 tiles per call.
-- ────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.find_nearest_unclaimed_resource(
  p_player_id uuid,
  p_ex integer,
  p_ey integer
)
RETURNS TABLE(target_x integer, target_y integer, path_length integer)
LANGUAGE plpgsql STABLE AS $$
DECLARE
  v_player record;
  v_resource_key text;
  v_visited jsonb := '{}'::jsonb;
  v_queue jsonb := '[]'::jsonb;
  v_cur jsonb;
  v_rx integer;
  v_ry integer;
  v_dist integer;
  v_neighbor_key text;
  v_neighbor record;
  v_iters integer := 0;
  v_max_iters integer := 1000;
BEGIN
  SELECT * INTO v_player FROM public.player_profiles WHERE id = p_player_id;
  IF NOT FOUND THEN RETURN; END IF;
  v_resource_key := v_player.industry_key;

  -- Seed the queue with the player's road tiles orthogonally adjacent
  -- to the extractor. These are the dist=1 starting points.
  FOR v_neighbor IN
    SELECT b.x AS rx, b.y AS ry
    FROM public.buildings b
    JOIN public.building_types bt ON bt.key = b.building_type_key
    WHERE bt.category = 'road'
      AND b.status = 'active'
      AND b.player_id = p_player_id
      AND (
        (b.x = p_ex - 1 AND b.y = p_ey)
        OR (b.x = p_ex + 1 AND b.y = p_ey)
        OR (b.x = p_ex AND b.y = p_ey - 1)
        OR (b.x = p_ex AND b.y = p_ey + 1)
      )
  LOOP
    v_neighbor_key := v_neighbor.rx || ',' || v_neighbor.ry;
    IF NOT (v_visited ? v_neighbor_key) THEN
      v_visited := v_visited || jsonb_build_object(v_neighbor_key, true);
      v_queue := v_queue || jsonb_build_array(jsonb_build_object(
        'x', v_neighbor.rx, 'y', v_neighbor.ry, 'd', 1
      ));
    END IF;
  END LOOP;

  -- BFS
  WHILE jsonb_array_length(v_queue) > 0 AND v_iters < v_max_iters LOOP
    v_iters := v_iters + 1;
    v_cur := v_queue->0;
    v_queue := v_queue - 0;
    v_rx := (v_cur->>'x')::integer;
    v_ry := (v_cur->>'y')::integer;
    v_dist := (v_cur->>'d')::integer;

    -- Check for a matching unclaimed resource tile orthogonally adjacent
    -- to this road tile. Tile must also be owned by the player.
    -- A tile counts as a candidate only if it has the matching resource,
    -- isn't already claimed, and has no building on it. The
    -- occupied_building_id check prevents an extractor placed on top of
    -- a resource tile (legal under M2 placement rules) from claiming
    -- that same tile as its own target.
    SELECT mt.x, mt.y INTO target_x, target_y
    FROM public.map_tiles mt
    WHERE mt.owner_player_id = p_player_id
      AND mt.resource_node_key = v_resource_key
      AND mt.claimed_by_building_id IS NULL
      AND mt.occupied_building_id IS NULL
      AND (
        (mt.x = v_rx - 1 AND mt.y = v_ry)
        OR (mt.x = v_rx + 1 AND mt.y = v_ry)
        OR (mt.x = v_rx AND mt.y = v_ry - 1)
        OR (mt.x = v_rx AND mt.y = v_ry + 1)
      )
    LIMIT 1;

    IF target_x IS NOT NULL THEN
      path_length := v_dist;
      RETURN NEXT;
      RETURN;
    END IF;

    -- Otherwise, enqueue neighboring road tiles (player's own).
    FOR v_neighbor IN
      SELECT b.x AS rx, b.y AS ry
      FROM public.buildings b
      JOIN public.building_types bt ON bt.key = b.building_type_key
      WHERE bt.category = 'road'
        AND b.status = 'active'
        AND b.player_id = p_player_id
        AND (
          (b.x = v_rx - 1 AND b.y = v_ry)
          OR (b.x = v_rx + 1 AND b.y = v_ry)
          OR (b.x = v_rx AND b.y = v_ry - 1)
          OR (b.x = v_rx AND b.y = v_ry + 1)
        )
    LOOP
      v_neighbor_key := v_neighbor.rx || ',' || v_neighbor.ry;
      IF NOT (v_visited ? v_neighbor_key) THEN
        v_visited := v_visited || jsonb_build_object(v_neighbor_key, true);
        v_queue := v_queue || jsonb_build_array(jsonb_build_object(
          'x', v_neighbor.rx, 'y', v_neighbor.ry, 'd', v_dist + 1
        ));
      END IF;
    END LOOP;
  END LOOP;

  -- No path found
  RETURN;
END;
$$;

-- ────────────────────────────────────────────────────────────
-- 3. BFS — verify the existing target is still reachable
-- ────────────────────────────────────────────────────────────
-- Used by hybrid-sticky re-targeting: keep current claim if still
-- reachable; otherwise release and re-BFS.
-- ────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.verify_extractor_path(
  p_player_id uuid,
  p_ex integer,
  p_ey integer,
  p_tx integer,
  p_ty integer
)
RETURNS integer LANGUAGE plpgsql STABLE AS $$
DECLARE
  v_visited jsonb := '{}'::jsonb;
  v_queue jsonb := '[]'::jsonb;
  v_cur jsonb;
  v_rx integer;
  v_ry integer;
  v_dist integer;
  v_neighbor_key text;
  v_neighbor record;
  v_iters integer := 0;
  v_max_iters integer := 1000;
BEGIN
  -- Seed with extractor's road neighbors
  FOR v_neighbor IN
    SELECT b.x AS rx, b.y AS ry
    FROM public.buildings b
    JOIN public.building_types bt ON bt.key = b.building_type_key
    WHERE bt.category = 'road' AND b.status = 'active' AND b.player_id = p_player_id
      AND (
        (b.x = p_ex - 1 AND b.y = p_ey)
        OR (b.x = p_ex + 1 AND b.y = p_ey)
        OR (b.x = p_ex AND b.y = p_ey - 1)
        OR (b.x = p_ex AND b.y = p_ey + 1)
      )
  LOOP
    v_neighbor_key := v_neighbor.rx || ',' || v_neighbor.ry;
    IF NOT (v_visited ? v_neighbor_key) THEN
      v_visited := v_visited || jsonb_build_object(v_neighbor_key, true);
      v_queue := v_queue || jsonb_build_array(jsonb_build_object(
        'x', v_neighbor.rx, 'y', v_neighbor.ry, 'd', 1
      ));
    END IF;
  END LOOP;

  WHILE jsonb_array_length(v_queue) > 0 AND v_iters < v_max_iters LOOP
    v_iters := v_iters + 1;
    v_cur := v_queue->0;
    v_queue := v_queue - 0;
    v_rx := (v_cur->>'x')::integer;
    v_ry := (v_cur->>'y')::integer;
    v_dist := (v_cur->>'d')::integer;

    -- Found if this road tile is adjacent to the target
    IF (ABS(v_rx - p_tx) + ABS(v_ry - p_ty)) = 1 THEN
      RETURN v_dist;
    END IF;

    FOR v_neighbor IN
      SELECT b.x AS rx, b.y AS ry
      FROM public.buildings b
      JOIN public.building_types bt ON bt.key = b.building_type_key
      WHERE bt.category = 'road' AND b.status = 'active' AND b.player_id = p_player_id
        AND (
          (b.x = v_rx - 1 AND b.y = v_ry)
          OR (b.x = v_rx + 1 AND b.y = v_ry)
          OR (b.x = v_rx AND b.y = v_ry - 1)
          OR (b.x = v_rx AND b.y = v_ry + 1)
        )
    LOOP
      v_neighbor_key := v_neighbor.rx || ',' || v_neighbor.ry;
      IF NOT (v_visited ? v_neighbor_key) THEN
        v_visited := v_visited || jsonb_build_object(v_neighbor_key, true);
        v_queue := v_queue || jsonb_build_array(jsonb_build_object(
          'x', v_neighbor.rx, 'y', v_neighbor.ry, 'd', v_dist + 1
        ));
      END IF;
    END LOOP;
  END LOOP;

  RETURN NULL;
END;
$$;

-- ────────────────────────────────────────────────────────────
-- 4. Hybrid-sticky re-targeting for a player's extractors
-- ────────────────────────────────────────────────────────────
-- For each of the player's extractors:
--   * If currently idle (no target): try to find a target.
--   * If has a target: verify the path is still valid. If valid,
--     keep it and just refresh path_length. If invalid, release
--     the claim and try to find a new target.
-- ────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.recompute_extractor_paths(p_player_id uuid)
RETURNS json LANGUAGE plpgsql AS $$
DECLARE
  v_extractor record;
  v_path record;
  v_verify integer;
  v_recomputed integer := 0;
  v_idle integer := 0;
BEGIN
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
$$;

-- ────────────────────────────────────────────────────────────
-- 5. UPDATED place_building — drops the on-tile rule for extractors,
--    requires road adjacency, runs BFS, claims target tile.
-- ────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.place_building(
  p_tile_id uuid,
  p_building_type_key text
)
RETURNS json LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_bt record;
  v_tile record;
  v_player record;
  v_building_id uuid;
  v_worker_supply integer;
  v_workers_needed integer;
  v_road_connected boolean;
  v_road_adjacent boolean;
  v_path record;
BEGIN
  -- Initialize v_path so the RETURN's CASE expression can read its fields
  -- even when this is a non-extractor placement (no BFS performed).
  SELECT NULL::integer AS target_x,
         NULL::integer AS target_y,
         NULL::integer AS path_length
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
    RAISE EXCEPTION 'Not enough money (need %, have %)',
      v_bt.build_cost, v_player.money;
  END IF;

  SELECT * INTO v_tile FROM public.map_tiles WHERE id = p_tile_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Tile not found'; END IF;

  -- District ownership
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

  -- Extractor rules (M2): road-adjacent, anywhere in district.
  -- The on-tile resource rule is GONE — extractors now collect via
  -- walkers traveling along the road graph to a resource tile.
  IF v_bt.category = 'extractor' THEN
    v_road_adjacent := public.has_road_access(v_uid, v_tile.x, v_tile.y);
    IF NOT v_road_adjacent THEN
      RAISE EXCEPTION 'Extractors must be placed adjacent to one of your roads';
    END IF;

  ELSIF v_bt.category = 'road' THEN
    SELECT (
      (v_player.home_x IS NOT NULL
       AND ABS(v_tile.x - v_player.home_x) + ABS(v_tile.y - v_player.home_y) = 1)
      OR EXISTS (
        SELECT 1
        FROM public.buildings b2
        JOIN public.building_types bt2 ON bt2.key = b2.building_type_key
        WHERE bt2.category = 'road'
          AND b2.status = 'active'
          AND b2.player_id = v_uid
          AND (
            (b2.x = v_tile.x - 1 AND b2.y = v_tile.y)
            OR (b2.x = v_tile.x + 1 AND b2.y = v_tile.y)
            OR (b2.x = v_tile.x AND b2.y = v_tile.y - 1)
            OR (b2.x = v_tile.x AND b2.y = v_tile.y + 1)
          )
      )
    ) INTO v_road_connected;

    IF NOT v_road_connected THEN
      RAISE EXCEPTION 'Roads must connect to your city center or another of your roads';
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

  -- M2: For extractors, immediately try to claim a resource tile
  IF v_bt.category = 'extractor' THEN
    SELECT * INTO v_path
    FROM public.find_nearest_unclaimed_resource(v_uid, v_tile.x, v_tile.y);
    IF v_path IS NOT NULL AND v_path.path_length IS NOT NULL THEN
      UPDATE public.buildings
      SET target_x = v_path.target_x,
          target_y = v_path.target_y,
          path_length = v_path.path_length
      WHERE id = v_building_id;
      UPDATE public.map_tiles
      SET claimed_by_building_id = v_building_id
      WHERE x = v_path.target_x AND y = v_path.target_y;
    END IF;
  END IF;

  -- M2: For roads, idle extractors might now find a path. Sticky-but-
  -- helpful: only re-BFS for extractors that don't currently have a target.
  IF v_bt.category = 'road' THEN
    PERFORM public.recompute_extractor_paths(v_uid);
  END IF;

  -- Recompute worker supply/demand using the per-player road check.
  SELECT 5 + COALESCE(SUM(htc.workers), 0) INTO v_worker_supply
  FROM public.buildings b2
  JOIN public.building_types bt2 ON bt2.key = b2.building_type_key
  JOIN public.housing_tier_config htc ON htc.tier = b2.housing_tier
  WHERE b2.player_id = v_uid
    AND b2.status = 'active'
    AND bt2.category = 'housing'
    AND (NOT htc.needs_road OR public.has_road_access(v_uid, b2.x, b2.y));

  SELECT COALESCE(SUM(bt2.worker_cost), 0) INTO v_workers_needed
  FROM public.buildings b2
  JOIN public.building_types bt2 ON bt2.key = b2.building_type_key
  WHERE b2.player_id = v_uid
    AND b2.status = 'active'
    AND (
      bt2.category = 'extractor'
      OR (bt2.category = 'processor' AND public.has_road_access(v_uid, b2.x, b2.y))
    );

  UPDATE public.player_profiles
  SET money = money - v_bt.build_cost,
      worker_capacity = v_worker_supply,
      workers_used = LEAST(v_worker_supply, v_workers_needed)
  WHERE id = v_uid
  RETURNING * INTO v_player;

  RETURN json_build_object(
    'building_id', v_building_id,
    'money', v_player.money,
    'workers_used', v_player.workers_used,
    'worker_capacity', v_player.worker_capacity,
    'workers_needed', v_workers_needed,
    'labor_shortage', v_workers_needed > v_worker_supply,
    'extractor_target', CASE WHEN v_path IS NOT NULL AND v_path.path_length IS NOT NULL
      THEN json_build_object('x', v_path.target_x, 'y', v_path.target_y, 'path_length', v_path.path_length)
      ELSE NULL END
  );
END;
$$;

-- ────────────────────────────────────────────────────────────
-- 6. Trigger: when a road is deleted, recompute paths for owner
-- ────────────────────────────────────────────────────────────
-- Demolition happens via direct DELETE on buildings (client-side).
-- This trigger keeps the resource graph consistent.
-- ────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.handle_building_change()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_bt record;
BEGIN
  IF TG_OP = 'DELETE' THEN
    SELECT * INTO v_bt FROM public.building_types WHERE key = OLD.building_type_key;
    IF v_bt.category = 'road' THEN
      PERFORM public.recompute_extractor_paths(OLD.player_id);
    END IF;
    -- Extractor demolition releases its claim automatically via
    -- ON DELETE SET NULL on map_tiles.claimed_by_building_id.
    RETURN OLD;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_buildings_change ON public.buildings;
CREATE TRIGGER trg_buildings_change
AFTER DELETE ON public.buildings
FOR EACH ROW EXECUTE FUNCTION public.handle_building_change();

-- ────────────────────────────────────────────────────────────
-- 7. UPDATED process_production — scale extractor rate by path
-- ────────────────────────────────────────────────────────────
-- Same body as housing_evolution_migration.sql but with the
-- extractor production loop scaling output_rate by:
--   min(1, canonical / max(path_length, 1))
-- where canonical = 4. Idle extractors (NULL path_length) skip.
-- ────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.process_production()
RETURNS json LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_base_workers integer := 5;
  v_housing_workers integer;
  v_worker_supply integer;
  v_workers_remaining integer;
  v_workers_needed integer := 0;
  v_staffed_ids uuid[];
  v_unstaffed_count integer := 0;
  v_building record;
  v_elapsed_min numeric;
  v_produced numeric;
  v_consumed numeric;
  v_available numeric;
  v_actual_min numeric;
  v_total_produced numeric := 0;
  v_player record;
  v_house record;
  v_has_road boolean;
  v_cur_tier record;
  v_next_tier record;
  v_prev_tier record;
  v_elapsed_secs numeric;
  v_evolution_events json[] := ARRAY[]::json[];
  v_should_upgrade boolean;
  v_should_devolve boolean;
  v_canonical_path integer := 4;  -- M2: path-length sweet spot
  v_path_factor numeric;
BEGIN
  -- ── LABOR ALLOCATION ─────────────────────────────────
  SELECT COALESCE(SUM(htc.workers), 0) INTO v_housing_workers
  FROM public.buildings b
  JOIN public.building_types bt ON bt.key = b.building_type_key
  JOIN public.housing_tier_config htc ON htc.tier = b.housing_tier
  WHERE b.player_id = v_uid AND b.status = 'active' AND bt.category = 'housing'
    AND (NOT htc.needs_road OR public.has_road_access(v_uid, b.x, b.y));

  v_worker_supply := v_base_workers + v_housing_workers;
  v_workers_remaining := v_worker_supply;
  v_staffed_ids := ARRAY[]::uuid[];

  FOR v_building IN
    SELECT b.id, bt.worker_cost
    FROM public.buildings b
    JOIN public.building_types bt ON bt.key = b.building_type_key
    WHERE b.player_id = v_uid AND b.status = 'active'
      AND (
        bt.category = 'extractor'
        OR (bt.category = 'processor' AND public.has_road_access(v_uid, b.x, b.y))
      )
    ORDER BY b.created_at ASC
  LOOP
    v_workers_needed := v_workers_needed + v_building.worker_cost;
    IF v_workers_remaining >= v_building.worker_cost THEN
      v_staffed_ids := v_staffed_ids || v_building.id;
      v_workers_remaining := v_workers_remaining - v_building.worker_cost;
    ELSE
      v_unstaffed_count := v_unstaffed_count + 1;
    END IF;
  END LOOP;

  -- ── PRODUCTION: extractors (staffed AND has-path-to-resource) ──
  FOR v_building IN
    SELECT b.id, b.last_processed_at, b.path_length,
           bt.output_resource_key, bt.output_rate
    FROM public.buildings b
    JOIN public.building_types bt ON bt.key = b.building_type_key
    WHERE b.player_id = v_uid AND b.status = 'active' AND bt.category = 'extractor'
      AND b.id = ANY(v_staffed_ids)
    FOR UPDATE OF b
  LOOP
    -- M2: skip if no path
    IF v_building.path_length IS NULL THEN
      UPDATE public.buildings SET last_processed_at = now() WHERE id = v_building.id;
      CONTINUE;
    END IF;

    v_elapsed_min := EXTRACT(EPOCH FROM (now() - v_building.last_processed_at)) / 60.0;
    IF v_elapsed_min < 0.1 THEN CONTINUE; END IF;

    -- Path scaling: min(1, canonical / path_length)
    v_path_factor := LEAST(1.0, v_canonical_path::numeric / GREATEST(v_building.path_length, 1));
    v_produced := FLOOR(v_elapsed_min * v_building.output_rate * v_path_factor);
    IF v_produced > 0 THEN
      INSERT INTO public.inventories (player_id, resource_key, quantity)
      VALUES (v_uid, v_building.output_resource_key, v_produced)
      ON CONFLICT (player_id, resource_key)
      DO UPDATE SET quantity = inventories.quantity + v_produced, updated_at = now();
      v_total_produced := v_total_produced + v_produced;
    END IF;
    UPDATE public.buildings SET last_processed_at = now() WHERE id = v_building.id;
  END LOOP;

  UPDATE public.buildings b SET last_processed_at = now()
  FROM public.building_types bt
  WHERE bt.key = b.building_type_key
    AND b.player_id = v_uid AND b.status = 'active' AND bt.category = 'extractor'
    AND NOT (b.id = ANY(v_staffed_ids));

  -- ── PRODUCTION: processors (staffed AND road-connected) ──
  FOR v_building IN
    SELECT b.id, b.last_processed_at,
           bt.input_resource_key, bt.input_rate,
           bt.output_resource_key, bt.output_rate
    FROM public.buildings b
    JOIN public.building_types bt ON bt.key = b.building_type_key
    WHERE b.player_id = v_uid AND b.status = 'active' AND bt.category = 'processor'
      AND b.id = ANY(v_staffed_ids)
    FOR UPDATE OF b
  LOOP
    v_elapsed_min := EXTRACT(EPOCH FROM (now() - v_building.last_processed_at)) / 60.0;
    IF v_elapsed_min < 0.1 THEN CONTINUE; END IF;

    SELECT COALESCE(quantity, 0) INTO v_available
    FROM public.inventories
    WHERE player_id = v_uid AND resource_key = v_building.input_resource_key;
    IF v_available IS NULL THEN v_available := 0; END IF;

    IF v_building.input_rate > 0 THEN
      v_actual_min := LEAST(v_elapsed_min, v_available / v_building.input_rate);
    ELSE
      v_actual_min := v_elapsed_min;
    END IF;

    v_consumed := FLOOR(v_actual_min * v_building.input_rate);
    v_produced := FLOOR(v_actual_min * v_building.output_rate);

    IF v_consumed > 0 AND v_produced > 0 THEN
      UPDATE public.inventories
      SET quantity = quantity - v_consumed, updated_at = now()
      WHERE player_id = v_uid AND resource_key = v_building.input_resource_key;

      INSERT INTO public.inventories (player_id, resource_key, quantity)
      VALUES (v_uid, v_building.output_resource_key, v_produced)
      ON CONFLICT (player_id, resource_key)
      DO UPDATE SET quantity = inventories.quantity + v_produced, updated_at = now();
      v_total_produced := v_total_produced + v_produced;
    END IF;
    UPDATE public.buildings SET last_processed_at = now() WHERE id = v_building.id;
  END LOOP;

  -- ── HOUSING EVOLUTION ─────────────────────────────────
  FOR v_house IN
    SELECT b.id, b.x, b.y, b.housing_tier, b.last_processed_at
    FROM public.buildings b
    JOIN public.building_types bt ON bt.key = b.building_type_key
    WHERE b.player_id = v_uid AND b.status = 'active' AND bt.category = 'housing'
    FOR UPDATE OF b
  LOOP
    v_has_road := public.has_road_access(v_uid, v_house.x, v_house.y);
    SELECT * INTO v_cur_tier FROM public.housing_tier_config WHERE tier = v_house.housing_tier;
    SELECT * INTO v_next_tier FROM public.housing_tier_config WHERE tier = v_house.housing_tier + 1;
    SELECT * INTO v_prev_tier FROM public.housing_tier_config WHERE tier = v_house.housing_tier - 1;
    v_elapsed_secs := EXTRACT(EPOCH FROM (now() - v_house.last_processed_at));

    v_should_upgrade := v_next_tier IS NOT NULL
      AND v_has_road
      AND (NOT v_next_tier.needs_road OR v_has_road)
      AND v_elapsed_secs >= COALESCE(v_cur_tier.upgrade_secs, 60);
    v_should_devolve := v_cur_tier IS NOT NULL
      AND v_cur_tier.needs_road
      AND NOT v_has_road
      AND v_elapsed_secs >= COALESCE(v_cur_tier.devolve_secs, 30);

    IF v_should_upgrade THEN
      UPDATE public.buildings
      SET housing_tier = housing_tier + 1, last_processed_at = now()
      WHERE id = v_house.id;
      v_evolution_events := v_evolution_events || jsonb_build_object(
        'building_id', v_house.id, 'event', 'upgrade',
        'from_tier', v_house.housing_tier, 'to_tier', v_house.housing_tier + 1
      )::json;
    ELSIF v_should_devolve THEN
      UPDATE public.buildings
      SET housing_tier = housing_tier - 1, last_processed_at = now()
      WHERE id = v_house.id;
      v_evolution_events := v_evolution_events || jsonb_build_object(
        'building_id', v_house.id, 'event', 'devolve',
        'from_tier', v_house.housing_tier, 'to_tier', v_house.housing_tier - 1
      )::json;
    END IF;
  END LOOP;

  -- ── FINAL UPDATE ──────────────────────────────────────
  SELECT 5 + COALESCE(SUM(htc.workers), 0) INTO v_worker_supply
  FROM public.buildings b
  JOIN public.building_types bt ON bt.key = b.building_type_key
  JOIN public.housing_tier_config htc ON htc.tier = b.housing_tier
  WHERE b.player_id = v_uid AND b.status = 'active' AND bt.category = 'housing'
    AND (NOT htc.needs_road OR public.has_road_access(v_uid, b.x, b.y));

  SELECT COALESCE(SUM(bt.worker_cost), 0) INTO v_workers_needed
  FROM public.buildings b
  JOIN public.building_types bt ON bt.key = b.building_type_key
  WHERE b.player_id = v_uid AND b.status = 'active'
    AND (
      bt.category = 'extractor'
      OR (bt.category = 'processor' AND public.has_road_access(v_uid, b.x, b.y))
    );

  UPDATE public.player_profiles
  SET worker_capacity = v_worker_supply,
      workers_used = LEAST(v_worker_supply, v_workers_needed)
  WHERE id = v_uid
  RETURNING money, workers_used, worker_capacity INTO v_player;

  RETURN json_build_object(
    'total_produced', v_total_produced,
    'money', v_player.money,
    'workers_used', v_player.workers_used,
    'worker_capacity', v_player.worker_capacity,
    'workers_needed', v_workers_needed,
    'labor_shortage', v_workers_needed > v_worker_supply,
    'unstaffed_count', v_unstaffed_count,
    'evolution_events', array_to_json(v_evolution_events),
    'inventory', COALESCE(
      (SELECT json_object_agg(resource_key, quantity)
       FROM public.inventories WHERE player_id = v_uid),
      '{}'::json
    )
  );
END;
$$;

-- ────────────────────────────────────────────────────────────
-- 8. PERMISSIONS
-- ────────────────────────────────────────────────────────────

GRANT EXECUTE ON FUNCTION public.find_nearest_unclaimed_resource(uuid, integer, integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.verify_extractor_path(uuid, integer, integer, integer, integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.recompute_extractor_paths(uuid) TO authenticated;
