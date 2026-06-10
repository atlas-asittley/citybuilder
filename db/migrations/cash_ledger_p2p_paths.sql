-- ── Cash ledger: log P2P + black-market paths (2026-05-08 audit, follow-up) ──
-- The previous migration (cash_ledger_completeness.sql) caught the
-- biggest gap (auto-trader). This patches the remaining money paths
-- that also bypass cash_transactions:
--
--   accept_trade        → both sides logged as p2p_trade
--   _pp_run_agreements  → both sides logged as p2p_agreement
--   black_market_trade  → logged as black_market
--
-- After this, every server-side money mutator writes a corresponding
-- ledger entry. The Treasury panel will show the full earned/spent
-- breakdown across all 6+ income/expense categories.

-- accept_trade — both sides of a one-shot P2P offer.
CREATE OR REPLACE FUNCTION public.accept_trade(p_offer_id uuid)
 RETURNS json LANGUAGE plpgsql SECURITY DEFINER AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_offer record;
  v_sender_money integer;
  v_recipient_money integer;
  v_resource_key text;
  v_qty numeric;
  v_have numeric;
  v_sender_delta integer;
  v_recipient_delta integer;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;

  SELECT * INTO v_offer FROM public.player_trade_offers
    WHERE id = p_offer_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Offer not found'; END IF;
  IF v_offer.to_player_id <> v_uid THEN
    RAISE EXCEPTION 'Only the recipient can accept this offer';
  END IF;
  IF v_offer.status <> 'pending' THEN
    RAISE EXCEPTION 'Offer is %', v_offer.status;
  END IF;

  IF v_offer.from_player_id < v_offer.to_player_id THEN
    SELECT money INTO v_sender_money FROM public.player_profiles
      WHERE id = v_offer.from_player_id FOR UPDATE;
    SELECT money INTO v_recipient_money FROM public.player_profiles
      WHERE id = v_offer.to_player_id FOR UPDATE;
  ELSE
    SELECT money INTO v_recipient_money FROM public.player_profiles
      WHERE id = v_offer.to_player_id FOR UPDATE;
    SELECT money INTO v_sender_money FROM public.player_profiles
      WHERE id = v_offer.from_player_id FOR UPDATE;
  END IF;

  IF v_offer.give_money > 0 AND v_sender_money < v_offer.give_money THEN
    RAISE EXCEPTION 'Sender no longer has the offered money (need %, has %)',
      v_offer.give_money, v_sender_money;
  END IF;
  IF v_offer.receive_money > 0 AND v_recipient_money < v_offer.receive_money THEN
    RAISE EXCEPTION 'You no longer have the requested money (need %, have %)',
      v_offer.receive_money, v_recipient_money;
  END IF;

  FOR v_resource_key, v_qty IN
    SELECT key, value::text::numeric FROM jsonb_each_text(v_offer.give_resources)
  LOOP
    SELECT COALESCE(quantity, 0) INTO v_have FROM public.inventories
      WHERE player_id = v_offer.from_player_id AND resource_key = v_resource_key;
    IF v_have IS NULL OR v_have < v_qty THEN
      RAISE EXCEPTION 'Sender no longer has enough % (need %, has %)',
        v_resource_key, v_qty, COALESCE(v_have, 0);
    END IF;
  END LOOP;
  FOR v_resource_key, v_qty IN
    SELECT key, value::text::numeric FROM jsonb_each_text(v_offer.receive_resources)
  LOOP
    SELECT COALESCE(quantity, 0) INTO v_have FROM public.inventories
      WHERE player_id = v_offer.to_player_id AND resource_key = v_resource_key;
    IF v_have IS NULL OR v_have < v_qty THEN
      RAISE EXCEPTION 'You no longer have enough % (need %, has %)',
        v_resource_key, v_qty, COALESCE(v_have, 0);
    END IF;
  END LOOP;

  v_sender_delta := -v_offer.give_money + v_offer.receive_money;
  v_recipient_delta := v_offer.give_money - v_offer.receive_money;

  UPDATE public.player_profiles SET money = money + v_sender_delta
    WHERE id = v_offer.from_player_id;
  IF v_sender_delta <> 0 THEN
    INSERT INTO public.cash_transactions (player_id, source, amount, context)
      VALUES (v_offer.from_player_id, 'p2p_trade', v_sender_delta,
              jsonb_build_object('offer_id', p_offer_id, 'role', 'sender'));
  END IF;

  UPDATE public.player_profiles SET money = money + v_recipient_delta
    WHERE id = v_offer.to_player_id;
  IF v_recipient_delta <> 0 THEN
    INSERT INTO public.cash_transactions (player_id, source, amount, context)
      VALUES (v_offer.to_player_id, 'p2p_trade', v_recipient_delta,
              jsonb_build_object('offer_id', p_offer_id, 'role', 'recipient'));
  END IF;

  FOR v_resource_key, v_qty IN
    SELECT key, value::text::numeric FROM jsonb_each_text(v_offer.give_resources)
  LOOP
    UPDATE public.inventories
      SET quantity = quantity - v_qty, updated_at = now()
      WHERE player_id = v_offer.from_player_id AND resource_key = v_resource_key;
    INSERT INTO public.inventories (player_id, resource_key, quantity)
    VALUES (v_offer.to_player_id, v_resource_key, v_qty)
    ON CONFLICT (player_id, resource_key) DO UPDATE SET
      quantity = public.inventories.quantity + EXCLUDED.quantity,
      updated_at = now();
  END LOOP;

  FOR v_resource_key, v_qty IN
    SELECT key, value::text::numeric FROM jsonb_each_text(v_offer.receive_resources)
  LOOP
    UPDATE public.inventories
      SET quantity = quantity - v_qty, updated_at = now()
      WHERE player_id = v_offer.to_player_id AND resource_key = v_resource_key;
    INSERT INTO public.inventories (player_id, resource_key, quantity)
    VALUES (v_offer.from_player_id, v_resource_key, v_qty)
    ON CONFLICT (player_id, resource_key) DO UPDATE SET
      quantity = public.inventories.quantity + EXCLUDED.quantity,
      updated_at = now();
  END LOOP;

  UPDATE public.player_trade_offers
    SET status = 'accepted', resolved_at = now()
    WHERE id = p_offer_id;

  RETURN json_build_object('offer_id', p_offer_id, 'status', 'accepted');
END;
$function$;

-- _pp_run_agreements — log both sides of a recurring P2P agreement.
CREATE OR REPLACE FUNCTION public._pp_run_agreements(p_uid uuid)
 RETURNS void LANGUAGE plpgsql SECURITY DEFINER AS $function$
DECLARE
  v_agr public.trade_agreements;
  v_key TEXT;
  v_qty NUMERIC;
  v_can_fire BOOLEAN;
  v_from_money INTEGER;
  v_to_money INTEGER;
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

  -- Money flows: each direction logged with corresponding cash entry.
  IF v_agr.give_money > 0 THEN
    UPDATE public.player_profiles SET money = money - v_agr.give_money WHERE id = v_agr.from_player_id;
    INSERT INTO public.cash_transactions (player_id, source, amount, context)
      VALUES (v_agr.from_player_id, 'p2p_agreement', -v_agr.give_money,
              jsonb_build_object('agreement_id', v_agr.id, 'role', 'sender_pays'));
    UPDATE public.player_profiles SET money = money + v_agr.give_money WHERE id = v_agr.to_player_id;
    INSERT INTO public.cash_transactions (player_id, source, amount, context)
      VALUES (v_agr.to_player_id, 'p2p_agreement', v_agr.give_money,
              jsonb_build_object('agreement_id', v_agr.id, 'role', 'recipient_receives'));
  END IF;
  IF v_agr.receive_money > 0 THEN
    UPDATE public.player_profiles SET money = money - v_agr.receive_money WHERE id = v_agr.to_player_id;
    INSERT INTO public.cash_transactions (player_id, source, amount, context)
      VALUES (v_agr.to_player_id, 'p2p_agreement', -v_agr.receive_money,
              jsonb_build_object('agreement_id', v_agr.id, 'role', 'recipient_pays'));
    UPDATE public.player_profiles SET money = money + v_agr.receive_money WHERE id = v_agr.from_player_id;
    INSERT INTO public.cash_transactions (player_id, source, amount, context)
      VALUES (v_agr.from_player_id, 'p2p_agreement', v_agr.receive_money,
              jsonb_build_object('agreement_id', v_agr.id, 'role', 'sender_receives'));
  END IF;

  UPDATE public.trade_agreements
     SET last_fired_at = last_fired_at + (interval_minutes || ' minutes')::interval
   WHERE id = v_agr.id;
END;
$function$;

-- black_market_trade — buy or sell logged as 'black_market' (signed).
CREATE OR REPLACE FUNCTION public.black_market_trade(p_resource_key text, p_quantity integer, p_direction text)
 RETURNS json LANGUAGE plpgsql SECURITY DEFINER AS $function$
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
  IF p_quantity < 1 THEN RAISE EXCEPTION 'Quantity must be at least 1'; END IF;

  PERFORM public.process_production();

  SELECT
    CASE p_resource_key
      WHEN 'timber' THEN 1 WHEN 'stone' THEN 1 WHEN 'lumber' THEN 3
      WHEN 'brick' THEN 4 WHEN 'grain' THEN 1 WHEN 'flour' THEN 3
      WHEN 'clay' THEN 1 WHEN 'pottery' THEN 3 WHEN 'bread' THEN 5
      WHEN 'furniture' THEN 7 WHEN 'statuary' THEN 7 ELSE NULL END,
    CASE p_resource_key
      WHEN 'timber' THEN 10 WHEN 'stone' THEN 11 WHEN 'lumber' THEN 18
      WHEN 'brick' THEN 20 WHEN 'grain' THEN 9 WHEN 'flour' THEN 16
      WHEN 'clay' THEN 8 WHEN 'pottery' THEN 15 WHEN 'bread' THEN 22
      WHEN 'furniture' THEN 28 WHEN 'statuary' THEN 30 ELSE NULL END
  INTO v_buy_from_player, v_sell_to_player;

  IF v_buy_from_player IS NULL THEN
    RAISE EXCEPTION 'Resource not available on black market: %', p_resource_key;
  END IF;

  IF p_direction = 'sell' THEN
    v_unit_price := v_buy_from_player;
    v_total := v_unit_price * p_quantity;

    SELECT COALESCE(quantity, 0) INTO v_available
    FROM public.inventories WHERE player_id = v_uid AND resource_key = p_resource_key;
    IF v_available IS NULL OR v_available < p_quantity THEN
      RAISE EXCEPTION 'Not enough % (have %, need %)', p_resource_key, COALESCE(v_available, 0), p_quantity;
    END IF;

    UPDATE public.inventories SET quantity = quantity - p_quantity, updated_at = now()
    WHERE player_id = v_uid AND resource_key = p_resource_key;

    UPDATE public.player_profiles SET money = money + v_total WHERE id = v_uid
      RETURNING money INTO v_new_money;
    INSERT INTO public.cash_transactions (player_id, source, amount, context)
      VALUES (v_uid, 'black_market', v_total,
              jsonb_build_object('resource', p_resource_key, 'quantity', p_quantity,
                                 'unit_price', v_unit_price, 'direction', 'sell'));

    INSERT INTO public.trade_transactions (player_id, trader_key, resource_key, quantity, unit_price, total_price, transaction_type)
    VALUES (v_uid, 'black_market', p_resource_key, p_quantity, v_unit_price, v_total, 'sell');
  ELSE
    v_unit_price := v_sell_to_player;
    v_total := v_unit_price * p_quantity;

    SELECT money INTO v_player_money FROM public.player_profiles WHERE id = v_uid;
    IF v_player_money < v_total THEN
      RAISE EXCEPTION 'Not enough money (have $%, need $%)', v_player_money, v_total;
    END IF;

    UPDATE public.player_profiles SET money = money - v_total WHERE id = v_uid
      RETURNING money INTO v_new_money;
    INSERT INTO public.cash_transactions (player_id, source, amount, context)
      VALUES (v_uid, 'black_market', -v_total,
              jsonb_build_object('resource', p_resource_key, 'quantity', p_quantity,
                                 'unit_price', v_unit_price, 'direction', 'buy'));

    INSERT INTO public.inventories (player_id, resource_key, quantity)
    VALUES (v_uid, p_resource_key, p_quantity)
    ON CONFLICT (player_id, resource_key)
    DO UPDATE SET quantity = inventories.quantity + p_quantity, updated_at = now();

    INSERT INTO public.trade_transactions (player_id, trader_key, resource_key, quantity, unit_price, total_price, transaction_type)
    VALUES (v_uid, 'black_market', p_resource_key, p_quantity, v_unit_price, v_total, 'buy');
  END IF;

  RETURN json_build_object(
    'direction', p_direction, 'resource', p_resource_key,
    'quantity', p_quantity, 'unit_price', v_unit_price,
    'total_price', v_total, 'money', v_new_money,
    'inventory', COALESCE(
      (SELECT json_object_agg(resource_key, quantity) FROM public.inventories WHERE player_id = v_uid),
      '{}'::json));
END;
$function$;
