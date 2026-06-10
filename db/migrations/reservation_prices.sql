-- ─────────────────────────────────────────────────────────────────────
-- Reservation prices for auto-trade (2026-05-09).
--
-- Atlas: "set a buy/sell price (on Resources tab) so it only buy/sells
-- when a partner meets that price." Global per-resource gates,
-- enforced server-side in the trade phase fns.
--
-- Schema: two new nullable columns on trade_policies:
--   min_sell_price  — sell only if trader's buy_price >= this
--   max_buy_price   — buy  only if trader's sell_price <= this
-- NULL means "no gate" (current behavior).
--
-- Rationale per design conversation:
--   1. Sell to ANY partner that meets your floor; daily caps + capacities
--      already exist for routing volume.
--   2. Global per resource (not per (resource, partner)) — keeps the UI
--      tractable.
-- ─────────────────────────────────────────────────────────────────────

ALTER TABLE public.trade_policies
  ADD COLUMN IF NOT EXISTS min_sell_price integer,
  ADD COLUMN IF NOT EXISTS max_buy_price integer;

ALTER TABLE public.trade_policies
  ADD CONSTRAINT trade_policies_min_sell_price_chk
  CHECK (min_sell_price IS NULL OR min_sell_price >= 0) NOT VALID;
ALTER TABLE public.trade_policies
  VALIDATE CONSTRAINT trade_policies_min_sell_price_chk;

ALTER TABLE public.trade_policies
  ADD CONSTRAINT trade_policies_max_buy_price_chk
  CHECK (max_buy_price IS NULL OR max_buy_price >= 0) NOT VALID;
ALTER TABLE public.trade_policies
  VALIDATE CONSTRAINT trade_policies_max_buy_price_chk;


-- save_trade_policy gains the two optional price params. Default NULL
-- preserves the existing 3-arg call signature for any code that passes
-- only mode + reserve_target.
CREATE OR REPLACE FUNCTION public.save_trade_policy(
  p_resource_key text,
  p_mode text,
  p_reserve_target integer,
  p_min_sell_price integer DEFAULT NULL,
  p_max_buy_price integer DEFAULT NULL
)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
DECLARE
  v_uid uuid := auth.uid();
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'auth required'; END IF;
  IF p_mode NOT IN ('keep', 'sell_surplus', 'buy_to_reserve') THEN
    RAISE EXCEPTION 'Invalid trade mode: %', p_mode;
  END IF;
  IF p_reserve_target < 0 THEN
    RAISE EXCEPTION 'Reserve target cannot be negative';
  END IF;
  IF p_min_sell_price IS NOT NULL AND p_min_sell_price < 0 THEN
    RAISE EXCEPTION 'min_sell_price cannot be negative';
  END IF;
  IF p_max_buy_price IS NOT NULL AND p_max_buy_price < 0 THEN
    RAISE EXCEPTION 'max_buy_price cannot be negative';
  END IF;

  INSERT INTO public.trade_policies
    (player_id, resource_key, mode, reserve_target, min_sell_price, max_buy_price)
  VALUES
    (v_uid, p_resource_key, p_mode, p_reserve_target, p_min_sell_price, p_max_buy_price)
  ON CONFLICT (player_id, resource_key)
  DO UPDATE SET mode = p_mode,
                reserve_target = p_reserve_target,
                min_sell_price = p_min_sell_price,
                max_buy_price = p_max_buy_price,
                updated_at = now();

  RETURN json_build_object('ok', true, 'resource_key', p_resource_key,
                          'mode', p_mode, 'reserve_target', p_reserve_target,
                          'min_sell_price', p_min_sell_price,
                          'max_buy_price', p_max_buy_price);
END;
$function$;


-- _rtv_sell_phase: gate on min_sell_price.
CREATE OR REPLACE FUNCTION public._rtv_sell_phase(
  p_uid uuid,
  p_trader_key text,
  p_per_resource_capacity integer
)
RETURNS TABLE(capacity_used integer, earned integer, summary jsonb)
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_city_id uuid;
  v_total_used integer := 0;
  v_earned integer := 0;
  v_summary jsonb := '[]'::jsonb;
  v_policy record;
  v_buy_price integer;
  v_buy_cap integer;
  v_inventory numeric;
  v_quota_used integer;
  v_quota_remaining integer;
  v_surplus integer;
  v_sell_amt integer;
  v_today date := CURRENT_DATE;
BEGIN
  SELECT city_id INTO v_city_id FROM public.player_profiles WHERE id = p_uid;

  FOR v_policy IN
    SELECT tp.resource_key, tp.reserve_target, tp.min_sell_price
    FROM public.trade_policies tp
    WHERE tp.player_id = p_uid AND tp.mode = 'sell_surplus'
  LOOP
    SELECT cat.buy_price, cat.daily_buy_cap INTO v_buy_price, v_buy_cap
    FROM public._trader_catalog(v_city_id, p_trader_key) cat
    WHERE cat.resource_key = v_policy.resource_key;
    IF NOT FOUND OR v_buy_price IS NULL THEN CONTINUE; END IF;

    -- Reservation price gate: skip if this partner doesn't meet the
    -- player's floor.
    IF v_policy.min_sell_price IS NOT NULL
       AND v_buy_price < v_policy.min_sell_price THEN
      CONTINUE;
    END IF;

    SELECT COALESCE(qty_bought, 0) INTO v_quota_used
    FROM public.trader_daily_quota
    WHERE player_id = p_uid AND trader_key = p_trader_key
      AND resource_key = v_policy.resource_key AND day_bucket = v_today;
    v_quota_remaining := GREATEST(0, COALESCE(v_buy_cap, 0) - COALESCE(v_quota_used, 0));
    IF v_quota_remaining <= 0 THEN CONTINUE; END IF;

    SELECT COALESCE(quantity, 0) INTO v_inventory
    FROM public.inventories
    WHERE player_id = p_uid AND resource_key = v_policy.resource_key;
    IF v_inventory IS NULL THEN v_inventory := 0; END IF;

    v_surplus := GREATEST(0, FLOOR(v_inventory) - v_policy.reserve_target);
    IF v_surplus <= 0 THEN CONTINUE; END IF;

    v_sell_amt := LEAST(v_surplus, p_per_resource_capacity, v_quota_remaining);
    IF v_sell_amt <= 0 THEN CONTINUE; END IF;

    UPDATE public.inventories
      SET quantity = quantity - v_sell_amt, updated_at = now()
      WHERE player_id = p_uid AND resource_key = v_policy.resource_key;

    INSERT INTO public.trader_daily_quota
      (player_id, trader_key, resource_key, day_bucket, qty_bought, qty_sold)
    VALUES (p_uid, p_trader_key, v_policy.resource_key, v_today, v_sell_amt, 0)
    ON CONFLICT (player_id, trader_key, resource_key, day_bucket)
    DO UPDATE SET qty_bought = public.trader_daily_quota.qty_bought + v_sell_amt;

    v_earned := v_earned + (v_sell_amt * v_buy_price);
    v_total_used := v_total_used + v_sell_amt;
    v_summary := v_summary || jsonb_build_object(
      'type', 'sell',
      'resource', v_policy.resource_key,
      'quantity', v_sell_amt,
      'unit_price', v_buy_price,
      'total', v_sell_amt * v_buy_price
    );
    INSERT INTO public.trade_transactions
      (player_id, trader_key, resource_key, quantity, unit_price, total_price, transaction_type)
    VALUES
      (p_uid, p_trader_key, v_policy.resource_key, v_sell_amt, v_buy_price,
       v_sell_amt * v_buy_price, 'sell');
  END LOOP;

  capacity_used := v_total_used;
  earned := v_earned;
  summary := v_summary;
  RETURN NEXT;
END;
$$;


-- _rtv_buy_phase: gate on max_buy_price.
CREATE OR REPLACE FUNCTION public._rtv_buy_phase(
  p_uid uuid,
  p_trader_key text,
  p_per_resource_capacity integer,
  p_money_in integer
)
RETURNS TABLE(capacity_used integer, spent integer, summary jsonb, money_out integer)
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_city_id uuid;
  v_money integer := p_money_in;
  v_total_used integer := 0;
  v_spent integer := 0;
  v_summary jsonb := '[]'::jsonb;
  v_policy record;
  v_sell_price integer;
  v_sell_cap integer;
  v_quota_used integer;
  v_quota_remaining integer;
  v_inventory numeric;
  v_needed integer;
  v_buy_amt integer;
  v_today date := CURRENT_DATE;
BEGIN
  SELECT city_id INTO v_city_id FROM public.player_profiles WHERE id = p_uid;

  FOR v_policy IN
    SELECT tp.resource_key, tp.reserve_target, tp.max_buy_price
    FROM public.trade_policies tp
    WHERE tp.player_id = p_uid AND tp.mode = 'buy_to_reserve'
  LOOP
    IF v_money <= 0 THEN EXIT; END IF;

    SELECT cat.sell_price, cat.daily_sell_cap INTO v_sell_price, v_sell_cap
    FROM public._trader_catalog(v_city_id, p_trader_key) cat
    WHERE cat.resource_key = v_policy.resource_key;
    IF NOT FOUND OR v_sell_price IS NULL THEN CONTINUE; END IF;

    -- Reservation price gate: skip if this partner exceeds the
    -- player's ceiling.
    IF v_policy.max_buy_price IS NOT NULL
       AND v_sell_price > v_policy.max_buy_price THEN
      CONTINUE;
    END IF;

    SELECT COALESCE(qty_sold, 0) INTO v_quota_used
    FROM public.trader_daily_quota
    WHERE player_id = p_uid AND trader_key = p_trader_key
      AND resource_key = v_policy.resource_key AND day_bucket = v_today;
    v_quota_remaining := GREATEST(0, COALESCE(v_sell_cap, 0) - COALESCE(v_quota_used, 0));
    IF v_quota_remaining <= 0 THEN CONTINUE; END IF;

    SELECT COALESCE(quantity, 0) INTO v_inventory
    FROM public.inventories
    WHERE player_id = p_uid AND resource_key = v_policy.resource_key;
    IF v_inventory IS NULL THEN v_inventory := 0; END IF;

    v_needed := GREATEST(0, v_policy.reserve_target - FLOOR(v_inventory));
    IF v_needed <= 0 THEN CONTINUE; END IF;

    v_buy_amt := LEAST(v_needed, p_per_resource_capacity, v_quota_remaining);
    IF v_sell_price > 0 THEN
      v_buy_amt := LEAST(v_buy_amt, FLOOR(v_money / v_sell_price));
    END IF;
    IF v_buy_amt <= 0 THEN CONTINUE; END IF;

    INSERT INTO public.inventories (player_id, resource_key, quantity)
    VALUES (p_uid, v_policy.resource_key, v_buy_amt)
    ON CONFLICT (player_id, resource_key)
    DO UPDATE SET quantity = public.inventories.quantity + v_buy_amt, updated_at = now();

    INSERT INTO public.trader_daily_quota
      (player_id, trader_key, resource_key, day_bucket, qty_bought, qty_sold)
    VALUES (p_uid, p_trader_key, v_policy.resource_key, v_today, 0, v_buy_amt)
    ON CONFLICT (player_id, trader_key, resource_key, day_bucket)
    DO UPDATE SET qty_sold = public.trader_daily_quota.qty_sold + v_buy_amt;

    v_spent := v_spent + (v_buy_amt * v_sell_price);
    v_money := v_money - (v_buy_amt * v_sell_price);
    v_total_used := v_total_used + v_buy_amt;
    v_summary := v_summary || jsonb_build_object(
      'type', 'buy',
      'resource', v_policy.resource_key,
      'quantity', v_buy_amt,
      'unit_price', v_sell_price,
      'total', v_buy_amt * v_sell_price
    );
    INSERT INTO public.trade_transactions
      (player_id, trader_key, resource_key, quantity, unit_price, total_price, transaction_type)
    VALUES
      (p_uid, p_trader_key, v_policy.resource_key, v_buy_amt, v_sell_price,
       v_buy_amt * v_sell_price, 'buy');
  END LOOP;

  capacity_used := v_total_used;
  spent := v_spent;
  summary := v_summary;
  money_out := v_money;
  RETURN NEXT;
END;
$$;
DROP FUNCTION IF EXISTS public.save_trade_policy(text, text, integer);
