-- ============================================================
-- City Builder - Clay Chain Migration
-- ============================================================
-- Run AFTER the Grain Chain migration is in place.
-- Adds: Clay + Pottery resources, Clay Pit (extractor) + Pottery
--        Kiln (processor), clay map nodes, trader prices, Black
--        Market support, inventory seeding.
-- ============================================================

-- ────────────────────────────────────────────────────────────
-- 1. NEW RESOURCES
-- ────────────────────────────────────────────────────────────

INSERT INTO public.resources (key, name, kind, industry_key) VALUES
  ('clay',    'Clay',    'raw',       'common'),
  ('pottery', 'Pottery', 'processed', 'common')
ON CONFLICT (key) DO NOTHING;

-- ────────────────────────────────────────────────────────────
-- 2. NEW BUILDING TYPES
-- ────────────────────────────────────────────────────────────

-- Clay Pit: extractor, common (all players), Tier 1
--   3 workers, $120, produces 1.5 clay/min (no input)
INSERT INTO public.building_types (
  key, name, tier, industry_key, category, build_cost, worker_cost,
  input_resource_key, input_rate, output_resource_key, output_rate,
  workers_provided
) VALUES (
  'clay_pit', 'Clay Pit', 1, 'common', 'extractor', 120, 3,
  NULL, 0, 'clay', 1.5,
  0
)
ON CONFLICT (key) DO UPDATE SET
  name = EXCLUDED.name,
  build_cost = EXCLUDED.build_cost,
  worker_cost = EXCLUDED.worker_cost,
  output_rate = EXCLUDED.output_rate;

-- Pottery Kiln: processor, common (all players), Tier 2
--   2 workers, $250, consumes 1.5 clay/min → produces 0.75 pottery/min
INSERT INTO public.building_types (
  key, name, tier, industry_key, category, build_cost, worker_cost,
  input_resource_key, input_rate, output_resource_key, output_rate,
  workers_provided
) VALUES (
  'pottery_kiln', 'Pottery Kiln', 2, 'common', 'processor', 250, 2,
  'clay', 1.5, 'pottery', 0.75,
  0
)
ON CONFLICT (key) DO UPDATE SET
  name = EXCLUDED.name,
  build_cost = EXCLUDED.build_cost,
  worker_cost = EXCLUDED.worker_cost,
  input_resource_key = EXCLUDED.input_resource_key,
  input_rate = EXCLUDED.input_rate,
  output_resource_key = EXCLUDED.output_resource_key,
  output_rate = EXCLUDED.output_rate;

-- ────────────────────────────────────────────────────────────
-- 3. CLAY RESOURCE NODES ON MAP
-- ────────────────────────────────────────────────────────────
-- Place ~10 clay nodes in the north-center area (rows 0-5,
-- cols 5-9) to balance against grain in the south.

UPDATE public.map_tiles SET resource_node_key = 'clay'
WHERE (x, y) IN (
  (5, 0),  (6, 1),  (7, 0),  (8, 2),  (9, 1),
  (5, 3),  (6, 4),  (7, 3),  (8, 5),  (9, 4)
)
AND resource_node_key IS NULL
AND occupied_building_id IS NULL;

-- ────────────────────────────────────────────────────────────
-- 4. TRADER PRICES FOR CLAY & POTTERY
-- ────────────────────────────────────────────────────────────

-- River Traders: generalist, trades raw clay
INSERT INTO public.trader_prices (trader_key, resource_key, buy_price, sell_price) VALUES
  ('river_traders', 'clay', 3, 5)
ON CONFLICT (trader_key, resource_key) DO UPDATE SET
  buy_price = EXCLUDED.buy_price, sell_price = EXCLUDED.sell_price, is_active = true;

-- Desert Caravan: buys processed pottery at premium
INSERT INTO public.trader_prices (trader_key, resource_key, buy_price, sell_price) VALUES
  ('desert_caravan', 'pottery', 10, NULL)
ON CONFLICT (trader_key, resource_key) DO UPDATE SET
  buy_price = EXCLUDED.buy_price, sell_price = EXCLUDED.sell_price, is_active = true;

-- Mountain Folk: bulk trader, cheap prices
INSERT INTO public.trader_prices (trader_key, resource_key, buy_price, sell_price) VALUES
  ('mountain_folk', 'clay', 2, 4),
  ('mountain_folk', 'pottery', 7, NULL)
ON CONFLICT (trader_key, resource_key) DO UPDATE SET
  buy_price = EXCLUDED.buy_price, sell_price = EXCLUDED.sell_price, is_active = true;

-- ────────────────────────────────────────────────────────────
-- 5. UPDATED RPC: black_market_trade
-- ────────────────────────────────────────────────────────────
-- Add clay and pottery to the fixed-price emergency market.
-- Clay:    buy_from_player 2g, sell_to_player 8g
-- Pottery: buy_from_player 5g, sell_to_player 15g

CREATE OR REPLACE FUNCTION public.black_market_trade(
  p_resource_key text,
  p_quantity integer,
  p_direction text
)
RETURNS json LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_buy_from_player integer;
  v_sell_to_player integer;
  v_unit_price integer;
  v_total integer;
  v_available numeric;
  v_player_money integer;
  v_new_money integer;
BEGIN
  IF p_direction NOT IN ('buy', 'sell') THEN
    RAISE EXCEPTION 'Invalid direction: %. Must be buy or sell.', p_direction;
  END IF;
  IF p_quantity < 1 THEN
    RAISE EXCEPTION 'Quantity must be at least 1';
  END IF;

  PERFORM public.process_production();

  SELECT
    CASE p_resource_key
      WHEN 'timber'  THEN 2
      WHEN 'stone'   THEN 2
      WHEN 'lumber'  THEN 5
      WHEN 'brick'   THEN 6
      WHEN 'grain'   THEN 2
      WHEN 'flour'   THEN 5
      WHEN 'clay'    THEN 2
      WHEN 'pottery' THEN 5
      ELSE NULL
    END,
    CASE p_resource_key
      WHEN 'timber'  THEN 10
      WHEN 'stone'   THEN 11
      WHEN 'lumber'  THEN 18
      WHEN 'brick'   THEN 20
      WHEN 'grain'   THEN 9
      WHEN 'flour'   THEN 16
      WHEN 'clay'    THEN 8
      WHEN 'pottery' THEN 15
      ELSE NULL
    END
  INTO v_buy_from_player, v_sell_to_player;

  IF v_buy_from_player IS NULL THEN
    RAISE EXCEPTION 'Resource not available on black market: %', p_resource_key;
  END IF;

  IF p_direction = 'sell' THEN
    v_unit_price := v_buy_from_player;
    v_total := v_unit_price * p_quantity;

    SELECT COALESCE(quantity, 0) INTO v_available
    FROM public.inventories
    WHERE player_id = v_uid AND resource_key = p_resource_key;

    IF v_available IS NULL OR v_available < p_quantity THEN
      RAISE EXCEPTION 'Not enough % (have %, need %)', p_resource_key, COALESCE(v_available, 0), p_quantity;
    END IF;

    UPDATE public.inventories
    SET quantity = quantity - p_quantity, updated_at = now()
    WHERE player_id = v_uid AND resource_key = p_resource_key;

    UPDATE public.player_profiles
    SET money = money + v_total
    WHERE id = v_uid
    RETURNING money INTO v_new_money;

    INSERT INTO public.trade_transactions (player_id, trader_key, resource_key, quantity, unit_price, total_price, transaction_type)
    VALUES (v_uid, 'black_market', p_resource_key, p_quantity, v_unit_price, v_total, 'sell');

  ELSE
    v_unit_price := v_sell_to_player;
    v_total := v_unit_price * p_quantity;

    SELECT money INTO v_player_money
    FROM public.player_profiles WHERE id = v_uid;

    IF v_player_money < v_total THEN
      RAISE EXCEPTION 'Not enough money (have $%, need $%)', v_player_money, v_total;
    END IF;

    UPDATE public.player_profiles
    SET money = money - v_total
    WHERE id = v_uid
    RETURNING money INTO v_new_money;

    INSERT INTO public.inventories (player_id, resource_key, quantity)
    VALUES (v_uid, p_resource_key, p_quantity)
    ON CONFLICT (player_id, resource_key)
    DO UPDATE SET quantity = inventories.quantity + p_quantity, updated_at = now();

    INSERT INTO public.trade_transactions (player_id, trader_key, resource_key, quantity, unit_price, total_price, transaction_type)
    VALUES (v_uid, 'black_market', p_resource_key, p_quantity, v_unit_price, v_total, 'buy');
  END IF;

  RETURN json_build_object(
    'direction', p_direction,
    'resource', p_resource_key,
    'quantity', p_quantity,
    'unit_price', v_unit_price,
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

-- ────────────────────────────────────────────────────────────
-- 6. UPDATED RPC: choose_industry
-- ────────────────────────────────────────────────────────────
-- Seed clay and pottery inventory rows for new players.

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
    (v_uid, 'stone', 0),  (v_uid, 'brick', 0),
    (v_uid, 'grain', 0),  (v_uid, 'flour', 0),
    (v_uid, 'clay', 0),   (v_uid, 'pottery', 0)
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

-- ────────────────────────────────────────────────────────────
-- 7. SEED INVENTORY FOR EXISTING PLAYERS
-- ────────────────────────────────────────────────────────────

INSERT INTO public.inventories (player_id, resource_key, quantity)
SELECT pp.id, r.key, 0
FROM public.player_profiles pp
CROSS JOIN (VALUES ('clay'), ('pottery')) AS r(key)
ON CONFLICT (player_id, resource_key) DO NOTHING;

-- ────────────────────────────────────────────────────────────
-- 8. PERMISSIONS
-- ────────────────────────────────────────────────────────────
-- All RPCs are replaced in-place; existing GRANTs still apply.
