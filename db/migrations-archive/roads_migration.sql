-- ============================================================
-- City Builder - Roads Migration (Phase 1)
-- ============================================================
-- Run AFTER the Housing & Labor migration is in place.
-- Adds: road building type, road access checks for housing
--        and processors, extractors exempt.
-- ============================================================

-- ────────────────────────────────────────────────────────────
-- 1. SCHEMA CHANGES
-- ────────────────────────────────────────────────────────────

-- Allow 'road' as a building category
ALTER TABLE public.building_types
  DROP CONSTRAINT IF EXISTS building_types_category_check;
ALTER TABLE public.building_types
  ADD CONSTRAINT building_types_category_check
  CHECK (category IN ('extractor', 'processor', 'housing', 'road'));

-- ────────────────────────────────────────────────────────────
-- 2. SEED ROAD BUILDING TYPE
-- ────────────────────────────────────────────────────────────

-- Roads are industry 'common' — available to all players.
-- Cheap ($5), no workers, no production.
INSERT INTO public.building_types (
  key, name, tier, industry_key, category, build_cost, worker_cost,
  input_resource_key, input_rate, output_resource_key, output_rate,
  workers_provided
) VALUES (
  'road', 'Road', 1, 'common', 'road', 5, 0,
  NULL, 0, NULL, 0, 0
)
ON CONFLICT (key) DO UPDATE SET
  name = EXCLUDED.name,
  build_cost = EXCLUDED.build_cost,
  category = EXCLUDED.category,
  worker_cost = EXCLUDED.worker_cost,
  workers_provided = EXCLUDED.workers_provided;

-- ────────────────────────────────────────────────────────────
-- 3. HELPER: check if a building has road access
-- ────────────────────────────────────────────────────────────
-- A building has road access if any orthogonal neighbor tile
-- contains a road building (any player's road counts).

CREATE OR REPLACE FUNCTION public.has_road_access(p_x integer, p_y integer)
RETURNS boolean LANGUAGE sql STABLE AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.buildings b
    JOIN public.building_types bt ON bt.key = b.building_type_key
    WHERE bt.category = 'road' AND b.status = 'active'
      AND (
        (b.x = p_x - 1 AND b.y = p_y)
        OR (b.x = p_x + 1 AND b.y = p_y)
        OR (b.x = p_x AND b.y = p_y - 1)
        OR (b.x = p_x AND b.y = p_y + 1)
      )
  );
$$;

-- ────────────────────────────────────────────────────────────
-- 4. UPDATED RPC: place_building
-- ────────────────────────────────────────────────────────────
-- Changes:
--   * Roads can be placed on any buildable empty tile
--   * Worker supply now only counts housing with road access
--   * Workers needed now only counts processors with road access
--     (extractors are exempt from road requirement)

CREATE OR REPLACE FUNCTION public.place_building(p_tile_id uuid, p_building_type_key text)
RETURNS json LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_bt record;
  v_tile record;
  v_player record;
  v_building_id uuid;
  v_worker_supply integer;
  v_workers_needed integer;
BEGIN
  SELECT * INTO v_bt FROM public.building_types WHERE key = p_building_type_key AND is_active;
  IF NOT FOUND THEN RAISE EXCEPTION 'Unknown building type'; END IF;

  SELECT * INTO v_player FROM public.player_profiles WHERE id = v_uid;
  IF NOT FOUND THEN RAISE EXCEPTION 'Player not found'; END IF;

  -- Industry check: allow 'common' buildings for any player
  IF v_bt.industry_key <> 'common' AND v_bt.industry_key <> v_player.industry_key THEN
    RAISE EXCEPTION 'You can only place buildings for your chosen industry';
  END IF;

  IF v_player.money < v_bt.build_cost THEN
    RAISE EXCEPTION 'Not enough money (need %, have %)', v_bt.build_cost, v_player.money;
  END IF;

  SELECT * INTO v_tile FROM public.map_tiles WHERE id = p_tile_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Tile not found'; END IF;
  IF NOT v_tile.buildable THEN RAISE EXCEPTION 'Tile is not buildable'; END IF;
  IF v_tile.occupied_building_id IS NOT NULL THEN RAISE EXCEPTION 'Tile already occupied'; END IF;

  -- Placement rules by category
  IF v_bt.category = 'extractor' THEN
    IF v_tile.resource_node_key IS NULL OR v_tile.resource_node_key != v_bt.output_resource_key THEN
      RAISE EXCEPTION 'Extractor must be placed on a matching resource tile';
    END IF;
  END IF;
  -- Housing, processors, and roads can be placed on any buildable empty tile

  INSERT INTO public.buildings (player_id, building_type_key, tile_id, x, y)
  VALUES (v_uid, p_building_type_key, p_tile_id, v_tile.x, v_tile.y)
  RETURNING id INTO v_building_id;

  UPDATE public.map_tiles SET occupied_building_id = v_building_id WHERE id = p_tile_id;

  -- Recompute labor stats (includes the just-placed building)
  -- Only count housing with road access for worker supply
  SELECT 5 + COALESCE(SUM(bt2.workers_provided), 0) INTO v_worker_supply
  FROM public.buildings b2
  JOIN public.building_types bt2 ON bt2.key = b2.building_type_key
  WHERE b2.player_id = v_uid AND b2.status = 'active' AND bt2.category = 'housing'
    AND public.has_road_access(b2.x, b2.y);

  -- Workers needed: extractors always count, processors only if road access
  SELECT COALESCE(SUM(bt2.worker_cost), 0) INTO v_workers_needed
  FROM public.buildings b2
  JOIN public.building_types bt2 ON bt2.key = b2.building_type_key
  WHERE b2.player_id = v_uid AND b2.status = 'active'
    AND (
      bt2.category = 'extractor'
      OR (bt2.category = 'processor' AND public.has_road_access(b2.x, b2.y))
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
-- 5. UPDATED RPC: process_production
-- ────────────────────────────────────────────────────────────
-- Changes:
--   * Housing only provides workers if it has road access
--   * Processors only produce if they have road access
--   * Extractors are exempt from road requirement
--   * Disconnected processors have timestamps advanced (no catch-up)

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
BEGIN
  -- ── LABOR ALLOCATION ──────────────────────────────────
  -- Count workers from housing buildings WITH road access only
  SELECT COALESCE(SUM(bt.workers_provided), 0) INTO v_housing_workers
  FROM public.buildings b
  JOIN public.building_types bt ON bt.key = b.building_type_key
  WHERE b.player_id = v_uid AND b.status = 'active' AND bt.category = 'housing'
    AND public.has_road_access(b.x, b.y);

  v_worker_supply := v_base_workers + v_housing_workers;
  v_workers_remaining := v_worker_supply;
  v_staffed_ids := ARRAY[]::uuid[];

  -- Allocate workers to production buildings (oldest built first)
  -- Extractors are always eligible; processors only with road access
  FOR v_building IN
    SELECT b.id, bt.worker_cost
    FROM public.buildings b
    JOIN public.building_types bt ON bt.key = b.building_type_key
    WHERE b.player_id = v_uid AND b.status = 'active'
      AND (
        bt.category = 'extractor'
        OR (bt.category = 'processor' AND public.has_road_access(b.x, b.y))
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

  -- ── PRODUCTION: extractors (staffed only) ─────────────
  FOR v_building IN
    SELECT b.id, b.last_processed_at, bt.output_resource_key, bt.output_rate
    FROM public.buildings b
    JOIN public.building_types bt ON bt.key = b.building_type_key
    WHERE b.player_id = v_uid AND b.status = 'active' AND bt.category = 'extractor'
      AND b.id = ANY(v_staffed_ids)
    FOR UPDATE OF b
  LOOP
    v_elapsed_min := EXTRACT(EPOCH FROM (now() - v_building.last_processed_at)) / 60.0;
    IF v_elapsed_min < 0.1 THEN CONTINUE; END IF;

    v_produced := FLOOR(v_elapsed_min * v_building.output_rate);
    IF v_produced > 0 THEN
      INSERT INTO public.inventories (player_id, resource_key, quantity)
      VALUES (v_uid, v_building.output_resource_key, v_produced)
      ON CONFLICT (player_id, resource_key)
      DO UPDATE SET quantity = inventories.quantity + v_produced, updated_at = now();

      v_total_produced := v_total_produced + v_produced;
    END IF;

    UPDATE public.buildings SET last_processed_at = now() WHERE id = v_building.id;
  END LOOP;

  -- Advance timestamp for unstaffed extractors (no catch-up)
  UPDATE public.buildings b SET last_processed_at = now()
  FROM public.building_types bt
  WHERE bt.key = b.building_type_key
    AND b.player_id = v_uid AND b.status = 'active' AND bt.category = 'extractor'
    AND NOT (b.id = ANY(v_staffed_ids));

  -- ── PRODUCTION: processors (staffed AND road-connected only) ──
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

  -- Advance timestamp for unstaffed/disconnected processors (no catch-up)
  -- This catches both labor-unstaffed and road-disconnected processors,
  -- since disconnected processors are excluded from the staffed loop above.
  UPDATE public.buildings b SET last_processed_at = now()
  FROM public.building_types bt
  WHERE bt.key = b.building_type_key
    AND b.player_id = v_uid AND b.status = 'active' AND bt.category = 'processor'
    AND NOT (b.id = ANY(v_staffed_ids));

  -- ── UPDATE PROFILE with computed labor stats ──────────
  UPDATE public.player_profiles
  SET worker_capacity = v_worker_supply,
      workers_used = LEAST(v_worker_supply, v_workers_needed)
  WHERE id = v_uid;

  SELECT money, workers_used, worker_capacity INTO v_player
  FROM public.player_profiles WHERE id = v_uid;

  RETURN json_build_object(
    'total_produced', v_total_produced,
    'money', v_player.money,
    'workers_used', v_player.workers_used,
    'worker_capacity', v_player.worker_capacity,
    'workers_needed', v_workers_needed,
    'labor_shortage', v_workers_needed > v_worker_supply,
    'unstaffed_count', v_unstaffed_count,
    'inventory', COALESCE(
      (SELECT json_object_agg(resource_key, quantity)
       FROM public.inventories WHERE player_id = v_uid),
      '{}'::json
    )
  );
END;
$$;

-- ────────────────────────────────────────────────────────────
-- 6. PERMISSIONS
-- ────────────────────────────────────────────────────────────
-- place_building and process_production are replaced in-place;
-- existing GRANT statements still apply.
-- Grant execute on new helper function.
GRANT EXECUTE ON FUNCTION public.has_road_access(integer, integer) TO authenticated;
