-- ============================================================
-- City Builder - Grain Chain Migration (Slices 1+2)
-- ============================================================
-- Run AFTER the Housing Evolution migration is in place.
-- Adds: Grain + Flour resources, Grain Farm (extractor) + Mill
--        (processor), grain map nodes, trader prices, Black
--        Market support, inventory seeding.
-- ============================================================

-- ────────────────────────────────────────────────────────────
-- 1. NEW RESOURCES
-- ────────────────────────────────────────────────────────────

INSERT INTO public.resources (key, name, kind, industry_key) VALUES
  ('grain', 'Grain', 'raw',       'common'),
  ('flour', 'Flour', 'processed', 'common')
ON CONFLICT (key) DO NOTHING;

-- ────────────────────────────────────────────────────────────
-- 2. NEW BUILDING TYPES
-- ────────────────────────────────────────────────────────────

-- Grain Farm: extractor, common (all players), Tier 1
--   4 workers, $150, produces 2 grain/min (no input)
INSERT INTO public.building_types (
  key, name, tier, industry_key, category, build_cost, worker_cost,
  input_resource_key, input_rate, output_resource_key, output_rate,
  workers_provided
) VALUES (
  'grain_farm', 'Grain Farm', 1, 'common', 'extractor', 150, 4,
  NULL, 0, 'grain', 2,
  0
)
ON CONFLICT (key) DO UPDATE SET
  name = EXCLUDED.name,
  build_cost = EXCLUDED.build_cost,
  worker_cost = EXCLUDED.worker_cost,
  output_rate = EXCLUDED.output_rate;

-- Mill: processor, common (all players), Tier 2
--   3 workers, $300, consumes 2 grain/min → produces 1 flour/min
INSERT INTO public.building_types (
  key, name, tier, industry_key, category, build_cost, worker_cost,
  input_resource_key, input_rate, output_resource_key, output_rate,
  workers_provided
) VALUES (
  'mill', 'Mill', 2, 'common', 'processor', 300, 3,
  'grain', 2, 'flour', 1,
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
-- 3. GRAIN RESOURCE NODES ON MAP
-- ────────────────────────────────────────────────────────────
-- Place ~10 grain nodes in the south-center area (rows 9-14,
-- cols 5-9) to create geographic choice vs timber (west) and
-- stone (east).

UPDATE public.map_tiles SET resource_node_key = 'grain'
WHERE (x, y) IN (
  (5, 9),  (6, 10), (7, 11), (8, 9),  (9, 10),
  (5, 12), (6, 13), (7, 14), (8, 12), (9, 14)
)
AND resource_node_key IS NULL
AND occupied_building_id IS NULL;

-- ────────────────────────────────────────────────────────────
-- 4. TRADER PRICES FOR GRAIN & FLOUR
-- ────────────────────────────────────────────────────────────

-- River Traders: generalist, trades raw grain
INSERT INTO public.trader_prices (trader_key, resource_key, buy_price, sell_price) VALUES
  ('river_traders', 'grain', 3, 6)
ON CONFLICT (trader_key, resource_key) DO UPDATE SET
  buy_price = EXCLUDED.buy_price, sell_price = EXCLUDED.sell_price, is_active = true;

-- Desert Caravan: buys processed flour at premium, sells raw grain
INSERT INTO public.trader_prices (trader_key, resource_key, buy_price, sell_price) VALUES
  ('desert_caravan', 'flour', 9, NULL),
  ('desert_caravan', 'grain', NULL, 7)
ON CONFLICT (trader_key, resource_key) DO UPDATE SET
  buy_price = EXCLUDED.buy_price, sell_price = EXCLUDED.sell_price, is_active = true;

-- Mountain Folk: bulk trader, cheap prices
INSERT INTO public.trader_prices (trader_key, resource_key, buy_price, sell_price) VALUES
  ('mountain_folk', 'grain', 2, 4),
  ('mountain_folk', 'flour', 6, NULL)
ON CONFLICT (trader_key, resource_key) DO UPDATE SET
  buy_price = EXCLUDED.buy_price, sell_price = EXCLUDED.sell_price, is_active = true;

-- ────────────────────────────────────────────────────────────
-- 5. UPDATED RPC: black_market_trade
-- ────────────────────────────────────────────────────────────
-- Add grain and flour to the fixed-price emergency market.
-- Grain: buy_from_player 2g, sell_to_player 9g
-- Flour: buy_from_player 5g, sell_to_player 16g

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
      WHEN 'timber' THEN 2
      WHEN 'stone'  THEN 2
      WHEN 'lumber' THEN 5
      WHEN 'brick'  THEN 6
      WHEN 'grain'  THEN 2
      WHEN 'flour'  THEN 5
      ELSE NULL
    END,
    CASE p_resource_key
      WHEN 'timber' THEN 10
      WHEN 'stone'  THEN 11
      WHEN 'lumber' THEN 18
      WHEN 'brick'  THEN 20
      WHEN 'grain'  THEN 9
      WHEN 'flour'  THEN 16
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
-- Seed grain and flour inventory rows for new players so trade
-- policies and inventory display work immediately.

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
    (v_uid, 'grain', 0),  (v_uid, 'flour', 0)
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
-- Ensure existing players get grain/flour inventory rows so
-- the UI and trade system work without requiring re-registration.

INSERT INTO public.inventories (player_id, resource_key, quantity)
SELECT pp.id, r.key, 0
FROM public.player_profiles pp
CROSS JOIN (VALUES ('grain'), ('flour')) AS r(key)
ON CONFLICT (player_id, resource_key) DO NOTHING;

-- ────────────────────────────────────────────────────────────
-- 8. PERMISSIONS
-- ────────────────────────────────────────────────────────────
-- All RPCs are replaced in-place; existing GRANTs still apply.
-- No new functions added, so no new GRANTs needed.
