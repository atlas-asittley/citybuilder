-- ─────────────────────────────────────────────────────────────────────
-- Notify the counterparty when a trade agreement gets cancelled.
--
-- Atlas: "we need to add a notification for a player any time any
-- other player ends a recurring trade with that player."
--
-- The other notification surface (bell log) currently only carries
-- housing_ready_to_upgrade per Atlas's strip-down on 2026-05-08.
-- This adds a SECOND allowed event: trade_agreement_cancelled.
-- Server writes a row to player_notifications for the other party;
-- client picks it up, converts to addNotification, marks read.
--
-- RLS: read your own only. Update read_at via the canonical RPC.
-- ─────────────────────────────────────────────────────────────────────

-- (1) RLS — table didn't have policies before; add SELECT own +
-- UPDATE own (for marking read).
ALTER TABLE public.player_notifications ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS player_notifications_read ON public.player_notifications;
CREATE POLICY player_notifications_read ON public.player_notifications
  FOR SELECT USING (player_id = auth.uid());

DROP POLICY IF EXISTS player_notifications_update_own ON public.player_notifications;
CREATE POLICY player_notifications_update_own ON public.player_notifications
  FOR UPDATE USING (player_id = auth.uid());


-- (2) cancel_trade_agreement: write a notification for the other
-- party at the same time as flipping status. Only fires the
-- notification if the agreement was previously active (cancelling
-- a 'pending' offer doesn't notify — that path is mutual abandon).
CREATE OR REPLACE FUNCTION public.cancel_trade_agreement(p_agreement_id uuid)
RETURNS public.trade_agreements
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_row public.trade_agreements;
  v_other_party uuid;
  v_canceller_name text;
  v_was_active boolean;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'auth required'; END IF;

  SELECT * INTO v_row FROM public.trade_agreements
   WHERE id = p_agreement_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'agreement not found'; END IF;
  IF v_row.from_player_id <> v_uid AND v_row.to_player_id <> v_uid THEN
    RAISE EXCEPTION 'not a party to this agreement';
  END IF;
  IF v_row.status = 'cancelled' THEN RETURN v_row; END IF;

  v_was_active := (v_row.status = 'active');

  UPDATE public.trade_agreements
     SET status = 'cancelled'
   WHERE id = p_agreement_id
   RETURNING * INTO v_row;

  IF v_was_active THEN
    v_other_party := CASE
      WHEN v_row.from_player_id = v_uid THEN v_row.to_player_id
      ELSE v_row.from_player_id
    END;

    SELECT display_name INTO v_canceller_name
    FROM public.player_profiles WHERE id = v_uid;
    v_canceller_name := COALESCE(v_canceller_name, 'A player');

    INSERT INTO public.player_notifications
      (player_id, kind, title, body, payload)
    VALUES (
      v_other_party,
      'trade_agreement_cancelled',
      v_canceller_name || ' ended a recurring trade',
      v_canceller_name || ' cancelled your recurring trade agreement.',
      jsonb_build_object(
        'agreement_id', v_row.id,
        'cancelled_by_player_id', v_uid,
        'cancelled_by_name', v_canceller_name,
        'give_resources', v_row.give_resources,
        'give_money', v_row.give_money,
        'receive_resources', v_row.receive_resources,
        'receive_money', v_row.receive_money
      )
    );
  END IF;

  RETURN v_row;
END;
$function$;


-- (3) RPC the client calls each process_production tick to drain
-- any unread notifications. Returns the rows + marks them read in
-- one round-trip so a slow network doesn't cause duplicate toasts.
CREATE OR REPLACE FUNCTION public.fetch_unread_notifications()
RETURNS TABLE(id uuid, kind text, title text, body text, payload jsonb, created_at timestamptz)
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
DECLARE
  v_uid uuid := auth.uid();
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'auth required'; END IF;

  RETURN QUERY
  WITH unread AS (
    SELECT n.id AS nid, n.kind AS nkind, n.title AS ntitle,
           n.body AS nbody, n.payload AS npayload, n.created_at AS ncreated_at
    FROM public.player_notifications n
    WHERE n.player_id = v_uid AND n.read_at IS NULL
    ORDER BY n.created_at ASC
    LIMIT 50
  ), marked AS (
    UPDATE public.player_notifications pn
       SET read_at = now()
     WHERE pn.id IN (SELECT u.nid FROM unread u)
     RETURNING 1
  )
  SELECT u.nid, u.nkind, u.ntitle, u.nbody, u.npayload, u.ncreated_at
    FROM unread u
   WHERE EXISTS (SELECT 1 FROM marked);
END;
$function$;

GRANT EXECUTE ON FUNCTION public.fetch_unread_notifications() TO authenticated;
