-- ============================================================
-- City Builder - Black Market Migration
-- ============================================================
-- Run AFTER Phase 2B migration is in place.
-- Adds: black_market_trade RPC for instant emergency trading
--        at intentionally terrible fixed rates.
-- ============================================================

-- ────────────────────────────────────────────────────────────
-- 1. BLACK MARKET TRADE RPC
-- ────────────────────────────────────────────────────────────
-- Instant buy/sell for all 4 core resources at fixed bad rates.
-- No visit timer, no capacity limits. Rates are the balancing mechanism.
--
-- Fixed prices (from spec):
--   timber: buy_from_player 2g, sell_to_player 10g
--   stone:  buy_from_player 2g, sell_to_player 11g
--   lumber: buy_from_player 5g, sell_to_player 18g
--   brick:  buy_from_player 6g, sell_to_player 20g

CREATE OR REPLACE FUNCTION public.black_market_trade(
  p_resource_key text,
  p_quantity integer,
  p_direction text  -- 'sell' = player sells to market, 'buy' = player buys from market
)
RETURNS json LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_buy_from_player integer;  -- what market pays player
  v_sell_to_player integer;   -- what market charges player
  v_unit_price integer;
  v_total integer;
  v_available numeric;
  v_player_money integer;
  v_new_money integer;
BEGIN
  -- Validate direction
  IF p_direction NOT IN ('buy', 'sell') THEN
    RAISE EXCEPTION 'Invalid direction: %. Must be buy or sell.', p_direction;
  END IF;

  -- Validate quantity
  IF p_quantity < 1 THEN
    RAISE EXCEPTION 'Quantity must be at least 1';
  END IF;

  -- Catch up production first
  PERFORM public.process_production();

  -- Fixed black market prices (intentionally terrible)
  SELECT
    CASE p_resource_key
      WHEN 'timber' THEN 2
      WHEN 'stone'  THEN 2
      WHEN 'lumber' THEN 5
      WHEN 'brick'  THEN 6
      ELSE NULL
    END,
    CASE p_resource_key
      WHEN 'timber' THEN 10
      WHEN 'stone'  THEN 11
      WHEN 'lumber' THEN 18
      WHEN 'brick'  THEN 20
      ELSE NULL
    END
  INTO v_buy_from_player, v_sell_to_player;

  IF v_buy_from_player IS NULL THEN
    RAISE EXCEPTION 'Resource not available on black market: %', p_resource_key;
  END IF;

  IF p_direction = 'sell' THEN
    -- Player sells to black market (market buys from player)
    v_unit_price := v_buy_from_player;
    v_total := v_unit_price * p_quantity;

    -- Check inventory
    SELECT COALESCE(quantity, 0) INTO v_available
    FROM public.inventories
    WHERE player_id = v_uid AND resource_key = p_resource_key;

    IF v_available IS NULL OR v_available < p_quantity THEN
      RAISE EXCEPTION 'Not enough % (have %, need %)', p_resource_key, COALESCE(v_available, 0), p_quantity;
    END IF;

    -- Deduct inventory
    UPDATE public.inventories
    SET quantity = quantity - p_quantity, updated_at = now()
    WHERE player_id = v_uid AND resource_key = p_resource_key;

    -- Credit money
    UPDATE public.player_profiles
    SET money = money + v_total
    WHERE id = v_uid
    RETURNING money INTO v_new_money;

    -- Log transaction
    INSERT INTO public.trade_transactions (player_id, trader_key, resource_key, quantity, unit_price, total_price, transaction_type)
    VALUES (v_uid, 'black_market', p_resource_key, p_quantity, v_unit_price, v_total, 'sell');

  ELSE
    -- Player buys from black market (market sells to player)
    v_unit_price := v_sell_to_player;
    v_total := v_unit_price * p_quantity;

    -- Check money
    SELECT money INTO v_player_money
    FROM public.player_profiles WHERE id = v_uid;

    IF v_player_money < v_total THEN
      RAISE EXCEPTION 'Not enough money (have $%, need $%)', v_player_money, v_total;
    END IF;

    -- Deduct money
    UPDATE public.player_profiles
    SET money = money - v_total
    WHERE id = v_uid
    RETURNING money INTO v_new_money;

    -- Add to inventory
    INSERT INTO public.inventories (player_id, resource_key, quantity)
    VALUES (v_uid, p_resource_key, p_quantity)
    ON CONFLICT (player_id, resource_key)
    DO UPDATE SET quantity = inventories.quantity + p_quantity, updated_at = now();

    -- Log transaction
    INSERT INTO public.trade_transactions (player_id, trader_key, resource_key, quantity, unit_price, total_price, transaction_type)
    VALUES (v_uid, 'black_market', p_resource_key, p_quantity, v_unit_price, v_total, 'buy');
  END IF;

  -- Return updated state
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
-- 2. PERMISSIONS
-- ────────────────────────────────────────────────────────────
GRANT EXECUTE ON FUNCTION public.black_market_trade TO authenticated;
