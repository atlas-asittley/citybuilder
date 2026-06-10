-- Make resolve_trader_visit catch up the full backlog of missed visits
-- when a player returns after a long absence — so a sell-surplus /
-- buy-to-reserve policy keeps "selling while they're not there", just
-- resolved lazily on next visit. Mirrors how process_production catches
-- up production for the elapsed time.
--
-- Previously: one call resolved ONE missed visit and stamped
-- visited_at = now(), so if a player was offline 2h with a 10-min
-- interval, only 1 of the 12 missed visits actually ran. The remaining
-- 11 were silently dropped.
--
-- Now: the function loops while next_visit_at <= now(), processing one
-- visit per iteration (recording each in trader_visits with its actual
-- conceptual timestamp). Capped at 50 iterations per call as a runaway
-- guard.
--
-- Apply: psql "$DB_URL" -f trader_full_catchup.sql

CREATE OR REPLACE FUNCTION public.resolve_trader_visit(p_trader_key text)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
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
  v_player_money integer;
  v_visit_id uuid;
  v_next_visit_at timestamptz;
  v_visit_at timestamptz;
  v_iterations integer := 0;
  v_max_iterations constant integer := 50;
  v_total_earned integer := 0;
  v_total_spent integer := 0;
  v_summary jsonb := '[]'::jsonb;
  v_visit_summary jsonb;
  v_visit_earned integer;
  v_visit_spent integer;
  v_visits_resolved integer := 0;
  v_first_visit_id uuid;
  v_last_resolved_id uuid;
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
    v_visit_at := v_next_visit_at;     -- conceptual timestamp of THIS visit
    v_capacity_remaining := v_trader.visit_capacity;
    v_visit_summary := '[]'::jsonb;
    v_visit_earned := 0;
    v_visit_spent := 0;

    -- ── PHASE 1: Process sells ──
    FOR v_policy IN
      SELECT tp.resource_key, tp.mode, tp.reserve_target
      FROM public.trade_policies tp
      WHERE tp.player_id = v_uid AND tp.mode = 'sell_surplus'
    LOOP
      IF v_capacity_remaining <= 0 THEN EXIT; END IF;
      SELECT buy_price INTO v_buy_price
      FROM public.trader_prices
      WHERE trader_key = p_trader_key AND resource_key = v_policy.resource_key AND is_active;
      IF NOT FOUND OR v_buy_price IS NULL THEN CONTINUE; END IF;
      SELECT COALESCE(quantity, 0) INTO v_inventory
      FROM public.inventories
      WHERE player_id = v_uid AND resource_key = v_policy.resource_key;
      IF v_inventory IS NULL THEN v_inventory := 0; END IF;
      v_surplus := GREATEST(0, FLOOR(v_inventory) - v_policy.reserve_target);
      IF v_surplus <= 0 THEN CONTINUE; END IF;
      v_sell_amt := LEAST(v_surplus, v_capacity_remaining);
      IF v_sell_amt <= 0 THEN CONTINUE; END IF;
      UPDATE public.inventories
        SET quantity = quantity - v_sell_amt, updated_at = now()
        WHERE player_id = v_uid AND resource_key = v_policy.resource_key;
      v_visit_earned := v_visit_earned + (v_sell_amt * v_buy_price);
      v_capacity_remaining := v_capacity_remaining - v_sell_amt;
      v_visit_summary := v_visit_summary || jsonb_build_object(
        'type', 'sell',
        'resource', v_policy.resource_key,
        'quantity', v_sell_amt,
        'unit_price', v_buy_price,
        'total', v_sell_amt * v_buy_price
      );
      INSERT INTO public.trade_transactions
        (player_id, trader_key, resource_key, quantity, unit_price, total_price, transaction_type)
      VALUES
        (v_uid, p_trader_key, v_policy.resource_key, v_sell_amt, v_buy_price,
         v_sell_amt * v_buy_price, 'sell');
    END LOOP;

    IF v_visit_earned > 0 THEN
      UPDATE public.player_profiles SET money = money + v_visit_earned WHERE id = v_uid;
      v_player_money := v_player_money + v_visit_earned;
    END IF;

    -- ── PHASE 2: Process buys ──
    FOR v_policy IN
      SELECT tp.resource_key, tp.mode, tp.reserve_target
      FROM public.trade_policies tp
      WHERE tp.player_id = v_uid AND tp.mode = 'buy_to_reserve'
    LOOP
      IF v_capacity_remaining <= 0 THEN EXIT; END IF;
      SELECT tp.sell_price INTO v_sell_price
      FROM public.trader_prices tp
      WHERE tp.trader_key = p_trader_key AND tp.resource_key = v_policy.resource_key AND tp.is_active;
      IF NOT FOUND OR v_sell_price IS NULL THEN CONTINUE; END IF;
      SELECT COALESCE(quantity, 0) INTO v_inventory
      FROM public.inventories
      WHERE player_id = v_uid AND resource_key = v_policy.resource_key;
      IF v_inventory IS NULL THEN v_inventory := 0; END IF;
      v_needed := GREATEST(0, v_policy.reserve_target - FLOOR(v_inventory));
      IF v_needed <= 0 THEN CONTINUE; END IF;
      v_buy_amt := LEAST(v_needed, v_capacity_remaining);
      IF v_sell_price > 0 THEN
        v_buy_amt := LEAST(v_buy_amt, FLOOR(v_player_money / v_sell_price));
      END IF;
      IF v_buy_amt <= 0 THEN CONTINUE; END IF;
      INSERT INTO public.inventories (player_id, resource_key, quantity)
      VALUES (v_uid, v_policy.resource_key, v_buy_amt)
      ON CONFLICT (player_id, resource_key)
      DO UPDATE SET quantity = public.inventories.quantity + v_buy_amt, updated_at = now();
      v_visit_spent := v_visit_spent + (v_buy_amt * v_sell_price);
      v_player_money := v_player_money - (v_buy_amt * v_sell_price);
      v_capacity_remaining := v_capacity_remaining - v_buy_amt;
      v_visit_summary := v_visit_summary || jsonb_build_object(
        'type', 'buy',
        'resource', v_policy.resource_key,
        'quantity', v_buy_amt,
        'unit_price', v_sell_price,
        'total', v_buy_amt * v_sell_price
      );
      INSERT INTO public.trade_transactions
        (player_id, trader_key, resource_key, quantity, unit_price, total_price, transaction_type)
      VALUES
        (v_uid, p_trader_key, v_policy.resource_key, v_buy_amt, v_sell_price,
         v_buy_amt * v_sell_price, 'buy');
    END LOOP;

    IF v_visit_spent > 0 THEN
      UPDATE public.player_profiles SET money = money - v_visit_spent WHERE id = v_uid;
    END IF;

    INSERT INTO public.trader_visits
      (trader_key, player_id, capacity_total, capacity_used, summary, visited_at)
    VALUES
      (p_trader_key, v_uid, v_trader.visit_capacity,
       v_trader.visit_capacity - v_capacity_remaining, v_visit_summary, v_visit_at)
    RETURNING id INTO v_last_resolved_id;

    IF v_first_visit_id IS NULL THEN v_first_visit_id := v_last_resolved_id; END IF;

    v_total_earned := v_total_earned + v_visit_earned;
    v_total_spent := v_total_spent + v_visit_spent;
    -- Concatenate this visit's line items into the aggregate summary,
    -- prefixed with which catch-up tick they came from for readability.
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
$function$;

GRANT EXECUTE ON FUNCTION public.resolve_trader_visit(text) TO authenticated;
