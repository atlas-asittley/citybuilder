-- ============================================================
-- City Builder — District Scaffolding (M1)
-- ============================================================
-- Run AFTER all prior migrations. Implements per-player district
-- ownership of map chunks (15×15 tile blocks) and the spiral
-- allocation system that lets new players join without blocking
-- existing players.
--
-- See GAME_DESIGN.md for the design rationale.
--
-- ★ DESTRUCTIVE: Section 8 wipes existing buildings, tiles, and
--   district claims, then re-allocates a fresh starting chunk for
--   each existing player. This is intentional — the redesign
--   changes how tiles are owned, and the game currently has only
--   one player whose data can be safely re-seeded.
--
--   If you run this against a multi-player environment, comment
--   out section 8 and write a migration that preserves existing
--   buildings.
-- ============================================================

-- ────────────────────────────────────────────────────────────
-- 1. SCHEMA CHANGES
-- ────────────────────────────────────────────────────────────

-- Per-tile ownership. NULL = wilderness (visible but unbuildable).
ALTER TABLE public.map_tiles
  ADD COLUMN IF NOT EXISTS owner_player_id uuid
    REFERENCES public.player_profiles(id) ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS idx_map_tiles_owner
  ON public.map_tiles (owner_player_id) WHERE owner_player_id IS NOT NULL;

-- Per-player tracking: home position and chunk count
ALTER TABLE public.player_profiles
  ADD COLUMN IF NOT EXISTS chunks_owned integer NOT NULL DEFAULT 0;
ALTER TABLE public.player_profiles
  ADD COLUMN IF NOT EXISTS home_x integer;
ALTER TABLE public.player_profiles
  ADD COLUMN IF NOT EXISTS home_y integer;

-- Chunk-level ownership table (faster than scanning per-tile)
CREATE TABLE IF NOT EXISTS public.district_chunks (
  chunk_x integer NOT NULL,
  chunk_y integer NOT NULL,
  owner_player_id uuid NOT NULL
    REFERENCES public.player_profiles(id) ON DELETE CASCADE,
  allocated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (chunk_x, chunk_y)
);
CREATE INDEX IF NOT EXISTS idx_district_chunks_owner
  ON public.district_chunks (owner_player_id);

ALTER TABLE public.district_chunks ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS district_chunks_read_all ON public.district_chunks;
CREATE POLICY district_chunks_read_all
  ON public.district_chunks FOR SELECT USING (true);

-- ────────────────────────────────────────────────────────────
-- 2. SPIRAL ALLOCATOR
-- ────────────────────────────────────────────────────────────
-- Returns the next unowned chunk slot, walking outward from origin
-- in concentric Chebyshev rings. Order: (0,0), then radius-1 ring
-- (8 cells), radius-2 ring (16 cells), etc. Each ring is iterated
-- deterministically: x from −r to +r, y from −r to +r, taking only
-- the cells where |x|=r OR |y|=r.
--
-- Safety cap of radius 200 = ~160k chunks ~= 36 million tiles. If
-- we ever hit that, we have bigger problems.
-- ────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.next_unowned_chunk_slot()
RETURNS TABLE(chunk_x integer, chunk_y integer)
LANGUAGE plpgsql AS $$
DECLARE
  v_radius integer := 0;
  v_x integer;
  v_y integer;
BEGIN
  -- Origin first.
  -- Note: column references must be table-qualified (dc.chunk_x) because the
  -- OUT parameters of this function are also named chunk_x/chunk_y, which
  -- would otherwise cause "column reference is ambiguous" errors.
  IF NOT EXISTS (
    SELECT 1 FROM public.district_chunks dc
    WHERE dc.chunk_x = 0 AND dc.chunk_y = 0
  ) THEN
    chunk_x := 0; chunk_y := 0;
    RETURN NEXT;
    RETURN;
  END IF;

  v_radius := 1;
  WHILE v_radius < 200 LOOP
    FOR v_x IN -v_radius..v_radius LOOP
      FOR v_y IN -v_radius..v_radius LOOP
        -- Only cells on the ring (not interior, those were checked at smaller radii)
        IF ABS(v_x) = v_radius OR ABS(v_y) = v_radius THEN
          IF NOT EXISTS (
            SELECT 1 FROM public.district_chunks dc
            WHERE dc.chunk_x = v_x AND dc.chunk_y = v_y
          ) THEN
            chunk_x := v_x; chunk_y := v_y;
            RETURN NEXT;
            RETURN;
          END IF;
        END IF;
      END LOOP;
    END LOOP;
    v_radius := v_radius + 1;
  END LOOP;
  RAISE EXCEPTION 'Could not find unowned chunk slot within safety radius';
END;
$$;

-- ────────────────────────────────────────────────────────────
-- 3. CHUNK ALLOCATION
-- ────────────────────────────────────────────────────────────
-- Creates 15×15 tiles for a chunk, marks ownership, seeds ~8% of
-- the tiles as resource nodes of the player's industry. If this
-- is the player's FIRST chunk, also stamps the chunk's geometric
-- center as their city_center (unbuildable, the seed for road
-- network connectivity).
--
-- Idempotent on re-call for the same (chunk_x, chunk_y) — the
-- precondition check rejects duplicates.
-- ────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.allocate_district_chunk(
  p_player_id uuid,
  p_chunk_x integer,
  p_chunk_y integer
)
RETURNS json
LANGUAGE plpgsql AS $$
DECLARE
  v_player record;
  v_x_start integer := p_chunk_x * 15;
  v_y_start integer := p_chunk_y * 15;
  v_dx integer;
  v_dy integer;
  v_resource_key text;
  v_resource_count integer;
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

  v_resource_key := v_player.industry_key;
  v_is_first_chunk := (v_player.chunks_owned = 0);

  -- Insert tiles. ~8% chance per tile of being a resource node.
  FOR v_dx IN 0..14 LOOP
    FOR v_dy IN 0..14 LOOP
      INSERT INTO public.map_tiles (
        x, y, terrain_type, resource_node_key, buildable, owner_player_id
      ) VALUES (
        v_x_start + v_dx,
        v_y_start + v_dy,
        'ground',
        CASE WHEN random() < 0.08 THEN v_resource_key ELSE NULL END,
        true,
        p_player_id
      )
      ON CONFLICT (x, y) DO UPDATE SET
        owner_player_id = p_player_id,
        terrain_type = 'ground',
        buildable = true,
        resource_node_key = COALESCE(
          public.map_tiles.resource_node_key,
          EXCLUDED.resource_node_key
        );
    END LOOP;
  END LOOP;

  -- Stamp city center for the player's first chunk
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

  -- Record chunk ownership and bump count
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

-- ────────────────────────────────────────────────────────────
-- 4. UPDATED choose_industry
-- ────────────────────────────────────────────────────────────
-- Fixes the stale ('timber','stone') validator (now allows all 4
-- current industries). On signup, allocates the player's first
-- chunk via spiral allocation.
-- ────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.choose_industry(
  p_display_name text,
  p_industry_key text
)
RETURNS json LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_profile record;
  v_chunk record;
  v_chunks_owned integer;
BEGIN
  IF p_industry_key NOT IN ('timber', 'stone', 'grain', 'clay') THEN
    RAISE EXCEPTION 'Invalid industry. Choose timber, stone, grain, or clay.';
  END IF;
  IF length(trim(p_display_name)) < 2 THEN
    RAISE EXCEPTION 'Display name must be at least 2 characters.';
  END IF;

  INSERT INTO public.player_profiles (
    id, display_name, industry_key, money, worker_capacity, workers_used, chunks_owned
  ) VALUES (
    v_uid, trim(p_display_name), p_industry_key, 500, 5, 0, 0
  )
  ON CONFLICT (id) DO UPDATE SET
    display_name = trim(EXCLUDED.display_name),
    industry_key = EXCLUDED.industry_key,
    updated_at = now();

  -- Seed inventory rows for every known resource (zero quantity).
  -- Idempotent — won't clobber existing balances.
  INSERT INTO public.inventories (player_id, resource_key, quantity) VALUES
    (v_uid, 'timber', 0), (v_uid, 'lumber', 0),
    (v_uid, 'stone', 0),  (v_uid, 'brick', 0),
    (v_uid, 'grain', 0),  (v_uid, 'flour', 0),
    (v_uid, 'clay', 0),   (v_uid, 'pottery', 0),
    (v_uid, 'bread', 0),  (v_uid, 'furniture', 0),
    (v_uid, 'statuary', 0)
  ON CONFLICT (player_id, resource_key) DO NOTHING;

  -- Allocate first chunk if the player doesn't have one yet
  SELECT chunks_owned INTO v_chunks_owned
  FROM public.player_profiles WHERE id = v_uid;

  IF v_chunks_owned = 0 THEN
    SELECT * INTO v_chunk FROM public.next_unowned_chunk_slot();
    PERFORM public.allocate_district_chunk(v_uid, v_chunk.chunk_x, v_chunk.chunk_y);
  END IF;

  SELECT * INTO v_profile FROM public.player_profiles WHERE id = v_uid;

  RETURN json_build_object(
    'id', v_profile.id,
    'display_name', v_profile.display_name,
    'industry_key', v_profile.industry_key,
    'money', v_profile.money,
    'worker_capacity', v_profile.worker_capacity,
    'workers_used', v_profile.workers_used,
    'chunks_owned', v_profile.chunks_owned,
    'home_x', v_profile.home_x,
    'home_y', v_profile.home_y
  );
END;
$$;

-- ────────────────────────────────────────────────────────────
-- 5. expand_district RPC
-- ────────────────────────────────────────────────────────────
-- Costs base × chunks_owned^2 (quadratic curve). Allocates the
-- next unowned chunk slot in spiral order. Future revision could
-- pick the chunk adjacent to the player's existing district, but
-- spiral allocation is simpler and avoids contested neighbors.
-- ────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.expand_district()
RETURNS json LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_player record;
  v_cost integer;
  v_chunk record;
  v_alloc json;
  v_base_cost integer := 500;
BEGIN
  SELECT * INTO v_player FROM public.player_profiles WHERE id = v_uid;
  IF NOT FOUND THEN RAISE EXCEPTION 'Player not found'; END IF;

  v_cost := v_base_cost * v_player.chunks_owned * v_player.chunks_owned;

  IF v_player.money < v_cost THEN
    RAISE EXCEPTION 'Not enough money to expand (need %, have %)',
      v_cost, v_player.money;
  END IF;

  SELECT * INTO v_chunk FROM public.next_unowned_chunk_slot();
  v_alloc := public.allocate_district_chunk(v_uid, v_chunk.chunk_x, v_chunk.chunk_y);

  UPDATE public.player_profiles
  SET money = money - v_cost
  WHERE id = v_uid
  RETURNING * INTO v_player;

  RETURN json_build_object(
    'chunk_x', v_chunk.chunk_x,
    'chunk_y', v_chunk.chunk_y,
    'cost', v_cost,
    'money', v_player.money,
    'chunks_owned', v_player.chunks_owned,
    'allocation', v_alloc
  );
END;
$$;

-- ────────────────────────────────────────────────────────────
-- 6. has_road_access — multiplayer-aware overload
-- ────────────────────────────────────────────────────────────
-- The original 2-arg function checks ANY road of ANY player. Add
-- a 3-arg overload that filters by owner. The 2-arg version is
-- preserved for compat but should be considered deprecated.
-- ────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.has_road_access(
  p_player_id uuid,
  p_x integer,
  p_y integer
)
RETURNS boolean LANGUAGE sql STABLE AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.buildings b
    JOIN public.building_types bt ON bt.key = b.building_type_key
    WHERE bt.category = 'road' AND b.status = 'active'
      AND b.player_id = p_player_id
      AND (
        (b.x = p_x - 1 AND b.y = p_y)
        OR (b.x = p_x + 1 AND b.y = p_y)
        OR (b.x = p_x AND b.y = p_y - 1)
        OR (b.x = p_x AND b.y = p_y + 1)
      )
  );
$$;

GRANT EXECUTE ON FUNCTION public.has_road_access(uuid, integer, integer) TO authenticated;

-- ────────────────────────────────────────────────────────────
-- 7. UPDATED place_building — district ownership + per-player roads
-- ────────────────────────────────────────────────────────────
-- Adds:
--   * District ownership check (rejects placement on another
--     player's tiles or on wilderness).
--   * Road connectivity uses the player's home_x/home_y instead
--     of hardcoded (7,7), and only counts the player's own roads.
--   * Worker computation calls has_road_access(player_id, x, y)
--     so a neighbor's road doesn't accidentally make YOUR housing
--     count as connected.
--
-- Everything else is preserved from
-- road_connectivity_rule_migration.sql, the prior latest version.
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
BEGIN
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

  IF v_bt.category = 'extractor' THEN
    -- M2 will replace this with road-adjacency + BFS pathfinding.
    -- For now, the existing rule is preserved so M1 ships independently.
    IF v_tile.resource_node_key IS NULL OR v_tile.resource_node_key != v_bt.output_resource_key THEN
      RAISE EXCEPTION 'Extractor must be placed on a matching resource tile';
    END IF;

  ELSIF v_bt.category = 'road' THEN
    -- Connect to player's home (city center of their first chunk) or to
    -- another of THEIR roads. Player's home is set when the first chunk
    -- is allocated; if for some reason it's null, fall back to any of
    -- their existing roads.
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

  -- Recompute the player's worker supply and demand using the
  -- per-player has_road_access overload so neighbor roads don't
  -- accidentally count.
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
    'labor_shortage', v_workers_needed > v_worker_supply
  );
END;
$$;

-- ────────────────────────────────────────────────────────────
-- 8. WIPE + RE-SEED EXISTING DATA  ★ DESTRUCTIVE ★
-- ────────────────────────────────────────────────────────────
-- Removes all current buildings, tiles, and chunk claims, then
-- re-allocates a fresh starting chunk for each existing player.
--
-- Comment this section out if you don't want this behavior.
-- ────────────────────────────────────────────────────────────

DELETE FROM public.buildings;
DELETE FROM public.map_tiles;
DELETE FROM public.district_chunks;

UPDATE public.player_profiles
SET chunks_owned = 0, home_x = NULL, home_y = NULL,
    workers_used = 0, worker_capacity = 5;

-- Re-allocate a starting chunk for every existing player, in
-- creation order so the longest-running player gets origin.
DO $$
DECLARE
  v_player record;
  v_chunk record;
BEGIN
  FOR v_player IN
    SELECT id FROM public.player_profiles ORDER BY created_at
  LOOP
    SELECT * INTO v_chunk FROM public.next_unowned_chunk_slot();
    PERFORM public.allocate_district_chunk(v_player.id, v_chunk.chunk_x, v_chunk.chunk_y);
  END LOOP;
END;
$$;

-- ────────────────────────────────────────────────────────────
-- 9. PERMISSIONS
-- ────────────────────────────────────────────────────────────

GRANT EXECUTE ON FUNCTION public.next_unowned_chunk_slot() TO authenticated;
GRANT EXECUTE ON FUNCTION public.allocate_district_chunk(uuid, integer, integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.expand_district() TO authenticated;

-- ────────────────────────────────────────────────────────────
-- 10. REALTIME
-- ────────────────────────────────────────────────────────────

ALTER PUBLICATION supabase_realtime ADD TABLE public.district_chunks;
