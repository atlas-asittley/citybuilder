-- ─────────────────────────────────────────────────────────────────────
-- Two follow-ups to cash_transactions_period_start.sql:
--
-- (1) Backfill period_start on EXISTING upkeep + tax_revenue rows by
--     looking at the gap to the previous row in the same
--     (player_id, source) sequence. So the historical -$4150 spike
--     that came after 415 minutes of no upkeep entries gets stamped
--     period_start = (its created_at − 415 min). The chart can then
--     spread it across the right days retroactively.
--
--     First row per (player, source) has no LAG and stays NULL —
--     displayed as a point event. Harmless.
--
-- (2) For event-based catch-up phases (_pp_run_agreements and
--     _pp_resolve_trader_visits), backdate created_at to the
--     conceptual moment of each event rather than now(). Each iteration
--     of the catch-up loop already knows its target moment (the next
--     fire / visit timestamp). Just override the INSERT default.
-- ─────────────────────────────────────────────────────────────────────


-- ── (1) Backfill ──
WITH ordered AS (
  SELECT id,
         LAG(created_at) OVER (PARTITION BY player_id, source ORDER BY created_at) AS prev_at
  FROM public.cash_transactions
  WHERE source IN ('upkeep', 'tax_revenue')
    AND period_start IS NULL
)
UPDATE public.cash_transactions ct
   SET period_start = o.prev_at
  FROM ordered o
 WHERE ct.id = o.id
   AND o.prev_at IS NOT NULL;


-- ── (2a) Agreements: backdate created_at to (last_fired_at + interval),
--     which is the moment THIS iteration is conceptually firing at.
--     Captured in v_fire_at before we bump last_fired_at on the row.
CREATE OR REPLACE FUNCTION public._pp_run_agreements(p_uid uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
DECLARE
  v_agr public.trade_agreements;
  v_key TEXT;
  v_qty NUMERIC;
  v_can_fire BOOLEAN;
  v_from_money INTEGER;
  v_to_money INTEGER;
  v_fire_at TIMESTAMPTZ;
BEGIN
  SELECT * INTO v_agr
    FROM public.trade_agreements
   WHERE status = 'active'
     AND from_player_id = p_uid
     AND last_fired_at + (interval_minutes || ' minutes')::interval <= now()
   ORDER BY last_fired_at ASC
   LIMIT 1
   FOR UPDATE SKIP LOCKED;
  IF NOT FOUND THEN RETURN; END IF;

  -- Conceptual fire moment for THIS iteration. Capped at now() in case
  -- a fast-clock test races; chart code just sees a point event then.
  v_fire_at := LEAST(now(), v_agr.last_fired_at + (v_agr.interval_minutes || ' minutes')::interval);

  v_can_fire := TRUE;

  FOR v_key, v_qty IN SELECT k, val::numeric FROM jsonb_each_text(v_agr.give_resources) AS j(k, val) LOOP
    IF (SELECT COALESCE(quantity, 0) FROM public.inventories
         WHERE player_id = v_agr.from_player_id AND resource_key = v_key) < v_qty THEN
      v_can_fire := FALSE; EXIT;
    END IF;
  END LOOP;

  IF v_can_fire THEN
    FOR v_key, v_qty IN SELECT k, val::numeric FROM jsonb_each_text(v_agr.receive_resources) AS j(k, val) LOOP
      IF (SELECT COALESCE(quantity, 0) FROM public.inventories
           WHERE player_id = v_agr.to_player_id AND resource_key = v_key) < v_qty THEN
        v_can_fire := FALSE; EXIT;
      END IF;
    END LOOP;
  END IF;

  IF v_can_fire AND v_agr.give_money > 0 THEN
    SELECT money INTO v_from_money FROM public.player_profiles WHERE id = v_agr.from_player_id;
    IF v_from_money < v_agr.give_money THEN v_can_fire := FALSE; END IF;
  END IF;
  IF v_can_fire AND v_agr.receive_money > 0 THEN
    SELECT money INTO v_to_money FROM public.player_profiles WHERE id = v_agr.to_player_id;
    IF v_to_money < v_agr.receive_money THEN v_can_fire := FALSE; END IF;
  END IF;

  IF NOT v_can_fire THEN RETURN; END IF;

  -- Resource flows
  FOR v_key, v_qty IN SELECT k, val::numeric FROM jsonb_each_text(v_agr.give_resources) AS j(k, val) LOOP
    UPDATE public.inventories SET quantity = quantity - v_qty
      WHERE player_id = v_agr.from_player_id AND resource_key = v_key;
    INSERT INTO public.inventories (player_id, resource_key, quantity)
      VALUES (v_agr.to_player_id, v_key, v_qty)
      ON CONFLICT (player_id, resource_key)
      DO UPDATE SET quantity = inventories.quantity + EXCLUDED.quantity;
  END LOOP;

  FOR v_key, v_qty IN SELECT k, val::numeric FROM jsonb_each_text(v_agr.receive_resources) AS j(k, val) LOOP
    UPDATE public.inventories SET quantity = quantity - v_qty
      WHERE player_id = v_agr.to_player_id AND resource_key = v_key;
    INSERT INTO public.inventories (player_id, resource_key, quantity)
      VALUES (v_agr.from_player_id, v_key, v_qty)
      ON CONFLICT (player_id, resource_key)
      DO UPDATE SET quantity = inventories.quantity + EXCLUDED.quantity;
  END LOOP;

  IF v_agr.give_money > 0 THEN
    UPDATE public.player_profiles SET money = money - v_agr.give_money WHERE id = v_agr.from_player_id;
    INSERT INTO public.cash_transactions (player_id, source, amount, context, created_at)
      VALUES (v_agr.from_player_id, 'p2p_agreement', -v_agr.give_money,
              jsonb_build_object('agreement_id', v_agr.id, 'role', 'sender_pays'),
              v_fire_at);
    UPDATE public.player_profiles SET money = money + v_agr.give_money WHERE id = v_agr.to_player_id;
    INSERT INTO public.cash_transactions (player_id, source, amount, context, created_at)
      VALUES (v_agr.to_player_id, 'p2p_agreement', v_agr.give_money,
              jsonb_build_object('agreement_id', v_agr.id, 'role', 'recipient_receives'),
              v_fire_at);
  END IF;
  IF v_agr.receive_money > 0 THEN
    UPDATE public.player_profiles SET money = money - v_agr.receive_money WHERE id = v_agr.to_player_id;
    INSERT INTO public.cash_transactions (player_id, source, amount, context, created_at)
      VALUES (v_agr.to_player_id, 'p2p_agreement', -v_agr.receive_money,
              jsonb_build_object('agreement_id', v_agr.id, 'role', 'recipient_pays'),
              v_fire_at);
    UPDATE public.player_profiles SET money = money + v_agr.receive_money WHERE id = v_agr.from_player_id;
    INSERT INTO public.cash_transactions (player_id, source, amount, context, created_at)
      VALUES (v_agr.from_player_id, 'p2p_agreement', v_agr.receive_money,
              jsonb_build_object('agreement_id', v_agr.id, 'role', 'sender_receives'),
              v_fire_at);
  END IF;

  UPDATE public.trade_agreements
     SET last_fired_at = last_fired_at + (interval_minutes || ' minutes')::interval
   WHERE id = v_agr.id;
END;
$function$;


-- ── (2b) Trader visits: each WHILE iteration already computes v_visit_at
--     (the conceptual visit moment). Use it for the cash_transactions
--     created_at instead of letting the default `now()` collapse them.
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

      SELECT * INTO v_sell FROM public._rtv_sell_phase(p_player_id, v_trader.key, v_trader.visit_capacity);
      IF v_sell.earned > 0 THEN
        UPDATE public.player_profiles SET money = money + v_sell.earned WHERE id = p_player_id;
        v_player_money := v_player_money + v_sell.earned;
        INSERT INTO public.cash_transactions (player_id, source, amount, context, created_at)
          VALUES (p_player_id, 'npc_trade', v_sell.earned,
                  jsonb_build_object('trader', v_trader.key, 'direction', 'sell', 'visit_at', v_visit_at),
                  v_visit_at);
      END IF;

      SELECT * INTO v_buy FROM public._rtv_buy_phase(p_player_id, v_trader.key,
        v_trader.visit_capacity - v_sell.capacity_used, v_player_money);
      IF v_buy.spent > 0 THEN
        UPDATE public.player_profiles SET money = money - v_buy.spent WHERE id = p_player_id;
        v_player_money := v_buy.money_out;
        INSERT INTO public.cash_transactions (player_id, source, amount, context, created_at)
          VALUES (p_player_id, 'npc_trade', -v_buy.spent,
                  jsonb_build_object('trader', v_trader.key, 'direction', 'buy', 'visit_at', v_visit_at),
                  v_visit_at);
      END IF;

      INSERT INTO public.trader_visits
        (trader_key, player_id, capacity_total, capacity_used, summary, visited_at)
      VALUES (v_trader.key, p_player_id, v_trader.visit_capacity,
        v_sell.capacity_used + v_buy.capacity_used,
        v_sell.summary || v_buy.summary, v_visit_at);
      v_next_visit_at := v_visit_at + v_interval;
    END LOOP;
  END LOOP;
END;
$function$;
