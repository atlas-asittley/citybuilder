-- ====================================================================
-- accept_trade: don't reject zero-money asks against negative balances
-- ====================================================================
-- Atlas tried to send Jill (cash $-299) money via player trade. The
-- offer's receive_money was 0 (Atlas wanted nothing back), but the
-- accept-time balance check did:
--
--   IF v_recipient_money < v_offer.receive_money THEN ...
--
-- With v_recipient_money = -299 and v_offer.receive_money = 0,
-- -299 < 0 is true → "You no longer have the requested money
-- (need 0, have -299)". Trade blocked even though no money was
-- actually being asked.
--
-- Fix: only re-validate the balance when the offer ACTUALLY asks for
-- money (i.e. give_money > 0 or receive_money > 0). A zero ask is
-- always satisfiable regardless of the counterparty's balance.
--
-- Same logic applied to the sender check for symmetry — a zero
-- give_money offer should never fail on the sender's balance either.

CREATE OR REPLACE FUNCTION public.accept_trade(p_offer_id uuid)
RETURNS json
LANGUAGE plpgsql SECURITY DEFINER
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_offer record;
  v_sender_money integer;
  v_recipient_money integer;
  v_resource_key text;
  v_qty numeric;
  v_have numeric;
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

  -- Lock both player_profiles rows (consistent order to avoid deadlock).
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

  -- Re-validate balances at accept time. Skip the comparison entirely
  -- when no money is being asked — a zero ask is always satisfiable
  -- regardless of the counterparty's current balance (which may be
  -- negative if they're in upkeep deficit).
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

  UPDATE public.player_profiles
    SET money = money - v_offer.give_money + v_offer.receive_money
    WHERE id = v_offer.from_player_id;
  UPDATE public.player_profiles
    SET money = money + v_offer.give_money - v_offer.receive_money
    WHERE id = v_offer.to_player_id;

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

  RETURN json_build_object(
    'offer_id', p_offer_id,
    'status', 'accepted'
  );
END;
$function$;
