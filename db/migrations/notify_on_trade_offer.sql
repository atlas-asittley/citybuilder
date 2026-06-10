-- ─────────────────────────────────────────────────────────────────────
-- Notify the recipient when someone proposes a recurring trade.
--
-- Atlas: 'we need to notify a player any time someone offers them
-- a trade.'
--
-- Implemented as an AFTER INSERT trigger on trade_agreements so any
-- code path that creates a pending agreement fires the notification —
-- not just propose_trade_agreement. The drain RPC
-- fetch_unread_notifications already returns this kind alongside
-- trade_agreement_cancelled, and the client tick already renders
-- them via addNotification.
-- ─────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public._on_trade_agreement_proposed()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
DECLARE
  v_proposer_name text;
BEGIN
  -- Only fire for fresh PENDING offers (status='pending' is the
  -- default at INSERT). Don't fire if a row was inserted with some
  -- other status — that would be admin / system writes, not a real
  -- offer.
  IF NEW.status <> 'pending' THEN RETURN NEW; END IF;

  SELECT display_name INTO v_proposer_name
  FROM public.player_profiles WHERE id = NEW.from_player_id;
  v_proposer_name := COALESCE(v_proposer_name, 'A player');

  INSERT INTO public.player_notifications
    (player_id, kind, title, body, payload)
  VALUES (
    NEW.to_player_id,
    'trade_agreement_offered',
    v_proposer_name || ' offered a trade',
    v_proposer_name || ' proposed a recurring trade — open Trade → Players to accept or decline.',
    jsonb_build_object(
      'agreement_id', NEW.id,
      'from_player_id', NEW.from_player_id,
      'from_name', v_proposer_name,
      'give_resources', NEW.give_resources,
      'give_money', NEW.give_money,
      'receive_resources', NEW.receive_resources,
      'receive_money', NEW.receive_money,
      'interval_minutes', NEW.interval_minutes,
      'message', NEW.message
    )
  );

  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_notify_on_trade_agreement_proposed ON public.trade_agreements;
CREATE TRIGGER trg_notify_on_trade_agreement_proposed
  AFTER INSERT ON public.trade_agreements
  FOR EACH ROW
  EXECUTE FUNCTION public._on_trade_agreement_proposed();
