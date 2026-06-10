-- ============================================================
-- City Builder - Housing Evolution Migration (Phase A)
-- ============================================================
-- Run AFTER the Roads migration is in place.
-- Adds: housing tiers (Shanty=0, Mud Hut=1), auto-upgrade/devolve
--        based on road access, tier-aware worker supply.
-- ============================================================

-- ────────────────────────────────────────────────────────────
-- 1. SCHEMA CHANGES
-- ────────────────────────────────────────────────────────────

-- Housing tier: 0 = shanty (basic), 1 = mud hut (current full house)
-- Existing houses default to tier 1 (they were placed as full houses).
ALTER TABLE public.buildings
  ADD COLUMN IF NOT EXISTS housing_tier integer NOT NULL DEFAULT 1;

-- Tracks when conditions for tier change were first detected.
-- NULL = house is stable at current tier.
ALTER TABLE public.buildings
  ADD COLUMN IF NOT EXISTS evolution_eligible_at timestamptz DEFAULT NULL;

-- ────────────────────────────────────────────────────────────
-- 2. HOUSING EVOLUTION CONFIG TABLE
-- ────────────────────────────────────────────────────────────
-- Data-driven tier definitions so tuning doesn't require code changes.

CREATE TABLE IF NOT EXISTS public.housing_tier_config (
  tier          integer PRIMARY KEY,
  name          text NOT NULL,
  label         text NOT NULL DEFAULT '?',
  workers       integer NOT NULL DEFAULT 0,
  needs_road    boolean NOT NULL DEFAULT false,
  upgrade_secs  integer NOT NULL DEFAULT 30,
  devolve_secs  integer NOT NULL DEFAULT 60
);

-- Seed tier definitions
INSERT INTO public.housing_tier_config (tier, name, label, workers, needs_road, upgrade_secs, devolve_secs)
VALUES
  (0, 'Shanty',   'S', 2, false, 30, 60),
  (1, 'Mud Hut',  'H', 6, true,  30, 60)
ON CONFLICT (tier) DO UPDATE SET
  name = EXCLUDED.name,
  label = EXCLUDED.label,
  workers = EXCLUDED.workers,
  needs_road = EXCLUDED.needs_road,
  upgrade_secs = EXCLUDED.upgrade_secs,
  devolve_secs = EXCLUDED.devolve_secs;

-- RLS: allow authenticated users to read config
ALTER TABLE public.housing_tier_config ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Anyone can read housing tier config" ON public.housing_tier_config;
CREATE POLICY "Anyone can read housing tier config"
  ON public.housing_tier_config FOR SELECT TO authenticated
  USING (true);

-- ────────────────────────────────────────────────────────────
-- 3. UPDATED RPC: place_building
-- ────────────────────────────────────────────────────────────
-- Changes:
--   * New houses start at tier 0 (shanty)
--   * Worker supply uses tier-aware calculation

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

  IF v_bt.category = 'extractor' THEN
    IF v_tile.resource_node_key IS NULL OR v_tile.resource_node_key != v_bt.output_resource_key THEN
      RAISE EXCEPTION 'Extractor must be placed on a matching resource tile';
    END IF;
  END IF;

  -- New houses start at tier 0 (shanty); non-housing keeps default
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

  -- Tier-aware worker supply:
  -- Each housing tier defines its own worker count and road requirement
  SELECT 5 + COALESCE(SUM(htc.workers), 0) INTO v_worker_supply
  FROM public.buildings b2
  JOIN public.building_types bt2 ON bt2.key = b2.building_type_key
  JOIN public.housing_tier_config htc ON htc.tier = b2.housing_tier
  WHERE b2.player_id = v_uid AND b2.status = 'active' AND bt2.category = 'housing'
    AND (NOT htc.needs_road OR public.has_road_access(b2.x, b2.y));

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
-- 4. UPDATED RPC: process_production
-- ────────────────────────────────────────────────────────────
-- Changes:
--   * Tier-aware worker supply from housing
--   * Housing evolution checks (upgrade/devolve) after production
--   * Returns evolution events for client display

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
  -- Housing evolution
  v_house record;
  v_has_road boolean;
  v_cur_tier record;   -- current tier config
  v_next_tier record;  -- tier+1 config (for upgrade check)
  v_prev_tier record;  -- tier-1 config (for devolve check)
  v_elapsed_secs numeric;
  v_evolution_events json[] := ARRAY[]::json[];
  v_should_upgrade boolean;
  v_should_devolve boolean;
BEGIN
  -- ── LABOR ALLOCATION (tier-aware) ─────────────────────
  SELECT COALESCE(SUM(htc.workers), 0) INTO v_housing_workers
  FROM public.buildings b
  JOIN public.building_types bt ON bt.key = b.building_type_key
  JOIN public.housing_tier_config htc ON htc.tier = b.housing_tier
  WHERE b.player_id = v_uid AND b.status = 'active' AND bt.category = 'housing'
    AND (NOT htc.needs_road OR public.has_road_access(b.x, b.y));

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

  UPDATE public.buildings b SET last_processed_at = now()
  FROM public.building_types bt
  WHERE bt.key = b.building_type_key
    AND b.player_id = v_uid AND b.status = 'active' AND bt.category = 'processor'
    AND NOT (b.id = ANY(v_staffed_ids));

  -- ── HOUSING EVOLUTION ─────────────────────────────────
  -- For each house, check upgrade and devolve independently.
  -- Priority: devolve wins if both somehow apply (shouldn't happen).
  FOR v_house IN
    SELECT b.id, b.x, b.y, b.housing_tier, b.evolution_eligible_at
    FROM public.buildings b
    JOIN public.building_types bt ON bt.key = b.building_type_key
    WHERE b.player_id = v_uid AND b.status = 'active' AND bt.category = 'housing'
    FOR UPDATE OF b
  LOOP
    v_has_road := public.has_road_access(v_house.x, v_house.y);
    SELECT * INTO v_cur_tier FROM public.housing_tier_config WHERE tier = v_house.housing_tier;

    -- Determine upgrade/devolve eligibility
    v_should_upgrade := false;
    v_should_devolve := false;

    -- Check devolve: current tier needs aren't met
    IF v_house.housing_tier > 0 AND v_cur_tier.needs_road AND NOT v_has_road THEN
      v_should_devolve := true;
    END IF;

    -- Check upgrade: next tier's needs are met (only if not devolving)
    IF NOT v_should_devolve THEN
      SELECT * INTO v_next_tier FROM public.housing_tier_config WHERE tier = v_house.housing_tier + 1;
      IF v_next_tier IS NOT NULL THEN
        IF (NOT v_next_tier.needs_road OR v_has_road) THEN
          v_should_upgrade := true;
        END IF;
      END IF;
    END IF;

    -- Apply evolution timers
    IF v_should_devolve THEN
      IF v_house.evolution_eligible_at IS NULL THEN
        -- Start devolve timer
        UPDATE public.buildings SET evolution_eligible_at = now() WHERE id = v_house.id;
      ELSE
        v_elapsed_secs := EXTRACT(EPOCH FROM (now() - v_house.evolution_eligible_at));
        IF v_elapsed_secs >= v_cur_tier.devolve_secs THEN
          -- DEVOLVE
          SELECT * INTO v_prev_tier FROM public.housing_tier_config WHERE tier = v_house.housing_tier - 1;
          UPDATE public.buildings
          SET housing_tier = v_house.housing_tier - 1, evolution_eligible_at = NULL
          WHERE id = v_house.id;
          v_evolution_events := v_evolution_events || json_build_object(
            'building_id', v_house.id, 'x', v_house.x, 'y', v_house.y,
            'old_tier', v_house.housing_tier, 'new_tier', v_house.housing_tier - 1,
            'old_name', v_cur_tier.name, 'new_name', COALESCE(v_prev_tier.name, 'Ruins'),
            'direction', 'devolve'
          );
        END IF;
      END IF;

    ELSIF v_should_upgrade THEN
      IF v_house.evolution_eligible_at IS NULL THEN
        -- Start upgrade timer
        UPDATE public.buildings SET evolution_eligible_at = now() WHERE id = v_house.id;
      ELSE
        v_elapsed_secs := EXTRACT(EPOCH FROM (now() - v_house.evolution_eligible_at));
        IF v_elapsed_secs >= v_cur_tier.upgrade_secs THEN
          -- UPGRADE
          UPDATE public.buildings
          SET housing_tier = v_house.housing_tier + 1, evolution_eligible_at = NULL
          WHERE id = v_house.id;
          v_evolution_events := v_evolution_events || json_build_object(
            'building_id', v_house.id, 'x', v_house.x, 'y', v_house.y,
            'old_tier', v_house.housing_tier, 'new_tier', v_house.housing_tier + 1,
            'old_name', v_cur_tier.name, 'new_name', v_next_tier.name,
            'direction', 'upgrade'
          );
        END IF;
      END IF;

    ELSE
      -- House is stable; clear any pending timer
      IF v_house.evolution_eligible_at IS NOT NULL THEN
        UPDATE public.buildings SET evolution_eligible_at = NULL WHERE id = v_house.id;
      END IF;
    END IF;
  END LOOP;

  -- ── RECOMPUTE LABOR after evolution ───────────────────
  SELECT COALESCE(SUM(htc.workers), 0) INTO v_housing_workers
  FROM public.buildings b
  JOIN public.building_types bt ON bt.key = b.building_type_key
  JOIN public.housing_tier_config htc ON htc.tier = b.housing_tier
  WHERE b.player_id = v_uid AND b.status = 'active' AND bt.category = 'housing'
    AND (NOT htc.needs_road OR public.has_road_access(b.x, b.y));

  v_worker_supply := v_base_workers + v_housing_workers;

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
    ),
    'evolution_events', COALESCE(array_to_json(v_evolution_events), '[]'::json)
  );
END;
$$;

-- ────────────────────────────────────────────────────────────
-- 5. PERMISSIONS
-- ────────────────────────────────────────────────────────────
GRANT SELECT ON public.housing_tier_config TO authenticated;
