-- ─────────────────────────────────────────────────────────────────────
-- Per-player daily trade quotas (2026-05-08).
--
-- Atlas: "let's make it per player, not city wide. that gets too
-- complex for the user."
--
-- Until now, daily_buy_cap / daily_sell_cap on trader_prices were
-- decorative — _rtv_sell_phase / _rtv_buy_phase ignored them. The
-- existing trader_daily_quota table had PK (trader_key, resource_key,
-- day_bucket) which would have been city-wide if it were ever
-- written. Switching to per-player: add player_id, change PK, RLS so
-- each player only sees their own quotas.
--
-- Day boundary = UTC date. CURRENT_DATE in the player's session.
-- ─────────────────────────────────────────────────────────────────────

-- (1) Wipe any pre-existing rows (none of them were ever written by
-- live code, but be defensive). Then alter schema.
DELETE FROM public.trader_daily_quota;

ALTER TABLE public.trader_daily_quota
  DROP CONSTRAINT IF EXISTS trader_daily_quota_pkey;

ALTER TABLE public.trader_daily_quota
  ADD COLUMN IF NOT EXISTS player_id uuid;

ALTER TABLE public.trader_daily_quota
  ALTER COLUMN player_id SET NOT NULL;

ALTER TABLE public.trader_daily_quota
  DROP CONSTRAINT IF EXISTS trader_daily_quota_player_id_fkey;
ALTER TABLE public.trader_daily_quota
  ADD CONSTRAINT trader_daily_quota_player_id_fkey
  FOREIGN KEY (player_id) REFERENCES public.player_profiles(id) ON DELETE CASCADE;

ALTER TABLE public.trader_daily_quota
  ADD CONSTRAINT trader_daily_quota_pkey
  PRIMARY KEY (player_id, trader_key, resource_key, day_bucket);

-- RLS: players see only their own quotas.
ALTER TABLE public.trader_daily_quota ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS trader_daily_quota_read ON public.trader_daily_quota;
CREATE POLICY trader_daily_quota_read ON public.trader_daily_quota
  FOR SELECT USING (player_id = auth.uid());


-- (2) get_trader_daily_quotas() — filter by caller.
CREATE OR REPLACE FUNCTION public.get_trader_daily_quotas()
RETURNS TABLE(trader_key text, resource_key text, buy_cap integer, buy_used integer, sell_cap integer, sell_used integer)
LANGUAGE sql
STABLE SECURITY DEFINER
AS $function$
  WITH catalog AS (
    -- Mirror _trader_catalog logic: city rows win, fall back to global.
    SELECT cat.trader_key, cat.resource_key, cat.buy_price, cat.sell_price,
           cat.daily_buy_cap, cat.daily_sell_cap
    FROM (
      SELECT DISTINCT ON (tp.trader_key, tp.resource_key)
             tp.trader_key, tp.resource_key, tp.buy_price, tp.sell_price,
             tp.daily_buy_cap, tp.daily_sell_cap
      FROM public.trader_prices tp
      LEFT JOIN public.player_profiles me ON me.id = auth.uid()
      WHERE tp.is_active
        AND (tp.city_id = me.city_id OR tp.city_id IS NULL)
      ORDER BY tp.trader_key, tp.resource_key, tp.city_id NULLS LAST
    ) cat
  )
  SELECT
    catalog.trader_key,
    catalog.resource_key,
    catalog.daily_buy_cap   AS buy_cap,
    COALESCE(q.qty_bought, 0) AS buy_used,
    catalog.daily_sell_cap  AS sell_cap,
    COALESCE(q.qty_sold,   0) AS sell_used
  FROM catalog
  LEFT JOIN public.trader_daily_quota q
    ON q.trader_key = catalog.trader_key
   AND q.resource_key = catalog.resource_key
   AND q.day_bucket = CURRENT_DATE
   AND q.player_id = auth.uid();
$function$;


-- (3) _rtv_sell_phase — enforce daily_buy_cap on the trader's side
-- (which limits the player's sells). Reads remaining quota,
-- truncates the sell amount, writes back.
CREATE OR REPLACE FUNCTION public._rtv_sell_phase(
  p_uid uuid,
  p_trader_key text,
  p_capacity integer
)
RETURNS TABLE(capacity_used integer, earned integer, summary jsonb)
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_city_id uuid;
  v_remaining integer := p_capacity;
  v_earned integer := 0;
  v_summary jsonb := '[]'::jsonb;
  v_policy record;
  v_buy_price integer;
  v_buy_cap integer;
  v_inventory numeric;
  v_quota_used integer;
  v_quota_remaining integer;
  v_surplus integer;
  v_sell_amt integer;
  v_today date := CURRENT_DATE;
BEGIN
  SELECT city_id INTO v_city_id FROM public.player_profiles WHERE id = p_uid;

  FOR v_policy IN
    SELECT tp.resource_key, tp.reserve_target
    FROM public.trade_policies tp
    WHERE tp.player_id = p_uid AND tp.mode = 'sell_surplus'
  LOOP
    IF v_remaining <= 0 THEN EXIT; END IF;

    SELECT cat.buy_price, cat.daily_buy_cap INTO v_buy_price, v_buy_cap
    FROM public._trader_catalog(v_city_id, p_trader_key) cat
    WHERE cat.resource_key = v_policy.resource_key;
    IF NOT FOUND OR v_buy_price IS NULL THEN CONTINUE; END IF;

    -- Per-player quota check.
    SELECT COALESCE(qty_bought, 0) INTO v_quota_used
    FROM public.trader_daily_quota
    WHERE player_id = p_uid AND trader_key = p_trader_key
      AND resource_key = v_policy.resource_key AND day_bucket = v_today;
    v_quota_remaining := GREATEST(0, COALESCE(v_buy_cap, 0) - COALESCE(v_quota_used, 0));
    IF v_quota_remaining <= 0 THEN CONTINUE; END IF;

    SELECT COALESCE(quantity, 0) INTO v_inventory
    FROM public.inventories
    WHERE player_id = p_uid AND resource_key = v_policy.resource_key;
    IF v_inventory IS NULL THEN v_inventory := 0; END IF;

    v_surplus := GREATEST(0, FLOOR(v_inventory) - v_policy.reserve_target);
    IF v_surplus <= 0 THEN CONTINUE; END IF;
    v_sell_amt := LEAST(v_surplus, v_remaining, v_quota_remaining);
    IF v_sell_amt <= 0 THEN CONTINUE; END IF;

    UPDATE public.inventories
      SET quantity = quantity - v_sell_amt, updated_at = now()
      WHERE player_id = p_uid AND resource_key = v_policy.resource_key;

    -- Increment the quota row (insert or update).
    INSERT INTO public.trader_daily_quota
      (player_id, trader_key, resource_key, day_bucket, qty_bought, qty_sold)
    VALUES (p_uid, p_trader_key, v_policy.resource_key, v_today, v_sell_amt, 0)
    ON CONFLICT (player_id, trader_key, resource_key, day_bucket)
    DO UPDATE SET qty_bought = public.trader_daily_quota.qty_bought + v_sell_amt;

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


-- (4) _rtv_buy_phase — same shape, daily_sell_cap on trader's side
-- (which limits the player's buys), increments qty_sold.
CREATE OR REPLACE FUNCTION public._rtv_buy_phase(
  p_uid uuid,
  p_trader_key text,
  p_capacity integer,
  p_money_in integer
)
RETURNS TABLE(capacity_used integer, spent integer, summary jsonb, money_out integer)
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_city_id uuid;
  v_remaining integer := p_capacity;
  v_money integer := p_money_in;
  v_spent integer := 0;
  v_summary jsonb := '[]'::jsonb;
  v_policy record;
  v_sell_price integer;
  v_sell_cap integer;
  v_quota_used integer;
  v_quota_remaining integer;
  v_inventory numeric;
  v_needed integer;
  v_buy_amt integer;
  v_today date := CURRENT_DATE;
BEGIN
  SELECT city_id INTO v_city_id FROM public.player_profiles WHERE id = p_uid;

  FOR v_policy IN
    SELECT tp.resource_key, tp.reserve_target
    FROM public.trade_policies tp
    WHERE tp.player_id = p_uid AND tp.mode = 'buy_to_reserve'
  LOOP
    IF v_remaining <= 0 THEN EXIT; END IF;

    SELECT cat.sell_price, cat.daily_sell_cap INTO v_sell_price, v_sell_cap
    FROM public._trader_catalog(v_city_id, p_trader_key) cat
    WHERE cat.resource_key = v_policy.resource_key;
    IF NOT FOUND OR v_sell_price IS NULL THEN CONTINUE; END IF;

    SELECT COALESCE(qty_sold, 0) INTO v_quota_used
    FROM public.trader_daily_quota
    WHERE player_id = p_uid AND trader_key = p_trader_key
      AND resource_key = v_policy.resource_key AND day_bucket = v_today;
    v_quota_remaining := GREATEST(0, COALESCE(v_sell_cap, 0) - COALESCE(v_quota_used, 0));
    IF v_quota_remaining <= 0 THEN CONTINUE; END IF;

    SELECT COALESCE(quantity, 0) INTO v_inventory
    FROM public.inventories
    WHERE player_id = p_uid AND resource_key = v_policy.resource_key;
    IF v_inventory IS NULL THEN v_inventory := 0; END IF;

    v_needed := GREATEST(0, v_policy.reserve_target - FLOOR(v_inventory));
    IF v_needed <= 0 THEN CONTINUE; END IF;
    v_buy_amt := LEAST(v_needed, v_remaining, v_quota_remaining);
    IF v_sell_price > 0 THEN
      v_buy_amt := LEAST(v_buy_amt, FLOOR(v_money / v_sell_price));
    END IF;
    IF v_buy_amt <= 0 THEN CONTINUE; END IF;

    INSERT INTO public.inventories (player_id, resource_key, quantity)
    VALUES (p_uid, v_policy.resource_key, v_buy_amt)
    ON CONFLICT (player_id, resource_key)
    DO UPDATE SET quantity = public.inventories.quantity + v_buy_amt, updated_at = now();

    INSERT INTO public.trader_daily_quota
      (player_id, trader_key, resource_key, day_bucket, qty_bought, qty_sold)
    VALUES (p_uid, p_trader_key, v_policy.resource_key, v_today, 0, v_buy_amt)
    ON CONFLICT (player_id, trader_key, resource_key, day_bucket)
    DO UPDATE SET qty_sold = public.trader_daily_quota.qty_sold + v_buy_amt;

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
