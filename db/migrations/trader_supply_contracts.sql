-- ─────────────────────────────────────────────────────────────────────
-- Trader supply contracts (2026-05-21)
--
-- Design: players pool money into per-(trader, resource, direction)
-- contracts. When a contract's pool hits its threshold, the trader's
-- city-wide cap for that resource permanently increases by +25% (with
-- a floor so a low cap doesn't stay stuck). Threshold scales with
-- (bumps_already_funded) and (city total population) so cooperation
-- stays load-bearing — a small early city can fund the first bump
-- alone, but a large mature city's next bump costs enough to require
-- pooling across players.
--
-- Forks settled with Atlas 2026-05-21:
--   - Money-only contributions (resource pledges deferred).
--   - Multiplicative +25% bump step, floor 100 cap.
--   - Public contributors (names visible).
--   - Refunds allowed any time before settle.
--   - Full slice: ledger entries, bell-log notification, tests,
--     balance defaults included.
--
-- One subtle: round_at uses clock_timestamp() not now() so the round
-- boundary advances even within a single transaction. Without that,
-- a settle inside a test savepoint can't be distinguished from the
-- next pledge by timestamp. Settled pledges are also explicitly
-- closed (refunded=true) on settle as defense-in-depth.
-- ─────────────────────────────────────────────────────────────────────


-- ── Tables ──────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS public.trader_supply_contracts (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  trader_key text NOT NULL,
  resource_key text NOT NULL,
  direction text NOT NULL CHECK (direction IN ('sell','buy')),
  pool_money integer NOT NULL DEFAULT 0 CHECK (pool_money >= 0),
  threshold_money integer NOT NULL,
  bumps_funded integer NOT NULL DEFAULT 0,
  current_round_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  last_settled_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (trader_key, resource_key, direction)
);

CREATE TABLE IF NOT EXISTS public.trader_supply_pledges (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  contract_id uuid NOT NULL REFERENCES public.trader_supply_contracts(id) ON DELETE CASCADE,
  player_id uuid NOT NULL REFERENCES public.player_profiles(id) ON DELETE CASCADE,
  round_at timestamptz NOT NULL,
  amount integer NOT NULL CHECK (amount > 0),
  refunded boolean NOT NULL DEFAULT false,
  refunded_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS trader_supply_pledges_active_idx
  ON public.trader_supply_pledges (contract_id, round_at, refunded);


-- ── RLS ─────────────────────────────────────────────────────────────

ALTER TABLE public.trader_supply_contracts ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS contracts_read ON public.trader_supply_contracts;
CREATE POLICY contracts_read ON public.trader_supply_contracts FOR SELECT USING (true);

ALTER TABLE public.trader_supply_pledges ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS pledges_read ON public.trader_supply_pledges;
CREATE POLICY pledges_read ON public.trader_supply_pledges FOR SELECT USING (true);

GRANT SELECT ON public.trader_supply_contracts TO anon, authenticated;
GRANT SELECT ON public.trader_supply_pledges TO anon, authenticated;


-- Cash ledger source allowlist extended.
ALTER TABLE public.cash_transactions DROP CONSTRAINT IF EXISTS cash_source_check;
ALTER TABLE public.cash_transactions ADD CONSTRAINT cash_source_check CHECK (
  source = ANY (ARRAY[
    'tax_revenue','build_cost','expansion_cost','starting_grant',
    'demolish_refund','upkeep','npc_trade','p2p_trade','p2p_agreement',
    'black_market','ledger_adjustment','supply_contract'
  ])
);


-- ── Helpers + RPCs (current live definitions) ──────────────────────


CREATE OR REPLACE FUNCTION public._supply_contract_threshold(p_bumps_funded integer)
 RETURNS integer
 LANGUAGE sql
 IMMUTABLE
AS $function$
  WITH pop AS (
    SELECT COALESCE(SUM(population), 0)::numeric AS total FROM public.player_profiles
  )
  SELECT GREATEST(
    1000,
    FLOOR(
      10000.0
      * POWER(1.0 + p_bumps_funded, 1.5)
      * GREATEST(1.0, (SELECT total FROM pop) / 200.0)
    )::integer
  );
$function$
;


CREATE OR REPLACE FUNCTION public._supply_contract_new_cap(p_old_cap integer)
 RETURNS integer
 LANGUAGE sql
 IMMUTABLE
AS $function$
  SELECT GREATEST(100, ROUND(COALESCE(p_old_cap, 0) * 1.25)::integer);
$function$
;


CREATE OR REPLACE FUNCTION public.list_supply_contracts()
 RETURNS TABLE(id uuid, trader_key text, resource_key text, direction text, pool_money integer, threshold_money integer, bumps_funded integer, current_cap integer, my_pledge integer, contributors json)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
AS $function$
DECLARE
  v_uid uuid := auth.uid();
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'auth required'; END IF;
  RETURN QUERY
    SELECT
      c.id, c.trader_key, c.resource_key, c.direction,
      c.pool_money, c.threshold_money, c.bumps_funded,
      CASE c.direction
        WHEN 'sell' THEN (SELECT tp.daily_sell_cap FROM public.trader_prices tp
                          WHERE tp.trader_key = c.trader_key AND tp.resource_key = c.resource_key AND tp.is_active
                          LIMIT 1)
        WHEN 'buy'  THEN (SELECT tp.daily_buy_cap  FROM public.trader_prices tp
                          WHERE tp.trader_key = c.trader_key AND tp.resource_key = c.resource_key AND tp.is_active
                          LIMIT 1)
      END AS current_cap,
      COALESCE((
        SELECT SUM(p.amount)::integer FROM public.trader_supply_pledges p
        WHERE p.contract_id = c.id AND p.round_at = c.current_round_at
          AND p.refunded = false AND p.player_id = v_uid
      ), 0) AS my_pledge,
      COALESCE((
        SELECT json_agg(json_build_object(
                 'player_id', sub.player_id,
                 'display_name', sub.display_name,
                 'amount', sub.amount
               ) ORDER BY sub.amount DESC)
        FROM (
          SELECT p.player_id, pp.display_name, SUM(p.amount)::integer AS amount
          FROM public.trader_supply_pledges p
          JOIN public.player_profiles pp ON pp.id = p.player_id
          WHERE p.contract_id = c.id
            AND p.round_at = c.current_round_at
            AND p.refunded = false
          GROUP BY p.player_id, pp.display_name
        ) sub
      ), '[]'::json) AS contributors
    FROM public.trader_supply_contracts c
    ORDER BY c.trader_key, c.resource_key, c.direction;
END;
$function$
;


CREATE OR REPLACE FUNCTION public.contribute_to_supply_contract(p_trader_key text, p_resource_key text, p_direction text, p_amount integer)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_contract record;
  v_player_money integer;
  v_new_cap integer;
  v_old_cap integer;
  v_pool_after integer;
  v_did_settle boolean := false;
  v_new_round_at timestamptz;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'auth required'; END IF;
  IF p_amount IS NULL OR p_amount <= 0 THEN RAISE EXCEPTION 'amount must be positive'; END IF;
  IF p_direction NOT IN ('sell','buy') THEN RAISE EXCEPTION 'direction must be sell or buy'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.resources WHERE key = p_resource_key) THEN
    RAISE EXCEPTION 'unknown resource %', p_resource_key;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.traders WHERE key = p_trader_key AND is_active) THEN
    RAISE EXCEPTION 'unknown trader %', p_trader_key;
  END IF;

  SELECT money INTO v_player_money FROM public.player_profiles WHERE id = v_uid FOR UPDATE;
  IF v_player_money < p_amount THEN
    RAISE EXCEPTION 'Not enough money (have %, need %)', v_player_money, p_amount;
  END IF;

  SELECT * INTO v_contract FROM public.trader_supply_contracts
    WHERE trader_key = p_trader_key AND resource_key = p_resource_key AND direction = p_direction
    FOR UPDATE;
  IF NOT FOUND THEN
    INSERT INTO public.trader_supply_contracts (
      trader_key, resource_key, direction, pool_money, threshold_money, bumps_funded, current_round_at
    ) VALUES (
      p_trader_key, p_resource_key, p_direction, 0, public._supply_contract_threshold(0), 0, clock_timestamp()
    ) RETURNING * INTO v_contract;
  END IF;

  UPDATE public.player_profiles SET money = money - p_amount WHERE id = v_uid;
  INSERT INTO public.cash_transactions (player_id, source, amount, context)
  VALUES (v_uid, 'supply_contract', -p_amount,
          jsonb_build_object('contract_id', v_contract.id, 'trader', p_trader_key,
                             'resource', p_resource_key, 'direction', p_direction, 'kind', 'pledge'));

  INSERT INTO public.trader_supply_pledges (contract_id, player_id, round_at, amount)
  VALUES (v_contract.id, v_uid, v_contract.current_round_at, p_amount);

  v_pool_after := v_contract.pool_money + p_amount;

  IF v_pool_after >= v_contract.threshold_money THEN
    v_did_settle := true;
    IF NOT EXISTS (
      SELECT 1 FROM public.trader_prices WHERE trader_key = p_trader_key AND resource_key = p_resource_key AND is_active
    ) THEN
      INSERT INTO public.trader_prices
        (trader_key, resource_key, buy_price, sell_price, daily_buy_cap, daily_sell_cap, is_active)
      SELECT p_trader_key, p_resource_key,
             GREATEST(1, FLOOR(r.base_price * 0.7)::integer),
             GREATEST(1, CEIL(r.base_price * 1.5)::integer),
             0, 0, true
      FROM public.resources r WHERE r.key = p_resource_key;
    END IF;

    IF p_direction = 'sell' THEN
      SELECT daily_sell_cap INTO v_old_cap FROM public.trader_prices
        WHERE trader_key = p_trader_key AND resource_key = p_resource_key AND is_active;
      v_new_cap := public._supply_contract_new_cap(v_old_cap);
      UPDATE public.trader_prices SET daily_sell_cap = v_new_cap
        WHERE trader_key = p_trader_key AND resource_key = p_resource_key AND is_active;
    ELSE
      SELECT daily_buy_cap INTO v_old_cap FROM public.trader_prices
        WHERE trader_key = p_trader_key AND resource_key = p_resource_key AND is_active;
      v_new_cap := public._supply_contract_new_cap(v_old_cap);
      UPDATE public.trader_prices SET daily_buy_cap = v_new_cap
        WHERE trader_key = p_trader_key AND resource_key = p_resource_key AND is_active;
    END IF;

    -- Defense-in-depth: close out this round's pledges so a subsequent
    -- withdraw can't match them even if the clock_timestamp() values
    -- somehow collide (e.g. same-microsecond test environments).
    UPDATE public.trader_supply_pledges
       SET refunded = true, refunded_at = clock_timestamp()
     WHERE contract_id = v_contract.id
       AND round_at = v_contract.current_round_at
       AND refunded = false;

    v_new_round_at := clock_timestamp();
    UPDATE public.trader_supply_contracts
    SET pool_money = 0, bumps_funded = bumps_funded + 1,
        threshold_money = public._supply_contract_threshold(bumps_funded + 1),
        current_round_at = v_new_round_at, last_settled_at = clock_timestamp(), updated_at = clock_timestamp()
    WHERE id = v_contract.id;

    INSERT INTO public.player_notifications (player_id, kind, title, payload)
    SELECT DISTINCT p.player_id, 'supply_contract_bumped',
                    'Supply contract funded',
                    jsonb_build_object(
                      'trader_key', p_trader_key, 'resource_key', p_resource_key,
                      'direction', p_direction, 'old_cap', v_old_cap, 'new_cap', v_new_cap,
                      'bumps_funded', v_contract.bumps_funded + 1
                    )
    FROM public.trader_supply_pledges p WHERE p.contract_id = v_contract.id;
  ELSE
    UPDATE public.trader_supply_contracts SET pool_money = v_pool_after, updated_at = clock_timestamp()
      WHERE id = v_contract.id;
  END IF;

  RETURN json_build_object(
    'contract_id', v_contract.id,
    'pool_money', CASE WHEN v_did_settle THEN 0 ELSE v_pool_after END,
    'threshold_money', CASE WHEN v_did_settle THEN public._supply_contract_threshold(v_contract.bumps_funded + 1) ELSE v_contract.threshold_money END,
    'settled', v_did_settle, 'old_cap', v_old_cap, 'new_cap', v_new_cap,
    'money', v_player_money - p_amount
  );
END;
$function$
;


CREATE OR REPLACE FUNCTION public.withdraw_from_supply_contract(p_contract_id uuid)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_contract record;
  v_refund integer;
  v_new_money integer;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'auth required'; END IF;

  SELECT * INTO v_contract FROM public.trader_supply_contracts
    WHERE id = p_contract_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Contract not found'; END IF;

  -- Sum the caller's active pledges in the current round.
  SELECT COALESCE(SUM(amount), 0)::integer INTO v_refund
  FROM public.trader_supply_pledges
  WHERE contract_id = p_contract_id
    AND player_id = v_uid
    AND round_at = v_contract.current_round_at
    AND refunded = false;

  IF v_refund <= 0 THEN
    RAISE EXCEPTION 'No active pledges to withdraw';
  END IF;

  -- Mark pledges refunded.
  UPDATE public.trader_supply_pledges
  SET refunded = true, refunded_at = now()
  WHERE contract_id = p_contract_id
    AND player_id = v_uid
    AND round_at = v_contract.current_round_at
    AND refunded = false;

  -- Drop the pool counter.
  UPDATE public.trader_supply_contracts
  SET pool_money = pool_money - v_refund, updated_at = now()
  WHERE id = p_contract_id;

  -- Credit the player + ledger row.
  UPDATE public.player_profiles SET money = money + v_refund
  WHERE id = v_uid RETURNING money INTO v_new_money;

  INSERT INTO public.cash_transactions (player_id, source, amount, context)
  VALUES (v_uid, 'supply_contract', v_refund,
          jsonb_build_object('contract_id', p_contract_id,
                             'trader', v_contract.trader_key,
                             'resource', v_contract.resource_key,
                             'direction', v_contract.direction,
                             'kind', 'refund'));

  RETURN json_build_object(
    'contract_id', p_contract_id,
    'refunded', v_refund,
    'money', v_new_money
  );
END;
$function$
;


GRANT EXECUTE ON FUNCTION public.list_supply_contracts() TO authenticated;
GRANT EXECUTE ON FUNCTION public.contribute_to_supply_contract(text, text, text, integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.withdraw_from_supply_contract(uuid) TO authenticated;
