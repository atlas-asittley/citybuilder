-- Refactor `resolve_trader_visit` (212 lines) into orchestrator + phase helpers,
-- mirroring the process_production split.
--
-- Helpers:
--   _rtv_sell_phase(uid, trader, capacity)            → (capacity_used, earned, summary)
--   _rtv_buy_phase (uid, trader, capacity, money_in)  → (capacity_used, spent, summary, money_out)
--
-- Orchestrator: validates trader/timing, runs the catch-up loop calling
-- the two phases, records each visit, and assembles the response.

-- ── Sell phase ──
-- Iterates trade_policies in mode=sell_surplus and sells surplus inventory
-- to the trader up to `p_capacity`. Writes inventories + trade_transactions.
-- Does NOT update the player's money (the orchestrator does that after).
CREATE OR REPLACE FUNCTION public._rtv_sell_phase(
  p_uid uuid,
  p_trader_key text,
  p_capacity integer
)
RETURNS TABLE(capacity_used integer, earned integer, summary jsonb)
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_remaining integer := p_capacity;
  v_earned integer := 0;
  v_summary jsonb := '[]'::jsonb;
  v_policy record;
  v_buy_price integer;
  v_inventory numeric;
  v_surplus integer;
  v_sell_amt integer;
BEGIN
  FOR v_policy IN
    SELECT tp.resource_key, tp.reserve_target
    FROM public.trade_policies tp
    WHERE tp.player_id = p_uid AND tp.mode = 'sell_surplus'
  LOOP
    IF v_remaining <= 0 THEN EXIT; END IF;
    SELECT tp.buy_price INTO v_buy_price
    FROM public.trader_prices tp
    WHERE tp.trader_key = p_trader_key
      AND tp.resource_key = v_policy.resource_key
      AND tp.is_active;
    IF NOT FOUND OR v_buy_price IS NULL THEN CONTINUE; END IF;

    SELECT COALESCE(quantity, 0) INTO v_inventory
    FROM public.inventories
    WHERE player_id = p_uid AND resource_key = v_policy.resource_key;
    IF v_inventory IS NULL THEN v_inventory := 0; END IF;

    v_surplus := GREATEST(0, FLOOR(v_inventory) - v_policy.reserve_target);
    IF v_surplus <= 0 THEN CONTINUE; END IF;
    v_sell_amt := LEAST(v_surplus, v_remaining);
    IF v_sell_amt <= 0 THEN CONTINUE; END IF;

    UPDATE public.inventories
      SET quantity = quantity - v_sell_amt, updated_at = now()
      WHERE player_id = p_uid AND resource_key = v_policy.resource_key;

    v_earned := v_earned + (v_sell_amt * v_buy_price);
    v_remaining := v_remaining - v_sell_amt;
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

  capacity_used := p_capacity - v_remaining;
  earned := v_earned;
  summary := v_summary;
  RETURN NEXT;
END;
$$;

-- ── Buy phase ──
-- Iterates trade_policies in mode=buy_to_reserve, buys up to reserve_target,
-- bounded by `p_capacity` and the player's running money balance. Returns
-- updated money. Writes inventories + trade_transactions; orchestrator
-- updates player_profiles.money once at the end of the buy phase.
CREATE OR REPLACE FUNCTION public._rtv_buy_phase(
  p_uid uuid,
  p_trader_key text,
  p_capacity integer,
  p_money_in integer
)
RETURNS TABLE(capacity_used integer, spent integer, summary jsonb, money_out integer)
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_remaining integer := p_capacity;
  v_money integer := p_money_in;
  v_spent integer := 0;
  v_summary jsonb := '[]'::jsonb;
  v_policy record;
  v_sell_price integer;
  v_inventory numeric;
  v_needed integer;
  v_buy_amt integer;
BEGIN
  FOR v_policy IN
    SELECT tp.resource_key, tp.reserve_target
    FROM public.trade_policies tp
    WHERE tp.player_id = p_uid AND tp.mode = 'buy_to_reserve'
  LOOP
    IF v_remaining <= 0 THEN EXIT; END IF;
    SELECT tp.sell_price INTO v_sell_price
    FROM public.trader_prices tp
    WHERE tp.trader_key = p_trader_key
      AND tp.resource_key = v_policy.resource_key
      AND tp.is_active;
    IF NOT FOUND OR v_sell_price IS NULL THEN CONTINUE; END IF;

    SELECT COALESCE(quantity, 0) INTO v_inventory
    FROM public.inventories
    WHERE player_id = p_uid AND resource_key = v_policy.resource_key;
    IF v_inventory IS NULL THEN v_inventory := 0; END IF;

    v_needed := GREATEST(0, v_policy.reserve_target - FLOOR(v_inventory));
    IF v_needed <= 0 THEN CONTINUE; END IF;
    v_buy_amt := LEAST(v_needed, v_remaining);
    IF v_sell_price > 0 THEN
      v_buy_amt := LEAST(v_buy_amt, FLOOR(v_money / v_sell_price));
    END IF;
    IF v_buy_amt <= 0 THEN CONTINUE; END IF;

    INSERT INTO public.inventories (player_id, resource_key, quantity)
    VALUES (p_uid, v_policy.resource_key, v_buy_amt)
    ON CONFLICT (player_id, resource_key)
    DO UPDATE SET quantity = public.inventories.quantity + v_buy_amt, updated_at = now();

    v_spent := v_spent + (v_buy_amt * v_sell_price);
    v_money := v_money - (v_buy_amt * v_sell_price);
    v_remaining := v_remaining - v_buy_amt;
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

  capacity_used := p_capacity - v_remaining;
  spent := v_spent;
  summary := v_summary;
  money_out := v_money;
  RETURN NEXT;
END;
$$;

-- ── Orchestrator ──
CREATE OR REPLACE FUNCTION public.resolve_trader_visit(p_trader_key text)
RETURNS json
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_trader record;
  v_last_visit timestamptz;
  v_interval interval;
  v_player_money integer;
  v_visit_at timestamptz;
  v_next_visit_at timestamptz;
  v_iterations integer := 0;
  v_max_iterations constant integer := 50;
  v_total_earned integer := 0;
  v_total_spent integer := 0;
  v_summary jsonb := '[]'::jsonb;
  v_visit_summary jsonb;
  v_visits_resolved integer := 0;
  v_first_visit_id uuid;
  v_last_resolved_id uuid;
  v_sell record;
  v_buy record;
BEGIN
  PERFORM public.process_production();

  SELECT * INTO v_trader FROM public.traders WHERE key = p_trader_key AND is_active;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Trader not found: %', p_trader_key;
  END IF;

  v_interval := (v_trader.visit_interval_minutes::text || ' minutes')::interval;

  SELECT visited_at INTO v_last_visit
  FROM public.trader_visits
  WHERE player_id = v_uid AND trader_key = p_trader_key
  ORDER BY visited_at DESC
  LIMIT 1;

  IF v_last_visit IS NULL THEN
    SELECT created_at INTO v_last_visit FROM public.player_profiles WHERE id = v_uid;
  END IF;

  v_next_visit_at := v_last_visit + v_interval;
  IF now() < v_next_visit_at THEN
    RETURN json_build_object(
      'visit_resolved', false,
      'next_visit_at', v_next_visit_at,
      'trader_key', p_trader_key,
      'reason', 'not_due'
    );
  END IF;

  SELECT money INTO v_player_money FROM public.player_profiles WHERE id = v_uid;

  -- Catch up every missed visit, capped at v_max_iterations.
  WHILE v_next_visit_at <= now() AND v_iterations < v_max_iterations LOOP
    v_iterations := v_iterations + 1;
    v_visit_at := v_next_visit_at;

    SELECT * INTO v_sell
      FROM public._rtv_sell_phase(v_uid, p_trader_key, v_trader.visit_capacity);
    IF v_sell.earned > 0 THEN
      UPDATE public.player_profiles SET money = money + v_sell.earned WHERE id = v_uid;
      v_player_money := v_player_money + v_sell.earned;
    END IF;

    SELECT * INTO v_buy
      FROM public._rtv_buy_phase(
        v_uid,
        p_trader_key,
        v_trader.visit_capacity - v_sell.capacity_used,
        v_player_money
      );
    IF v_buy.spent > 0 THEN
      UPDATE public.player_profiles SET money = money - v_buy.spent WHERE id = v_uid;
      v_player_money := v_buy.money_out;
    END IF;

    v_visit_summary := v_sell.summary || v_buy.summary;

    INSERT INTO public.trader_visits
      (trader_key, player_id, capacity_total, capacity_used, summary, visited_at)
    VALUES
      (p_trader_key, v_uid, v_trader.visit_capacity,
       v_sell.capacity_used + v_buy.capacity_used,
       v_visit_summary, v_visit_at)
    RETURNING id INTO v_last_resolved_id;

    IF v_first_visit_id IS NULL THEN v_first_visit_id := v_last_resolved_id; END IF;

    v_total_earned := v_total_earned + v_sell.earned;
    v_total_spent := v_total_spent + v_buy.spent;
    v_summary := v_summary || v_visit_summary;
    v_visits_resolved := v_visits_resolved + 1;
    v_next_visit_at := v_visit_at + v_interval;
  END LOOP;

  RETURN json_build_object(
    'visit_resolved', true,
    'trader_key', p_trader_key,
    'visit_id', v_last_resolved_id,
    'visits_resolved', v_visits_resolved,
    'capacity_total', v_trader.visit_capacity * v_visits_resolved,
    'capacity_used', LEAST(
      v_trader.visit_capacity * v_visits_resolved,
      jsonb_array_length(v_summary)
    ),
    'total_earned', v_total_earned,
    'total_spent', v_total_spent,
    'summary', v_summary,
    'next_visit_at', v_next_visit_at,
    'money', v_player_money,
    'inventory', COALESCE(
      (SELECT json_object_agg(resource_key, quantity)
       FROM public.inventories WHERE player_id = v_uid),
      '{}'::json
    )
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public._rtv_sell_phase(uuid, text, integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public._rtv_buy_phase(uuid, text, integer, integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.resolve_trader_visit(text) TO authenticated;
