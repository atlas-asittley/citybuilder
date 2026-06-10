-- ─────────────────────────────────────────────────────────────────────
-- Trade policy mode: rename 'keep' → 'hold' (2026-05-21).
--
-- Atlas: "for trades with NPC's, you can't hold. it fails if you
-- choose hold."
--
-- The FE has been sending mode='hold' to save_trade_policy
-- (CityResourcesTab + TradePartnersTab both use that string in the
-- dropdown). The server's CHECK constraint + the IF in
-- save_trade_policy allowed only 'keep' | 'sell_surplus' |
-- 'buy_to_reserve'. So any "Hold" selection failed with
-- "Invalid trade mode: hold".
--
-- 'hold' is the player-facing word; bringing the server to match.
-- ─────────────────────────────────────────────────────────────────────

UPDATE public.trade_policies SET mode = 'hold' WHERE mode = 'keep';

ALTER TABLE public.trade_policies DROP CONSTRAINT IF EXISTS trade_policies_mode_check;
ALTER TABLE public.trade_policies ADD CONSTRAINT trade_policies_mode_check
  CHECK (mode IN ('hold', 'sell_surplus', 'buy_to_reserve'));

CREATE OR REPLACE FUNCTION public.save_trade_policy(
  p_resource_key text, p_mode text, p_reserve_target integer,
  p_min_sell_price integer DEFAULT NULL::integer,
  p_max_buy_price integer DEFAULT NULL::integer
)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
DECLARE
  v_uid uuid := auth.uid();
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'auth required'; END IF;
  IF p_mode NOT IN ('hold', 'sell_surplus', 'buy_to_reserve') THEN
    RAISE EXCEPTION 'Invalid trade mode: %', p_mode;
  END IF;
  IF p_reserve_target < 0 THEN
    RAISE EXCEPTION 'Reserve target cannot be negative';
  END IF;
  IF p_min_sell_price IS NOT NULL AND p_min_sell_price < 0 THEN
    RAISE EXCEPTION 'min_sell_price cannot be negative';
  END IF;
  IF p_max_buy_price IS NOT NULL AND p_max_buy_price < 0 THEN
    RAISE EXCEPTION 'max_buy_price cannot be negative';
  END IF;

  INSERT INTO public.trade_policies
    (player_id, resource_key, mode, reserve_target, min_sell_price, max_buy_price)
  VALUES
    (v_uid, p_resource_key, p_mode, p_reserve_target, p_min_sell_price, p_max_buy_price)
  ON CONFLICT (player_id, resource_key)
  DO UPDATE SET mode = p_mode,
                reserve_target = p_reserve_target,
                min_sell_price = p_min_sell_price,
                max_buy_price = p_max_buy_price,
                updated_at = now();

  RETURN json_build_object('ok', true, 'resource_key', p_resource_key,
                           'mode', p_mode, 'reserve_target', p_reserve_target,
                           'min_sell_price', p_min_sell_price,
                           'max_buy_price', p_max_buy_price);
END;
$function$;
