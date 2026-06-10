-- ─────────────────────────────────────────────────────────────────────
-- Run buy phase BEFORE sell phase in _pp_resolve_trader_visits.
--
-- Atlas was set to buy_to_reserve 100 pottery but his houses weren't
-- evolving. Diagnosis: every river_traders visit, the sell phase ran
-- first with full visit_capacity (30) and dumped 30 berries — buy
-- phase then got 0 capacity. Pottery never moved.
--
-- Fix: flip order. Buy phase runs first with full capacity; what's
-- left goes to sells. Buy demand is naturally bounded (each
-- buy_to_reserve policy stops at the reserve_target), so most visits
-- still leave plenty of capacity for selling.
-- ─────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public._pp_resolve_trader_visits(p_player_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
DECLARE
  v_trader record;
  v_last_visit timestamptz;
  v_interval interval;
  v_player_money integer;
  v_visit_at timestamptz;
  v_next_visit_at timestamptz;
  v_iterations integer;
  v_max_iterations constant integer := 50;
  v_sell record;
  v_buy record;
BEGIN
  IF NOT public.is_trade_unlocked(p_player_id) THEN RETURN; END IF;
  SELECT money INTO v_player_money FROM public.player_profiles WHERE id = p_player_id;

  FOR v_trader IN SELECT * FROM public.traders WHERE is_active LOOP
    IF NOT public._trader_is_unlocked(p_player_id, v_trader.key) THEN CONTINUE; END IF;
    v_interval := (v_trader.visit_interval_minutes::text || ' minutes')::interval;
    SELECT visited_at INTO v_last_visit
    FROM public.trader_visits
    WHERE player_id = p_player_id AND trader_key = v_trader.key
    ORDER BY visited_at DESC LIMIT 1;
    IF v_last_visit IS NULL THEN
      SELECT created_at INTO v_last_visit FROM public.player_profiles WHERE id = p_player_id;
    END IF;
    v_next_visit_at := v_last_visit + v_interval;
    v_iterations := 0;
    WHILE v_next_visit_at <= now() AND v_iterations < v_max_iterations LOOP
      v_iterations := v_iterations + 1;
      v_visit_at := v_next_visit_at;

      -- BUY phase first, but capped at half the visit capacity so
      -- the SELL phase always has room to fire on the same visit.
      -- Atlas's directive: "they should both buy and sell each visit."
      -- If the buy phase uses less than its half (e.g., reserve targets
      -- already met), the unused remainder rolls over to sells via the
      -- (visit_capacity - v_buy.capacity_used) below.
      SELECT * INTO v_buy FROM public._rtv_buy_phase(
        p_player_id, v_trader.key,
        GREATEST(1, v_trader.visit_capacity / 2),
        v_player_money
      );
      IF v_buy.spent > 0 THEN
        UPDATE public.player_profiles SET money = money - v_buy.spent WHERE id = p_player_id;
        v_player_money := v_buy.money_out;
        INSERT INTO public.cash_transactions (player_id, source, amount, context, created_at)
          VALUES (p_player_id, 'npc_trade', -v_buy.spent,
                  jsonb_build_object('trader', v_trader.key, 'direction', 'buy', 'visit_at', v_visit_at),
                  v_visit_at);
      END IF;

      -- SELL phase second: takes what capacity buys didn't.
      SELECT * INTO v_sell FROM public._rtv_sell_phase(
        p_player_id, v_trader.key, v_trader.visit_capacity - v_buy.capacity_used
      );
      IF v_sell.earned > 0 THEN
        UPDATE public.player_profiles SET money = money + v_sell.earned WHERE id = p_player_id;
        v_player_money := v_player_money + v_sell.earned;
        INSERT INTO public.cash_transactions (player_id, source, amount, context, created_at)
          VALUES (p_player_id, 'npc_trade', v_sell.earned,
                  jsonb_build_object('trader', v_trader.key, 'direction', 'sell', 'visit_at', v_visit_at),
                  v_visit_at);
      END IF;

      INSERT INTO public.trader_visits
        (trader_key, player_id, capacity_total, capacity_used, summary, visited_at)
      VALUES (v_trader.key, p_player_id, v_trader.visit_capacity,
        v_sell.capacity_used + v_buy.capacity_used,
        v_buy.summary || v_sell.summary, v_visit_at);
      v_next_visit_at := v_visit_at + v_interval;
    END LOOP;
  END LOOP;
END;
$function$;
