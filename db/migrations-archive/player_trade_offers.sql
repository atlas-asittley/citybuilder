-- Player-to-player trade offers.
--
-- A player crafts an offer: "I'll give you X money + Y resources for
-- Z money + W resources." It sits in `pending` status until the
-- recipient accepts (atomic transfer) or rejects, or the sender
-- cancels. No goods are locked at propose time — sender keeps using
-- their inventory until the offer is accepted, and accept-time
-- validation re-checks balances.
--
-- Schema: player_trade_offers + four RPCs (propose, accept, reject,
-- cancel). RLS lets each side SELECT offers they're a party to.
--
-- Apply: psql "$DB_URL" -f player_trade_offers.sql

-- ── 1. Schema ──
-- An older marketplace-style player_trade_offers table existed from
-- early scaffolding (resource listings; never used, 0 rows). Drop it
-- so the schema below is the only definition.
DROP TABLE IF EXISTS public.player_trade_offers CASCADE;

CREATE TABLE public.player_trade_offers (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  from_player_id    uuid NOT NULL REFERENCES public.player_profiles(id) ON DELETE CASCADE,
  to_player_id      uuid NOT NULL REFERENCES public.player_profiles(id) ON DELETE CASCADE,
  give_money        integer NOT NULL DEFAULT 0,
  give_resources    jsonb   NOT NULL DEFAULT '{}'::jsonb,
  receive_money     integer NOT NULL DEFAULT 0,
  receive_resources jsonb   NOT NULL DEFAULT '{}'::jsonb,
  status            text    NOT NULL DEFAULT 'pending',
  message           text,
  created_at        timestamptz NOT NULL DEFAULT now(),
  resolved_at       timestamptz,
  CONSTRAINT trade_offers_status_check
    CHECK (status IN ('pending', 'accepted', 'rejected', 'cancelled')),
  CONSTRAINT trade_offers_distinct_parties
    CHECK (from_player_id <> to_player_id),
  CONSTRAINT trade_offers_money_nonneg
    CHECK (give_money >= 0 AND receive_money >= 0)
);

CREATE INDEX IF NOT EXISTS idx_trade_offers_to_status
  ON public.player_trade_offers (to_player_id, status, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_trade_offers_from_status
  ON public.player_trade_offers (from_player_id, status, created_at DESC);

ALTER TABLE public.player_trade_offers ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS trade_offers_select ON public.player_trade_offers;
CREATE POLICY trade_offers_select ON public.player_trade_offers
  FOR SELECT
  USING (auth.uid() = from_player_id OR auth.uid() = to_player_id);

-- No INSERT / UPDATE / DELETE policies — all writes go through
-- SECURITY DEFINER RPCs below.

-- ── 2. propose_trade ──
CREATE OR REPLACE FUNCTION public.propose_trade(
  p_to_player_id      uuid,
  p_give_money        integer,
  p_give_resources    jsonb,
  p_receive_money     integer,
  p_receive_resources jsonb,
  p_message           text DEFAULT NULL
) RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_offer_id uuid;
  v_resource_key text;
  v_qty numeric;
  v_target_exists boolean;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;
  IF p_to_player_id IS NULL OR p_to_player_id = v_uid THEN
    RAISE EXCEPTION 'Invalid trade target';
  END IF;
  IF p_give_money < 0 OR p_receive_money < 0 THEN
    RAISE EXCEPTION 'Money amounts must be non-negative';
  END IF;
  IF p_give_resources IS NULL THEN p_give_resources := '{}'::jsonb; END IF;
  IF p_receive_resources IS NULL THEN p_receive_resources := '{}'::jsonb; END IF;

  -- Reject empty offers.
  IF p_give_money = 0 AND p_receive_money = 0
     AND p_give_resources = '{}'::jsonb AND p_receive_resources = '{}'::jsonb THEN
    RAISE EXCEPTION 'Trade offer cannot be empty';
  END IF;

  -- Confirm target player exists.
  SELECT EXISTS(SELECT 1 FROM public.player_profiles WHERE id = p_to_player_id)
    INTO v_target_exists;
  IF NOT v_target_exists THEN
    RAISE EXCEPTION 'Target player not found';
  END IF;

  -- Validate every resource_key actually exists. Better to fail at
  -- propose time than silently create an unaccepteable offer.
  FOR v_resource_key, v_qty IN
    SELECT key, value::text::numeric FROM jsonb_each_text(p_give_resources)
  LOOP
    IF v_qty <= 0 THEN
      RAISE EXCEPTION 'give_resources qty for % must be positive', v_resource_key;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM public.resources WHERE key = v_resource_key) THEN
      RAISE EXCEPTION 'Unknown resource: %', v_resource_key;
    END IF;
  END LOOP;
  FOR v_resource_key, v_qty IN
    SELECT key, value::text::numeric FROM jsonb_each_text(p_receive_resources)
  LOOP
    IF v_qty <= 0 THEN
      RAISE EXCEPTION 'receive_resources qty for % must be positive', v_resource_key;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM public.resources WHERE key = v_resource_key) THEN
      RAISE EXCEPTION 'Unknown resource: %', v_resource_key;
    END IF;
  END LOOP;

  INSERT INTO public.player_trade_offers (
    from_player_id, to_player_id,
    give_money, give_resources,
    receive_money, receive_resources,
    message
  ) VALUES (
    v_uid, p_to_player_id,
    p_give_money, p_give_resources,
    p_receive_money, p_receive_resources,
    p_message
  ) RETURNING id INTO v_offer_id;

  RETURN v_offer_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.propose_trade(uuid, integer, jsonb, integer, jsonb, text) TO authenticated;

-- ── 3. accept_trade ──
CREATE OR REPLACE FUNCTION public.accept_trade(p_offer_id uuid)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
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

  -- Re-validate balances at accept time.
  IF v_sender_money < v_offer.give_money THEN
    RAISE EXCEPTION 'Sender no longer has the offered money (need %, has %)',
      v_offer.give_money, v_sender_money;
  END IF;
  IF v_recipient_money < v_offer.receive_money THEN
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
      RAISE EXCEPTION 'You no longer have enough % (need %, have %)',
        v_resource_key, v_qty, COALESCE(v_have, 0);
    END IF;
  END LOOP;

  -- Money: sender pays give_money, gains receive_money. Recipient
  -- mirror. (We've already locked both rows.)
  UPDATE public.player_profiles
    SET money = money - v_offer.give_money + v_offer.receive_money
    WHERE id = v_offer.from_player_id;
  UPDATE public.player_profiles
    SET money = money + v_offer.give_money - v_offer.receive_money
    WHERE id = v_offer.to_player_id;

  -- give_resources: sender → recipient
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

  -- receive_resources: recipient → sender
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
$$;

GRANT EXECUTE ON FUNCTION public.accept_trade(uuid) TO authenticated;

-- ── 4. reject_trade ──
CREATE OR REPLACE FUNCTION public.reject_trade(p_offer_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_offer record;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
  SELECT * INTO v_offer FROM public.player_trade_offers
    WHERE id = p_offer_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Offer not found'; END IF;
  IF v_offer.to_player_id <> v_uid THEN
    RAISE EXCEPTION 'Only the recipient can reject this offer';
  END IF;
  IF v_offer.status <> 'pending' THEN
    RAISE EXCEPTION 'Offer is %', v_offer.status;
  END IF;
  UPDATE public.player_trade_offers
    SET status = 'rejected', resolved_at = now()
    WHERE id = p_offer_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.reject_trade(uuid) TO authenticated;

-- ── 5. cancel_trade ──
CREATE OR REPLACE FUNCTION public.cancel_trade(p_offer_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_offer record;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
  SELECT * INTO v_offer FROM public.player_trade_offers
    WHERE id = p_offer_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Offer not found'; END IF;
  IF v_offer.from_player_id <> v_uid THEN
    RAISE EXCEPTION 'Only the sender can cancel this offer';
  END IF;
  IF v_offer.status <> 'pending' THEN
    RAISE EXCEPTION 'Offer is %', v_offer.status;
  END IF;
  UPDATE public.player_trade_offers
    SET status = 'cancelled', resolved_at = now()
    WHERE id = p_offer_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.cancel_trade(uuid) TO authenticated;
