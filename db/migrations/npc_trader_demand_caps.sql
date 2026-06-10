-- ── NPC trader demand caps (2026-05-07) ──
-- Each trader-resource pair gains a daily cap on units bought from
-- players (`daily_buy_cap`). Once hit, that resource is full at that
-- trader until the next UTC day. Pushes players to diversify
-- production or compete for the same finite NPC demand.
--
-- The cap is GLOBAL (shared across all players) so multiplayer
-- pressure is real — first to sell wins, others find the trader
-- saturated.
--
-- Tracking lives in a new `trader_daily_quota` table keyed by
-- (trader_key, resource_key, day_bucket). Reads + writes happen
-- inside the visit-resolution phases.

ALTER TABLE public.trader_prices
  ADD COLUMN IF NOT EXISTS daily_buy_cap integer,
  ADD COLUMN IF NOT EXISTS daily_sell_cap integer;

-- Initial caps. Per-player produce rates roughly:
--   1 staffed extractor  = ~90 units/hour = ~2160 units/day
--   so a cap of 150-300 across each trader makes a single resource
--   limited to ~10-15% of one extractor's output via a single trader.
--   Stacking 3 traders, 850/day is the de-facto ceiling per resource.
UPDATE public.trader_prices SET daily_buy_cap = 300 WHERE buy_price IS NOT NULL;
-- Mountain folk has higher visit_capacity and slightly higher prices —
-- give it a slightly larger appetite.
UPDATE public.trader_prices SET daily_buy_cap = 400 WHERE trader_key = 'mountain_folk' AND buy_price IS NOT NULL;
-- Desert caravan trades premium processed goods at premium prices —
-- low-volume, high-margin.
UPDATE public.trader_prices SET daily_buy_cap = 100 WHERE trader_key = 'desert_caravan' AND buy_price IS NOT NULL;

-- Sell cap (for buy_to_reserve players) is more permissive — players
-- importing from NPCs are paying premium so don't punish them too.
UPDATE public.trader_prices SET daily_sell_cap = 200 WHERE sell_price IS NOT NULL;

CREATE TABLE IF NOT EXISTS public.trader_daily_quota (
  trader_key   text   NOT NULL REFERENCES public.traders(key) ON DELETE CASCADE,
  resource_key text   NOT NULL REFERENCES public.resources(key) ON DELETE CASCADE,
  day_bucket   date   NOT NULL,
  qty_bought   integer NOT NULL DEFAULT 0,
  qty_sold     integer NOT NULL DEFAULT 0,
  PRIMARY KEY (trader_key, resource_key, day_bucket)
);

ALTER TABLE public.trader_daily_quota ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS trader_daily_quota_read ON public.trader_daily_quota;
CREATE POLICY trader_daily_quota_read ON public.trader_daily_quota FOR SELECT USING (true);

GRANT SELECT ON public.trader_daily_quota TO anon, authenticated;

-- ── _rtv_sell_phase: check + increment buy quota ──
CREATE OR REPLACE FUNCTION public._rtv_sell_phase(p_uid uuid, p_trader_key text, p_capacity integer)
 RETURNS TABLE(capacity_used integer, earned integer, summary jsonb)
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  v_remaining integer := p_capacity;
  v_earned integer := 0;
  v_summary jsonb := '[]'::jsonb;
  v_policy record;
  v_buy_price integer;
  v_buy_cap integer;
  v_already_bought integer;
  v_quota_remaining integer;
  v_inventory numeric;
  v_surplus integer;
  v_sell_amt integer;
BEGIN
  FOR v_policy IN
    SELECT tp.resource_key, tp.reserve_target
    FROM public.trade_policies tp
    WHERE tp.player_id = p_uid AND tp.mode = 'sell_surplus'
  LOOP
    IF v_remaining <= 0 THEN EXIT; END IF;

    SELECT tp.buy_price, tp.daily_buy_cap INTO v_buy_price, v_buy_cap
    FROM public.trader_prices tp
    WHERE tp.trader_key = p_trader_key
      AND tp.resource_key = v_policy.resource_key
      AND tp.is_active;
    IF NOT FOUND OR v_buy_price IS NULL THEN CONTINUE; END IF;

    -- Daily-cap check. NULL cap = unlimited (legacy fallback).
    IF v_buy_cap IS NOT NULL THEN
      SELECT COALESCE(qty_bought, 0) INTO v_already_bought
      FROM public.trader_daily_quota
      WHERE trader_key = p_trader_key
        AND resource_key = v_policy.resource_key
        AND day_bucket = CURRENT_DATE;
      IF v_already_bought IS NULL THEN v_already_bought := 0; END IF;
      v_quota_remaining := v_buy_cap - v_already_bought;
      IF v_quota_remaining <= 0 THEN CONTINUE; END IF;
    ELSE
      v_quota_remaining := 2147483647;
    END IF;

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

    -- Increment the daily quota.
    INSERT INTO public.trader_daily_quota
      (trader_key, resource_key, day_bucket, qty_bought)
    VALUES
      (p_trader_key, v_policy.resource_key, CURRENT_DATE, v_sell_amt)
    ON CONFLICT (trader_key, resource_key, day_bucket)
    DO UPDATE SET qty_bought = public.trader_daily_quota.qty_bought + EXCLUDED.qty_bought;

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
$function$;

-- ── _rtv_buy_phase: check + increment sell quota ──
CREATE OR REPLACE FUNCTION public._rtv_buy_phase(p_uid uuid, p_trader_key text, p_capacity integer, p_money_in integer)
 RETURNS TABLE(capacity_used integer, spent integer, summary jsonb, money_out integer)
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  v_remaining integer := p_capacity;
  v_money integer := p_money_in;
  v_spent integer := 0;
  v_summary jsonb := '[]'::jsonb;
  v_policy record;
  v_sell_price integer;
  v_sell_cap integer;
  v_already_sold integer;
  v_quota_remaining integer;
  v_inventory numeric;
  v_needed integer;
  v_buy_amt integer;
BEGIN
  FOR v_policy IN
    SELECT tp.resource_key, tp.reserve_target
    FROM public.trade_policies tp
    WHERE tp.player_id = p_uid AND tp.mode = 'buy_to_reserve'
  LOOP
    IF v_remaining <= 0 THEN EXIT; END IF;

    SELECT tp.sell_price, tp.daily_sell_cap INTO v_sell_price, v_sell_cap
    FROM public.trader_prices tp
    WHERE tp.trader_key = p_trader_key
      AND tp.resource_key = v_policy.resource_key
      AND tp.is_active;
    IF NOT FOUND OR v_sell_price IS NULL THEN CONTINUE; END IF;

    -- Daily-cap check on the trader's sell side (player imports).
    IF v_sell_cap IS NOT NULL THEN
      SELECT COALESCE(qty_sold, 0) INTO v_already_sold
      FROM public.trader_daily_quota
      WHERE trader_key = p_trader_key
        AND resource_key = v_policy.resource_key
        AND day_bucket = CURRENT_DATE;
      IF v_already_sold IS NULL THEN v_already_sold := 0; END IF;
      v_quota_remaining := v_sell_cap - v_already_sold;
      IF v_quota_remaining <= 0 THEN CONTINUE; END IF;
    ELSE
      v_quota_remaining := 2147483647;
    END IF;

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
      (trader_key, resource_key, day_bucket, qty_sold)
    VALUES
      (p_trader_key, v_policy.resource_key, CURRENT_DATE, v_buy_amt)
    ON CONFLICT (trader_key, resource_key, day_bucket)
    DO UPDATE SET qty_sold = public.trader_daily_quota.qty_sold + EXCLUDED.qty_sold;

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
$function$;

-- ── RPC for the client to fetch today's quota state ──
-- Returns (trader_key, resource_key, buy_cap, sold, sell_cap, bought_by_players)
-- so the partner panel can render "X / Y sold today" indicators.
CREATE OR REPLACE FUNCTION public.get_trader_daily_quotas()
RETURNS TABLE(
  trader_key text,
  resource_key text,
  buy_cap integer,
  buy_used integer,
  sell_cap integer,
  sell_used integer
)
LANGUAGE sql
STABLE
AS $$
  SELECT
    tp.trader_key,
    tp.resource_key,
    tp.daily_buy_cap   AS buy_cap,
    COALESCE(q.qty_bought, 0) AS buy_used,
    tp.daily_sell_cap  AS sell_cap,
    COALESCE(q.qty_sold,   0) AS sell_used
  FROM public.trader_prices tp
  LEFT JOIN public.trader_daily_quota q
    ON q.trader_key = tp.trader_key
   AND q.resource_key = tp.resource_key
   AND q.day_bucket = CURRENT_DATE
  WHERE tp.is_active;
$$;

GRANT EXECUTE ON FUNCTION public.get_trader_daily_quotas() TO anon, authenticated;
