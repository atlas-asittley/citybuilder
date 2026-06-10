-- ============================================================
-- City Builder Phase 2A - Trade Foundation Migration
-- ============================================================
-- Run this AFTER the MVP schema is in place.
-- Adds: trade_policies, trader_visits, sell prices,
--        resolve_trader_visit RPC, save_trade_policy RPC
-- ============================================================

-- ────────────────────────────────────────────────────────────
-- 1. SCHEMA CHANGES
-- ────────────────────────────────────────────────────────────

-- Add sell_price to trader_prices (what the trader charges the player to buy)
ALTER TABLE public.trader_prices
  ADD COLUMN IF NOT EXISTS sell_price integer;

-- Set sell prices for starter trader
UPDATE public.trader_prices SET sell_price = 7  WHERE trader_key = 'starter_trader' AND resource_key = 'timber';
UPDATE public.trader_prices SET sell_price = 14 WHERE trader_key = 'starter_trader' AND resource_key = 'lumber';
UPDATE public.trader_prices SET sell_price = 8  WHERE trader_key = 'starter_trader' AND resource_key = 'stone';
UPDATE public.trader_prices SET sell_price = 16 WHERE trader_key = 'starter_trader' AND resource_key = 'brick';

-- Add trader capacity and visit interval to traders table
ALTER TABLE public.traders
  ADD COLUMN IF NOT EXISTS visit_capacity integer NOT NULL DEFAULT 20,
  ADD COLUMN IF NOT EXISTS visit_interval_minutes integer NOT NULL DEFAULT 10;

-- Trade policies table
CREATE TABLE IF NOT EXISTS public.trade_policies (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  player_id uuid NOT NULL REFERENCES public.player_profiles(id) ON DELETE CASCADE,
  resource_key text NOT NULL REFERENCES public.resources(key),
  mode text NOT NULL DEFAULT 'keep' CHECK (mode IN ('keep', 'sell_surplus', 'buy_to_reserve')),
  reserve_target integer NOT NULL DEFAULT 0,
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (player_id, resource_key)
);

CREATE INDEX IF NOT EXISTS idx_trade_policies_player ON public.trade_policies (player_id);

-- Trader visits log table
CREATE TABLE IF NOT EXISTS public.trader_visits (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  trader_key text NOT NULL REFERENCES public.traders(key),
  player_id uuid NOT NULL REFERENCES public.player_profiles(id) ON DELETE CASCADE,
  visited_at timestamptz NOT NULL DEFAULT now(),
  capacity_total integer NOT NULL,
  capacity_used integer NOT NULL DEFAULT 0,
  summary jsonb NOT NULL DEFAULT '[]'::jsonb
);

CREATE INDEX IF NOT EXISTS idx_trader_visits_player ON public.trader_visits (player_id);
CREATE INDEX IF NOT EXISTS idx_trader_visits_visited_at ON public.trader_visits (player_id, visited_at DESC);

-- ────────────────────────────────────────────────────────────
-- 2. ROW LEVEL SECURITY
-- ────────────────────────────────────────────────────────────

ALTER TABLE public.trade_policies ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.trader_visits ENABLE ROW LEVEL SECURITY;

CREATE POLICY "trade_policies_select_self" ON public.trade_policies
  FOR SELECT USING (auth.uid() = player_id);
CREATE POLICY "trade_policies_insert_self" ON public.trade_policies
  FOR INSERT WITH CHECK (auth.uid() = player_id);
CREATE POLICY "trade_policies_update_self" ON public.trade_policies
  FOR UPDATE USING (auth.uid() = player_id) WITH CHECK (auth.uid() = player_id);

CREATE POLICY "trader_visits_select_self" ON public.trader_visits
  FOR SELECT USING (auth.uid() = player_id);
CREATE POLICY "trader_visits_insert_self" ON public.trader_visits
  FOR INSERT WITH CHECK (auth.uid() = player_id);

-- ────────────────────────────────────────────────────────────
-- 3. RPC: save_trade_policy
-- ────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.save_trade_policy(
  p_resource_key text,
  p_mode text,
  p_reserve_target integer
)
RETURNS json LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_uid uuid := auth.uid();
BEGIN
  IF p_mode NOT IN ('keep', 'sell_surplus', 'buy_to_reserve') THEN
    RAISE EXCEPTION 'Invalid trade mode: %', p_mode;
  END IF;
  IF p_reserve_target < 0 THEN
    RAISE EXCEPTION 'Reserve target cannot be negative';
  END IF;

  INSERT INTO public.trade_policies (player_id, resource_key, mode, reserve_target)
  VALUES (v_uid, p_resource_key, p_mode, p_reserve_target)
  ON CONFLICT (player_id, resource_key)
  DO UPDATE SET mode = p_mode, reserve_target = p_reserve_target, updated_at = now();

  RETURN json_build_object('ok', true, 'resource_key', p_resource_key, 'mode', p_mode, 'reserve_target', p_reserve_target);
END;
$$;

-- ────────────────────────────────────────────────────────────
-- 4. RPC: resolve_trader_visit
-- ────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.resolve_trader_visit(p_trader_key text)
RETURNS json LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_trader record;
  v_last_visit timestamptz;
  v_interval interval;
  v_capacity_remaining integer;
  v_policy record;
  v_inventory numeric;
  v_surplus integer;
  v_needed integer;
  v_sell_amt integer;
  v_buy_amt integer;
  v_buy_price integer;
  v_sell_price integer;
  v_total_earned integer := 0;
  v_total_spent integer := 0;
  v_player_money integer;
  v_summary jsonb := '[]'::jsonb;
  v_visit_id uuid;
  v_next_visit_at timestamptz;
  v_visits_resolved integer := 0;
BEGIN
  -- Catch up production first
  PERFORM public.process_production();

  -- Load trader info
  SELECT * INTO v_trader FROM public.traders WHERE key = p_trader_key AND is_active;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Trader not found: %', p_trader_key;
  END IF;

  v_interval := (v_trader.visit_interval_minutes::text || ' minutes')::interval;

  -- Find last visit time for this player + trader
  SELECT visited_at INTO v_last_visit
  FROM public.trader_visits
  WHERE player_id = v_uid AND trader_key = p_trader_key
  ORDER BY visited_at DESC
  LIMIT 1;

  -- If no previous visit, use profile creation time
  IF v_last_visit IS NULL THEN
    SELECT created_at INTO v_last_visit FROM public.player_profiles WHERE id = v_uid;
  END IF;

  -- Check if a visit is due
  v_next_visit_at := v_last_visit + v_interval;
  IF now() < v_next_visit_at THEN
    -- No visit due yet, return status
    RETURN json_build_object(
      'visit_resolved', false,
      'next_visit_at', v_next_visit_at,
      'reason', 'not_due'
    );
  END IF;

  -- A visit is due! Resolve it.
  v_capacity_remaining := v_trader.visit_capacity;

  -- Get player money
  SELECT money INTO v_player_money FROM public.player_profiles WHERE id = v_uid;

  -- ── PHASE 1: Process sells ──
  FOR v_policy IN
    SELECT tp.resource_key, tp.mode, tp.reserve_target
    FROM public.trade_policies tp
    WHERE tp.player_id = v_uid AND tp.mode = 'sell_surplus'
  LOOP
    IF v_capacity_remaining <= 0 THEN EXIT; END IF;

    -- Get buy_price (what trader pays player)
    SELECT buy_price INTO v_buy_price
    FROM public.trader_prices
    WHERE trader_key = p_trader_key AND resource_key = v_policy.resource_key AND is_active;
    IF NOT FOUND THEN CONTINUE; END IF;

    -- Get current inventory
    SELECT COALESCE(quantity, 0) INTO v_inventory
    FROM public.inventories
    WHERE player_id = v_uid AND resource_key = v_policy.resource_key;
    IF v_inventory IS NULL THEN v_inventory := 0; END IF;

    -- Calculate surplus
    v_surplus := GREATEST(0, FLOOR(v_inventory) - v_policy.reserve_target);
    IF v_surplus <= 0 THEN CONTINUE; END IF;

    -- Limit by capacity
    v_sell_amt := LEAST(v_surplus, v_capacity_remaining);
    IF v_sell_amt <= 0 THEN CONTINUE; END IF;

    -- Execute sale
    UPDATE public.inventories
    SET quantity = quantity - v_sell_amt, updated_at = now()
    WHERE player_id = v_uid AND resource_key = v_policy.resource_key;

    v_total_earned := v_total_earned + (v_sell_amt * v_buy_price);
    v_capacity_remaining := v_capacity_remaining - v_sell_amt;

    -- Add to summary
    v_summary := v_summary || jsonb_build_object(
      'type', 'sell',
      'resource', v_policy.resource_key,
      'quantity', v_sell_amt,
      'unit_price', v_buy_price,
      'total', v_sell_amt * v_buy_price
    );

    -- Log transaction
    INSERT INTO public.trade_transactions (player_id, trader_key, resource_key, quantity, unit_price, total_price, transaction_type)
    VALUES (v_uid, p_trader_key, v_policy.resource_key, v_sell_amt, v_buy_price, v_sell_amt * v_buy_price, 'sell');
  END LOOP;

  -- Credit earnings
  IF v_total_earned > 0 THEN
    UPDATE public.player_profiles SET money = money + v_total_earned WHERE id = v_uid;
    v_player_money := v_player_money + v_total_earned;
  END IF;

  -- ── PHASE 2: Process buys ──
  FOR v_policy IN
    SELECT tp.resource_key, tp.mode, tp.reserve_target
    FROM public.trade_policies tp
    WHERE tp.player_id = v_uid AND tp.mode = 'buy_to_reserve'
  LOOP
    IF v_capacity_remaining <= 0 THEN EXIT; END IF;

    -- Get sell_price (what trader charges player)
    SELECT tp.sell_price INTO v_sell_price
    FROM public.trader_prices tp
    WHERE tp.trader_key = p_trader_key AND tp.resource_key = v_policy.resource_key AND tp.is_active;
    IF NOT FOUND OR v_sell_price IS NULL THEN CONTINUE; END IF;

    -- Get current inventory
    SELECT COALESCE(quantity, 0) INTO v_inventory
    FROM public.inventories
    WHERE player_id = v_uid AND resource_key = v_policy.resource_key;
    IF v_inventory IS NULL THEN v_inventory := 0; END IF;

    -- Calculate needed
    v_needed := GREATEST(0, v_policy.reserve_target - FLOOR(v_inventory));
    IF v_needed <= 0 THEN CONTINUE; END IF;

    -- Limit by capacity
    v_buy_amt := LEAST(v_needed, v_capacity_remaining);

    -- Limit by affordability
    IF v_sell_price > 0 THEN
      v_buy_amt := LEAST(v_buy_amt, FLOOR(v_player_money / v_sell_price));
    END IF;
    IF v_buy_amt <= 0 THEN CONTINUE; END IF;

    -- Execute purchase
    INSERT INTO public.inventories (player_id, resource_key, quantity)
    VALUES (v_uid, v_policy.resource_key, v_buy_amt)
    ON CONFLICT (player_id, resource_key)
    DO UPDATE SET quantity = inventories.quantity + v_buy_amt, updated_at = now();

    v_total_spent := v_total_spent + (v_buy_amt * v_sell_price);
    v_player_money := v_player_money - (v_buy_amt * v_sell_price);
    v_capacity_remaining := v_capacity_remaining - v_buy_amt;

    -- Add to summary
    v_summary := v_summary || jsonb_build_object(
      'type', 'buy',
      'resource', v_policy.resource_key,
      'quantity', v_buy_amt,
      'unit_price', v_sell_price,
      'total', v_buy_amt * v_sell_price
    );

    -- Log transaction
    INSERT INTO public.trade_transactions (player_id, trader_key, resource_key, quantity, unit_price, total_price, transaction_type)
    VALUES (v_uid, p_trader_key, v_policy.resource_key, v_buy_amt, v_sell_price, v_buy_amt * v_sell_price, 'buy');
  END LOOP;

  -- Debit spending
  IF v_total_spent > 0 THEN
    UPDATE public.player_profiles SET money = money - v_total_spent WHERE id = v_uid;
  END IF;

  -- Record visit
  INSERT INTO public.trader_visits (trader_key, player_id, capacity_total, capacity_used, summary, visited_at)
  VALUES (p_trader_key, v_uid, v_trader.visit_capacity, v_trader.visit_capacity - v_capacity_remaining, v_summary, now())
  RETURNING id INTO v_visit_id;

  -- Return result
  RETURN json_build_object(
    'visit_resolved', true,
    'visit_id', v_visit_id,
    'capacity_total', v_trader.visit_capacity,
    'capacity_used', v_trader.visit_capacity - v_capacity_remaining,
    'total_earned', v_total_earned,
    'total_spent', v_total_spent,
    'summary', v_summary,
    'next_visit_at', now() + v_interval,
    'money', v_player_money,
    'inventory', COALESCE(
      (SELECT json_object_agg(resource_key, quantity)
       FROM public.inventories WHERE player_id = v_uid),
      '{}'::json
    )
  );
END;
$$;

-- ────────────────────────────────────────────────────────────
-- 5. UPDATE trade_transactions to allow 'buy' type
-- ────────────────────────────────────────────────────────────

ALTER TABLE public.trade_transactions
  DROP CONSTRAINT IF EXISTS trade_transactions_transaction_type_check;
ALTER TABLE public.trade_transactions
  ADD CONSTRAINT trade_transactions_transaction_type_check
  CHECK (transaction_type IN ('sell', 'buy'));

-- ────────────────────────────────────────────────────────────
-- 6. PERMISSIONS
-- ────────────────────────────────────────────────────────────

GRANT EXECUTE ON FUNCTION public.save_trade_policy TO authenticated;
GRANT EXECUTE ON FUNCTION public.resolve_trader_visit TO authenticated;
