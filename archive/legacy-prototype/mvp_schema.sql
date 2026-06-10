-- ============================================================
-- City Builder MVP - Complete Supabase Migration
-- ============================================================
-- WARNING: This drops existing City Builder tables and replaces
-- them with the MVP schema. Back up data before running.
-- Run this in the Supabase SQL Editor.
-- ============================================================

-- Drop old tables (from previous phases)
DROP TABLE IF EXISTS public.trade_transactions CASCADE;
DROP TABLE IF EXISTS public.trader_prices CASCADE;
DROP TABLE IF EXISTS public.traders CASCADE;
DROP TABLE IF EXISTS public.inventories CASCADE;
DROP TABLE IF EXISTS public.buildings CASCADE;
DROP TABLE IF EXISTS public.map_tiles CASCADE;
DROP TABLE IF EXISTS public.building_types CASCADE;
DROP TABLE IF EXISTS public.player_profiles CASCADE;
DROP TABLE IF EXISTS public.resources CASCADE;
-- Drop legacy tables no longer needed
DROP TABLE IF EXISTS public.tiles CASCADE;
DROP TABLE IF EXISTS public.player_treasuries CASCADE;
DROP TABLE IF EXISTS public.player_inventories CASCADE;
DROP TABLE IF EXISTS public.population_state CASCADE;
DROP TABLE IF EXISTS public.districts CASCADE;
DROP TABLE IF EXISTS public.worlds CASCADE;
DROP TABLE IF EXISTS public.resource_types CASCADE;
DROP TABLE IF EXISTS public.npc_trade_partners CASCADE;
DROP TABLE IF EXISTS public.npc_trade_catalogs CASCADE;
DROP TABLE IF EXISTS public.player_market_offers CASCADE;
-- Drop old functions
DROP FUNCTION IF EXISTS public.bootstrap_player CASCADE;
DROP FUNCTION IF EXISTS public.place_building CASCADE;
DROP FUNCTION IF EXISTS public.run_production_tick CASCADE;
DROP FUNCTION IF EXISTS public.get_trade_partners CASCADE;
DROP FUNCTION IF EXISTS public.execute_npc_trade CASCADE;
DROP FUNCTION IF EXISTS public.get_market_offers CASCADE;
DROP FUNCTION IF EXISTS public.create_player_offer CASCADE;
DROP FUNCTION IF EXISTS public.fulfill_player_offer CASCADE;
DROP FUNCTION IF EXISTS public.cancel_player_offer CASCADE;
DROP FUNCTION IF EXISTS public.upgrade_housing CASCADE;
DROP FUNCTION IF EXISTS public.get_district_progress CASCADE;
DROP FUNCTION IF EXISTS public.upgrade_district CASCADE;
DROP FUNCTION IF EXISTS public.choose_industry CASCADE;
DROP FUNCTION IF EXISTS public.process_production CASCADE;
DROP FUNCTION IF EXISTS public.sell_to_trader CASCADE;

CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- ============================================================
-- 1. TABLES
-- ============================================================

CREATE TABLE public.resources (
  key text PRIMARY KEY,
  name text NOT NULL,
  kind text NOT NULL CHECK (kind IN ('raw', 'processed')),
  industry_key text NOT NULL,
  is_active boolean NOT NULL DEFAULT true
);

CREATE TABLE public.player_profiles (
  id uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  display_name text NOT NULL,
  industry_key text NOT NULL,
  money integer NOT NULL DEFAULT 500,
  worker_capacity integer NOT NULL DEFAULT 5,
  workers_used integer NOT NULL DEFAULT 0,
  color_hex text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE public.map_tiles (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  x integer NOT NULL,
  y integer NOT NULL,
  terrain_type text NOT NULL DEFAULT 'ground',
  resource_node_key text REFERENCES public.resources(key),
  buildable boolean NOT NULL DEFAULT true,
  occupied_building_id uuid UNIQUE,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (x, y)
);

CREATE TABLE public.building_types (
  key text PRIMARY KEY,
  name text NOT NULL,
  tier integer NOT NULL CHECK (tier IN (1, 2)),
  industry_key text NOT NULL,
  category text NOT NULL CHECK (category IN ('extractor', 'processor')),
  build_cost integer NOT NULL,
  worker_cost integer NOT NULL DEFAULT 1,
  input_resource_key text REFERENCES public.resources(key),
  input_rate numeric NOT NULL DEFAULT 0,
  output_resource_key text NOT NULL REFERENCES public.resources(key),
  output_rate numeric NOT NULL,
  is_active boolean NOT NULL DEFAULT true
);

CREATE TABLE public.buildings (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  player_id uuid NOT NULL REFERENCES public.player_profiles(id) ON DELETE CASCADE,
  building_type_key text NOT NULL REFERENCES public.building_types(key),
  tile_id uuid NOT NULL UNIQUE REFERENCES public.map_tiles(id) ON DELETE RESTRICT,
  x integer NOT NULL,
  y integer NOT NULL,
  status text NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'paused')),
  stored_input numeric NOT NULL DEFAULT 0,
  stored_output numeric NOT NULL DEFAULT 0,
  last_processed_at timestamptz NOT NULL DEFAULT now(),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.map_tiles
  ADD CONSTRAINT map_tiles_occupied_building_id_fkey
  FOREIGN KEY (occupied_building_id) REFERENCES public.buildings(id) ON DELETE SET NULL;

CREATE TABLE public.inventories (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  player_id uuid NOT NULL REFERENCES public.player_profiles(id) ON DELETE CASCADE,
  resource_key text NOT NULL REFERENCES public.resources(key),
  quantity numeric NOT NULL DEFAULT 0,
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (player_id, resource_key)
);

CREATE TABLE public.traders (
  key text PRIMARY KEY,
  name text NOT NULL,
  description text,
  is_active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE public.trader_prices (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  trader_key text NOT NULL REFERENCES public.traders(key) ON DELETE CASCADE,
  resource_key text NOT NULL REFERENCES public.resources(key),
  buy_price integer NOT NULL,
  is_active boolean NOT NULL DEFAULT true,
  UNIQUE (trader_key, resource_key)
);

CREATE TABLE public.trade_transactions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  player_id uuid NOT NULL REFERENCES public.player_profiles(id) ON DELETE CASCADE,
  trader_key text NOT NULL REFERENCES public.traders(key),
  resource_key text NOT NULL REFERENCES public.resources(key),
  quantity numeric NOT NULL,
  unit_price integer NOT NULL,
  total_price integer NOT NULL,
  transaction_type text NOT NULL DEFAULT 'sell' CHECK (transaction_type IN ('sell')),
  created_at timestamptz NOT NULL DEFAULT now()
);

-- ============================================================
-- 2. INDEXES
-- ============================================================

CREATE INDEX idx_map_tiles_xy ON public.map_tiles (x, y);
CREATE INDEX idx_buildings_player_id ON public.buildings (player_id);
CREATE INDEX idx_buildings_tile_id ON public.buildings (tile_id);
CREATE INDEX idx_inventories_player_id ON public.inventories (player_id);
CREATE INDEX idx_trade_transactions_player_id ON public.trade_transactions (player_id);

-- ============================================================
-- 3. TRIGGERS
-- ============================================================

CREATE OR REPLACE FUNCTION public.set_updated_at()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;

CREATE TRIGGER set_player_profiles_updated_at
  BEFORE UPDATE ON public.player_profiles
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

CREATE TRIGGER set_buildings_updated_at
  BEFORE UPDATE ON public.buildings
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

-- ============================================================
-- 4. ROW LEVEL SECURITY
-- ============================================================

ALTER TABLE public.player_profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.map_tiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.building_types ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.buildings ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.inventories ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.resources ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.traders ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.trader_prices ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.trade_transactions ENABLE ROW LEVEL SECURITY;

-- Player profiles: readable by all (for multiplayer names), writable by self
CREATE POLICY "player_profiles_select_all"
  ON public.player_profiles FOR SELECT USING (true);
CREATE POLICY "player_profiles_insert_self"
  ON public.player_profiles FOR INSERT WITH CHECK (auth.uid() = id);
CREATE POLICY "player_profiles_update_self"
  ON public.player_profiles FOR UPDATE
  USING (auth.uid() = id) WITH CHECK (auth.uid() = id);

-- Shared read-only tables
CREATE POLICY "map_tiles_read_all" ON public.map_tiles FOR SELECT USING (true);
CREATE POLICY "building_types_read_all" ON public.building_types FOR SELECT USING (true);
CREATE POLICY "resources_read_all" ON public.resources FOR SELECT USING (true);
CREATE POLICY "traders_read_all" ON public.traders FOR SELECT USING (true);
CREATE POLICY "trader_prices_read_all" ON public.trader_prices FOR SELECT USING (true);

-- Buildings: readable by all, writable by owner
CREATE POLICY "buildings_read_all" ON public.buildings FOR SELECT USING (true);
CREATE POLICY "buildings_insert_self" ON public.buildings FOR INSERT
  WITH CHECK (auth.uid() = player_id);
CREATE POLICY "buildings_update_self" ON public.buildings FOR UPDATE
  USING (auth.uid() = player_id) WITH CHECK (auth.uid() = player_id);

-- Inventories: self only
CREATE POLICY "inventories_select_self" ON public.inventories FOR SELECT
  USING (auth.uid() = player_id);
CREATE POLICY "inventories_insert_self" ON public.inventories FOR INSERT
  WITH CHECK (auth.uid() = player_id);
CREATE POLICY "inventories_update_self" ON public.inventories FOR UPDATE
  USING (auth.uid() = player_id) WITH CHECK (auth.uid() = player_id);

-- Trade transactions: self only
CREATE POLICY "trade_transactions_select_self" ON public.trade_transactions FOR SELECT
  USING (auth.uid() = player_id);
CREATE POLICY "trade_transactions_insert_self" ON public.trade_transactions FOR INSERT
  WITH CHECK (auth.uid() = player_id);

-- ============================================================
-- 5. SEED DATA
-- ============================================================

INSERT INTO public.resources (key, name, kind, industry_key) VALUES
  ('timber', 'Timber', 'raw', 'timber'),
  ('lumber', 'Lumber', 'processed', 'timber'),
  ('stone',  'Stone',  'raw', 'stone'),
  ('brick',  'Brick',  'processed', 'stone');

INSERT INTO public.building_types (
  key, name, tier, industry_key, category, build_cost, worker_cost,
  input_resource_key, input_rate, output_resource_key, output_rate
) VALUES
  ('timber_camp',     'Timber Camp',     1, 'timber', 'extractor',  100, 1, NULL,     0,   'timber', 1),
  ('sawmill',         'Sawmill',         2, 'timber', 'processor',  300, 1, 'timber', 1,   'lumber', 0.5),
  ('stone_quarry',    'Stone Quarry',    1, 'stone',  'extractor',  100, 1, NULL,     0,   'stone',  1),
  ('mason_workshop',  'Mason Workshop',  2, 'stone',  'processor',  300, 1, 'stone',  1,   'brick',  0.5);

INSERT INTO public.traders (key, name, description) VALUES
  ('starter_trader', 'Starter Trader', 'Buys basic goods at fixed prices.');

INSERT INTO public.trader_prices (trader_key, resource_key, buy_price) VALUES
  ('starter_trader', 'timber', 4),
  ('starter_trader', 'lumber', 10),
  ('starter_trader', 'stone',  5),
  ('starter_trader', 'brick',  12);

-- ============================================================
-- 6. MAP GENERATION (15x15 shared grid)
-- ============================================================

-- Generate base grid
INSERT INTO public.map_tiles (x, y, terrain_type, resource_node_key, buildable)
SELECT x, y, 'ground', NULL, true
FROM generate_series(0, 14) AS x, generate_series(0, 14) AS y;

-- Mark city center
UPDATE public.map_tiles SET terrain_type = 'city_center', buildable = false
WHERE x = 7 AND y = 7;

-- Place timber resource nodes (west side, 14 nodes)
UPDATE public.map_tiles SET resource_node_key = 'timber'
WHERE (x, y) IN (
  (0, 2), (0, 5), (0, 11),
  (1, 0), (1, 4), (1, 9), (1, 14),
  (2, 3), (2, 7),
  (3, 1), (3, 6), (3, 10),
  (4, 4), (4, 13)
);

-- Place stone resource nodes (east side, 14 nodes)
UPDATE public.map_tiles SET resource_node_key = 'stone'
WHERE (x, y) IN (
  (10, 1), (10, 4), (10, 10),
  (11, 0), (11, 7), (11, 12),
  (12, 2), (12, 6), (12, 9),
  (13, 3), (13, 8), (13, 14),
  (14, 5), (14, 11)
);

-- ============================================================
-- 7. RPC FUNCTIONS
-- ============================================================

-- choose_industry: create player profile and seed inventory
CREATE OR REPLACE FUNCTION public.choose_industry(p_display_name text, p_industry_key text)
RETURNS json LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_profile record;
BEGIN
  IF p_industry_key NOT IN ('timber', 'stone') THEN
    RAISE EXCEPTION 'Invalid industry. Choose timber or stone.';
  END IF;
  IF length(trim(p_display_name)) < 2 THEN
    RAISE EXCEPTION 'Display name must be at least 2 characters.';
  END IF;

  INSERT INTO public.player_profiles (id, display_name, industry_key, money, worker_capacity, workers_used)
  VALUES (v_uid, trim(p_display_name), p_industry_key, 500, 5, 0)
  ON CONFLICT (id) DO UPDATE SET
    display_name = trim(EXCLUDED.display_name),
    industry_key = EXCLUDED.industry_key,
    updated_at = now();

  INSERT INTO public.inventories (player_id, resource_key, quantity) VALUES
    (v_uid, 'timber', 0), (v_uid, 'lumber', 0),
    (v_uid, 'stone', 0),  (v_uid, 'brick', 0)
  ON CONFLICT (player_id, resource_key) DO NOTHING;

  SELECT * INTO v_profile FROM public.player_profiles WHERE id = v_uid;

  RETURN json_build_object(
    'id', v_profile.id,
    'display_name', v_profile.display_name,
    'industry_key', v_profile.industry_key,
    'money', v_profile.money,
    'worker_capacity', v_profile.worker_capacity,
    'workers_used', v_profile.workers_used
  );
END;
$$;

-- place_building: validate and place a building on a tile
CREATE OR REPLACE FUNCTION public.place_building(p_tile_id uuid, p_building_type_key text)
RETURNS json LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_bt record;
  v_tile record;
  v_player record;
  v_building_id uuid;
BEGIN
  SELECT * INTO v_bt FROM public.building_types WHERE key = p_building_type_key AND is_active;
  IF NOT FOUND THEN RAISE EXCEPTION 'Unknown building type'; END IF;

  SELECT * INTO v_player FROM public.player_profiles WHERE id = v_uid;
  IF NOT FOUND THEN RAISE EXCEPTION 'Player not found'; END IF;

  IF v_bt.industry_key <> v_player.industry_key THEN
    RAISE EXCEPTION 'You can only place buildings for your chosen industry';
  END IF;

  IF v_player.money < v_bt.build_cost THEN
    RAISE EXCEPTION 'Not enough money (need %, have %)', v_bt.build_cost, v_player.money;
  END IF;

  IF v_player.workers_used + v_bt.worker_cost > v_player.worker_capacity THEN
    RAISE EXCEPTION 'Not enough workers (need %, available %)', v_bt.worker_cost, v_player.worker_capacity - v_player.workers_used;
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

  INSERT INTO public.buildings (player_id, building_type_key, tile_id, x, y)
  VALUES (v_uid, p_building_type_key, p_tile_id, v_tile.x, v_tile.y)
  RETURNING id INTO v_building_id;

  UPDATE public.map_tiles SET occupied_building_id = v_building_id WHERE id = p_tile_id;

  UPDATE public.player_profiles
  SET money = money - v_bt.build_cost,
      workers_used = workers_used + v_bt.worker_cost
  WHERE id = v_uid
  RETURNING * INTO v_player;

  RETURN json_build_object(
    'building_id', v_building_id,
    'money', v_player.money,
    'workers_used', v_player.workers_used,
    'worker_capacity', v_player.worker_capacity
  );
END;
$$;

-- process_production: lazy production - calculate elapsed output for all player buildings
CREATE OR REPLACE FUNCTION public.process_production()
RETURNS json LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_building record;
  v_elapsed_min numeric;
  v_produced numeric;
  v_consumed numeric;
  v_available numeric;
  v_actual_min numeric;
  v_total_produced numeric := 0;
  v_player record;
BEGIN
  -- Phase 1: extractors (produce without consuming)
  FOR v_building IN
    SELECT b.id, b.last_processed_at, bt.output_resource_key, bt.output_rate
    FROM public.buildings b
    JOIN public.building_types bt ON bt.key = b.building_type_key
    WHERE b.player_id = v_uid AND b.status = 'active' AND bt.category = 'extractor'
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

  -- Phase 2: processors (consume input, produce output)
  FOR v_building IN
    SELECT b.id, b.last_processed_at,
           bt.input_resource_key, bt.input_rate,
           bt.output_resource_key, bt.output_rate
    FROM public.buildings b
    JOIN public.building_types bt ON bt.key = b.building_type_key
    WHERE b.player_id = v_uid AND b.status = 'active' AND bt.category = 'processor'
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

  SELECT money, workers_used, worker_capacity INTO v_player
  FROM public.player_profiles WHERE id = v_uid;

  RETURN json_build_object(
    'total_produced', v_total_produced,
    'money', v_player.money,
    'workers_used', v_player.workers_used,
    'worker_capacity', v_player.worker_capacity,
    'inventory', COALESCE(
      (SELECT json_object_agg(resource_key, quantity)
       FROM public.inventories WHERE player_id = v_uid),
      '{}'::json
    )
  );
END;
$$;

-- sell_to_trader: sell resources to NPC trader
CREATE OR REPLACE FUNCTION public.sell_to_trader(p_trader_key text, p_resource_key text, p_quantity numeric)
RETURNS json LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_price integer;
  v_total integer;
  v_available numeric;
  v_new_money integer;
BEGIN
  -- Catch up production first
  PERFORM public.process_production();

  SELECT buy_price INTO v_price
  FROM public.trader_prices
  WHERE trader_key = p_trader_key AND resource_key = p_resource_key AND is_active;
  IF NOT FOUND THEN RAISE EXCEPTION 'Trader does not buy this resource'; END IF;

  SELECT COALESCE(quantity, 0) INTO v_available
  FROM public.inventories
  WHERE player_id = v_uid AND resource_key = p_resource_key;
  IF v_available < p_quantity THEN
    RAISE EXCEPTION 'Not enough % (have %, need %)', p_resource_key, v_available, p_quantity;
  END IF;

  v_total := v_price * p_quantity;

  UPDATE public.inventories
  SET quantity = quantity - p_quantity, updated_at = now()
  WHERE player_id = v_uid AND resource_key = p_resource_key;

  UPDATE public.player_profiles
  SET money = money + v_total
  WHERE id = v_uid
  RETURNING money INTO v_new_money;

  INSERT INTO public.trade_transactions (player_id, trader_key, resource_key, quantity, unit_price, total_price)
  VALUES (v_uid, p_trader_key, p_resource_key, p_quantity, v_price, v_total);

  RETURN json_build_object(
    'total_price', v_total,
    'money', v_new_money,
    'inventory', COALESCE(
      (SELECT json_object_agg(resource_key, quantity)
       FROM public.inventories WHERE player_id = v_uid),
      '{}'::json
    )
  );
END;
$$;

-- ============================================================
-- 8. PERMISSIONS
-- ============================================================

GRANT EXECUTE ON FUNCTION public.choose_industry TO authenticated;
GRANT EXECUTE ON FUNCTION public.place_building TO authenticated;
GRANT EXECUTE ON FUNCTION public.process_production TO authenticated;
GRANT EXECUTE ON FUNCTION public.sell_to_trader TO authenticated;

-- ============================================================
-- 9. REALTIME
-- ============================================================

ALTER PUBLICATION supabase_realtime ADD TABLE public.buildings;
