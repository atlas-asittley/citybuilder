-- ============================================================
-- City Builder Phase 2B - Trade Partners Migration
-- ============================================================
-- Run AFTER Phase 2A migration is in place.
-- Adds: 3 distinct trade partners (River Traders, Desert Caravan,
--        Mountain Folk), partner-specific prices, updated RPC
-- ============================================================

-- ────────────────────────────────────────────────────────────
-- 1. SCHEMA CHANGES
-- ────────────────────────────────────────────────────────────

-- Allow buy_price to be NULL (for traders who only sell a resource to the player)
ALTER TABLE public.trader_prices ALTER COLUMN buy_price DROP NOT NULL;

-- Add display_order to traders for UI ordering
ALTER TABLE public.traders
  ADD COLUMN IF NOT EXISTS display_order integer NOT NULL DEFAULT 0;

-- ────────────────────────────────────────────────────────────
-- 2. MIGRATE STARTER_TRADER TO RIVER_TRADERS
-- ────────────────────────────────────────────────────────────

-- Create river_traders entry first
INSERT INTO public.traders (key, name, description, visit_capacity, visit_interval_minutes, display_order, is_active)
VALUES (
  'river_traders',
  'River Traders',
  'Dependable generalist partner. Trades basic raw materials with balanced capacity and reliable timing.',
  20, 10, 1, true
)
ON CONFLICT (key) DO NOTHING;

-- Migrate all child records from starter_trader to river_traders
UPDATE public.trader_prices SET trader_key = 'river_traders' WHERE trader_key = 'starter_trader';
UPDATE public.trader_visits SET trader_key = 'river_traders' WHERE trader_key = 'starter_trader';
UPDATE public.trade_transactions SET trader_key = 'river_traders' WHERE trader_key = 'starter_trader';

-- Remove old starter_trader (children already migrated)
DELETE FROM public.traders WHERE key = 'starter_trader';

-- River Traders only trade timber and stone per spec (remove lumber/brick rows)
DELETE FROM public.trader_prices WHERE trader_key = 'river_traders' AND resource_key IN ('lumber', 'brick');

-- Ensure river_traders prices are correct
UPDATE public.trader_prices SET buy_price = 4, sell_price = 7
WHERE trader_key = 'river_traders' AND resource_key = 'timber';

UPDATE public.trader_prices SET buy_price = 5, sell_price = 8
WHERE trader_key = 'river_traders' AND resource_key = 'stone';

-- ────────────────────────────────────────────────────────────
-- 3. SEED NEW TRADE PARTNERS
-- ────────────────────────────────────────────────────────────

-- Desert Caravan: refined goods specialist
-- Pays premium for processed goods (lumber, brick)
-- Sells raw materials (stone, timber) to player at moderate markup
INSERT INTO public.traders (key, name, description, visit_capacity, visit_interval_minutes, display_order, is_active)
VALUES (
  'desert_caravan',
  'Desert Caravan',
  'Refined goods specialist. Pays premium prices for lumber and brick. Less frequent but more rewarding.',
  14, 14, 2, true
)
ON CONFLICT (key) DO NOTHING;

INSERT INTO public.trader_prices (trader_key, resource_key, buy_price, sell_price) VALUES
  ('desert_caravan', 'lumber', 12, NULL),   -- buys lumber from player at 12g (premium!)
  ('desert_caravan', 'brick',  15, NULL),   -- buys brick from player at 15g (premium!)
  ('desert_caravan', 'stone',  NULL, 9),    -- sells stone to player at 9g
  ('desert_caravan', 'timber', NULL, 8)     -- sells timber to player at 8g
ON CONFLICT (trader_key, resource_key) DO UPDATE SET
  buy_price = EXCLUDED.buy_price,
  sell_price = EXCLUDED.sell_price,
  is_active = true;

-- Mountain Folk: bulk industrial materials partner
-- Trades raw + some processed, lower prices but massive capacity
INSERT INTO public.traders (key, name, description, visit_capacity, visit_interval_minutes, display_order, is_active)
VALUES (
  'mountain_folk',
  'Mountain Folk',
  'Industrial materials partner. Handles bulk raw and processed goods. Slower visits but massive carrying capacity.',
  26, 18, 3, true
)
ON CONFLICT (key) DO NOTHING;

INSERT INTO public.trader_prices (trader_key, resource_key, buy_price, sell_price) VALUES
  ('mountain_folk', 'timber', 3, 5),        -- buys timber at 3g, sells at 5g (cheapest)
  ('mountain_folk', 'lumber', 8, NULL),     -- buys lumber at 8g (less than Desert Caravan)
  ('mountain_folk', 'stone',  4, 6)         -- buys stone at 4g, sells at 6g (cheapest)
ON CONFLICT (trader_key, resource_key) DO UPDATE SET
  buy_price = EXCLUDED.buy_price,
  sell_price = EXCLUDED.sell_price,
  is_active = true;

-- ────────────────────────────────────────────────────────────
-- 4. UPDATE resolve_trader_visit RPC
-- ────────────────────────────────────────────────────────────
-- Only change: handle NULL buy_price gracefully in sell phase

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
    RETURN json_build_object(
      'visit_resolved', false,
      'next_visit_at', v_next_visit_at,
      'trader_key', p_trader_key,
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

    -- Get buy_price (what trader pays player) — skip if NULL or not found
    SELECT buy_price INTO v_buy_price
    FROM public.trader_prices
    WHERE trader_key = p_trader_key AND resource_key = v_policy.resource_key AND is_active;
    IF NOT FOUND OR v_buy_price IS NULL THEN CONTINUE; END IF;

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

    -- Get sell_price (what trader charges player) — skip if NULL or not found
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
    'trader_key', p_trader_key,
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
-- 5. PERMISSIONS
-- ────────────────────────────────────────────────────────────

-- Harden manual sell RPC too: reject resources a trader does not buy
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
  IF NOT FOUND OR v_price IS NULL THEN RAISE EXCEPTION 'Trader does not buy this resource'; END IF;

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

-- resolve_trader_visit already granted in Phase 2A, no new RPCs needed
GRANT EXECUTE ON FUNCTION public.sell_to_trader TO authenticated;
