-- ====================================================================
-- Recurring trade agreements between players
-- ====================================================================
-- Existing player_trade_offers is one-shot. Agreements add recurring
-- trades that fire every N minutes as long as both sides can pay.
-- Fires at most once per resolver call (bounded backlog).
--
-- Lifecycle: pending (proposed, awaiting counterparty) → active
-- (live, fires on interval) → cancelled (either party stopped it).
--
-- Schedule drift behavior: a successful firing advances last_fired_at
-- by exactly interval_minutes. A skipped firing (insufficient stock /
-- money on either side) does NOT advance, so the agreement retries
-- next tick. Cap at 1 firing per resolver call prevents 8-hours-offline
-- catch-up from depleting an inventory all at once.

CREATE TABLE IF NOT EXISTS public.trade_agreements (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  from_player_id UUID NOT NULL REFERENCES public.player_profiles(id) ON DELETE CASCADE,
  to_player_id UUID NOT NULL REFERENCES public.player_profiles(id) ON DELETE CASCADE,
  give_resources JSONB NOT NULL DEFAULT '{}'::jsonb,
  give_money INTEGER NOT NULL DEFAULT 0 CHECK (give_money >= 0),
  receive_resources JSONB NOT NULL DEFAULT '{}'::jsonb,
  receive_money INTEGER NOT NULL DEFAULT 0 CHECK (receive_money >= 0),
  interval_minutes INTEGER NOT NULL CHECK (interval_minutes BETWEEN 5 AND 1440),
  last_fired_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  status TEXT NOT NULL DEFAULT 'pending'
    CHECK (status IN ('pending', 'active', 'cancelled')),
  message TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CHECK (from_player_id <> to_player_id)
);

CREATE INDEX IF NOT EXISTS idx_trade_agreements_from_status
  ON public.trade_agreements (from_player_id, status, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_trade_agreements_to_status
  ON public.trade_agreements (to_player_id, status, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_trade_agreements_active_due
  ON public.trade_agreements (last_fired_at)
  WHERE status = 'active';

ALTER TABLE public.trade_agreements ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "trade_agreements_select" ON public.trade_agreements;
CREATE POLICY "trade_agreements_select"
  ON public.trade_agreements FOR SELECT
  USING (auth.uid() = from_player_id OR auth.uid() = to_player_id);

DROP POLICY IF EXISTS "trade_agreements_insert" ON public.trade_agreements;
CREATE POLICY "trade_agreements_insert"
  ON public.trade_agreements FOR INSERT
  WITH CHECK (auth.uid() = from_player_id);

DROP POLICY IF EXISTS "trade_agreements_update" ON public.trade_agreements;
CREATE POLICY "trade_agreements_update"
  ON public.trade_agreements FOR UPDATE
  USING (auth.uid() = from_player_id OR auth.uid() = to_player_id);


-- ──────────────────────────────────────────────────────────────────
-- propose_trade_agreement
-- ──────────────────────────────────────────────────────────────────
-- Caller proposes an agreement to another player. Creates a 'pending'
-- row. Validates resource keys exist + quantities positive.

CREATE OR REPLACE FUNCTION public.propose_trade_agreement(
  p_to_player_id UUID,
  p_give_resources JSONB,
  p_give_money INTEGER,
  p_receive_resources JSONB,
  p_receive_money INTEGER,
  p_interval_minutes INTEGER,
  p_message TEXT DEFAULT NULL
)
RETURNS public.trade_agreements
LANGUAGE plpgsql SECURITY DEFINER
AS $$
DECLARE
  v_uid UUID := auth.uid();
  v_row public.trade_agreements;
  v_key TEXT;
  v_qty INTEGER;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'auth required'; END IF;
  IF p_to_player_id = v_uid THEN RAISE EXCEPTION 'cannot trade with yourself'; END IF;
  IF NOT EXISTS (SELECT 1 FROM player_profiles WHERE id = p_to_player_id) THEN
    RAISE EXCEPTION 'counterparty does not exist';
  END IF;
  IF p_interval_minutes < 5 OR p_interval_minutes > 1440 THEN
    RAISE EXCEPTION 'interval must be between 5 and 1440 minutes';
  END IF;
  IF (COALESCE(p_give_resources, '{}'::jsonb) = '{}'::jsonb AND COALESCE(p_give_money, 0) = 0)
     OR (COALESCE(p_receive_resources, '{}'::jsonb) = '{}'::jsonb AND COALESCE(p_receive_money, 0) = 0) THEN
    RAISE EXCEPTION 'both sides must offer something';
  END IF;

  -- Validate every resource key exists and quantity is positive.
  FOR v_key, v_qty IN SELECT * FROM jsonb_each_text(COALESCE(p_give_resources, '{}'::jsonb)) LOOP
    IF NOT EXISTS (SELECT 1 FROM resources WHERE key = v_key) THEN
      RAISE EXCEPTION 'unknown resource: %', v_key;
    END IF;
    IF v_qty::INTEGER <= 0 THEN RAISE EXCEPTION 'quantity must be positive: %', v_key; END IF;
  END LOOP;
  FOR v_key, v_qty IN SELECT * FROM jsonb_each_text(COALESCE(p_receive_resources, '{}'::jsonb)) LOOP
    IF NOT EXISTS (SELECT 1 FROM resources WHERE key = v_key) THEN
      RAISE EXCEPTION 'unknown resource: %', v_key;
    END IF;
    IF v_qty::INTEGER <= 0 THEN RAISE EXCEPTION 'quantity must be positive: %', v_key; END IF;
  END LOOP;

  INSERT INTO public.trade_agreements (
    from_player_id, to_player_id,
    give_resources, give_money,
    receive_resources, receive_money,
    interval_minutes, message,
    status, last_fired_at
  ) VALUES (
    v_uid, p_to_player_id,
    COALESCE(p_give_resources, '{}'::jsonb), COALESCE(p_give_money, 0),
    COALESCE(p_receive_resources, '{}'::jsonb), COALESCE(p_receive_money, 0),
    p_interval_minutes, p_message,
    'pending', now()
  ) RETURNING * INTO v_row;

  RETURN v_row;
END;
$$;

GRANT EXECUTE ON FUNCTION public.propose_trade_agreement(UUID, JSONB, INTEGER, JSONB, INTEGER, INTEGER, TEXT) TO authenticated;


-- ──────────────────────────────────────────────────────────────────
-- accept_trade_agreement
-- ──────────────────────────────────────────────────────────────────
-- Counterparty accepts a pending agreement. Sets status = 'active'
-- and last_fired_at = now() so the first firing happens after the
-- full interval. Only the to_player_id (recipient of the proposal)
-- can accept.

CREATE OR REPLACE FUNCTION public.accept_trade_agreement(p_agreement_id UUID)
RETURNS public.trade_agreements
LANGUAGE plpgsql SECURITY DEFINER
AS $$
DECLARE
  v_uid UUID := auth.uid();
  v_row public.trade_agreements;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'auth required'; END IF;

  SELECT * INTO v_row FROM public.trade_agreements
   WHERE id = p_agreement_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'agreement not found'; END IF;
  IF v_row.to_player_id <> v_uid THEN RAISE EXCEPTION 'only the counterparty can accept'; END IF;
  IF v_row.status <> 'pending' THEN RAISE EXCEPTION 'agreement is not pending'; END IF;

  UPDATE public.trade_agreements
     SET status = 'active', last_fired_at = now()
   WHERE id = p_agreement_id
   RETURNING * INTO v_row;

  RETURN v_row;
END;
$$;

GRANT EXECUTE ON FUNCTION public.accept_trade_agreement(UUID) TO authenticated;


-- ──────────────────────────────────────────────────────────────────
-- cancel_trade_agreement
-- ──────────────────────────────────────────────────────────────────
-- Either party can cancel at any status (pending or active).

CREATE OR REPLACE FUNCTION public.cancel_trade_agreement(p_agreement_id UUID)
RETURNS public.trade_agreements
LANGUAGE plpgsql SECURITY DEFINER
AS $$
DECLARE
  v_uid UUID := auth.uid();
  v_row public.trade_agreements;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'auth required'; END IF;

  SELECT * INTO v_row FROM public.trade_agreements
   WHERE id = p_agreement_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'agreement not found'; END IF;
  IF v_row.from_player_id <> v_uid AND v_row.to_player_id <> v_uid THEN
    RAISE EXCEPTION 'not a party to this agreement';
  END IF;
  IF v_row.status = 'cancelled' THEN RETURN v_row; END IF;

  UPDATE public.trade_agreements
     SET status = 'cancelled'
   WHERE id = p_agreement_id
   RETURNING * INTO v_row;

  RETURN v_row;
END;
$$;

GRANT EXECUTE ON FUNCTION public.cancel_trade_agreement(UUID) TO authenticated;


-- ──────────────────────────────────────────────────────────────────
-- list_trade_agreements
-- ──────────────────────────────────────────────────────────────────
-- Returns every agreement the caller is a party to, with the
-- counterparty's display_name + color_hex pre-joined for the UI.

CREATE OR REPLACE FUNCTION public.list_trade_agreements()
RETURNS TABLE (
  id UUID,
  role TEXT,
  counterparty_id UUID,
  counterparty_name TEXT,
  counterparty_color TEXT,
  give_resources JSONB,
  give_money INTEGER,
  receive_resources JSONB,
  receive_money INTEGER,
  interval_minutes INTEGER,
  last_fired_at TIMESTAMPTZ,
  status TEXT,
  message TEXT,
  created_at TIMESTAMPTZ
)
LANGUAGE plpgsql SECURITY DEFINER
AS $$
DECLARE
  v_uid UUID := auth.uid();
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'auth required'; END IF;

  RETURN QUERY
  SELECT
    ta.id,
    CASE WHEN ta.from_player_id = v_uid THEN 'proposer' ELSE 'recipient' END AS role,
    CASE WHEN ta.from_player_id = v_uid THEN ta.to_player_id ELSE ta.from_player_id END AS counterparty_id,
    p.display_name AS counterparty_name,
    p.color_hex AS counterparty_color,
    ta.give_resources, ta.give_money,
    ta.receive_resources, ta.receive_money,
    ta.interval_minutes, ta.last_fired_at,
    ta.status, ta.message, ta.created_at
  FROM public.trade_agreements ta
  JOIN public.player_profiles p
    ON p.id = (CASE WHEN ta.from_player_id = v_uid THEN ta.to_player_id ELSE ta.from_player_id END)
  WHERE ta.from_player_id = v_uid OR ta.to_player_id = v_uid
  ORDER BY
    CASE ta.status WHEN 'pending' THEN 0 WHEN 'active' THEN 1 ELSE 2 END,
    ta.created_at DESC;
END;
$$;

GRANT EXECUTE ON FUNCTION public.list_trade_agreements() TO authenticated;


-- ──────────────────────────────────────────────────────────────────
-- _pp_run_agreements
-- ──────────────────────────────────────────────────────────────────
-- Resolver phase. Called from process_production for the current
-- player. Fires at most ONE agreement per call (bounded backlog).
-- Locks the chosen agreement row + both inventories with FOR UPDATE
-- to keep concurrent ticks from double-firing.
--
-- Each agreement is driven only when the from_player ticks (the
-- proposer side). Keeps the resolver single-driver — no double-fire
-- risk if both sides happen to tick concurrently.

CREATE OR REPLACE FUNCTION public._pp_run_agreements(p_uid UUID)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
AS $$
DECLARE
  v_agr public.trade_agreements;
  v_key TEXT;
  v_qty NUMERIC;
  v_can_fire BOOLEAN;
  v_from_money INTEGER;
  v_to_money INTEGER;
BEGIN
  -- Pick the single oldest-due active agreement where p_uid is the
  -- proposer. SKIP LOCKED so a parallel tick on the same player
  -- doesn't block — at worst a firing waits for the next tick.
  SELECT * INTO v_agr
    FROM public.trade_agreements
   WHERE status = 'active'
     AND from_player_id = p_uid
     AND last_fired_at + (interval_minutes || ' minutes')::interval <= now()
   ORDER BY last_fired_at ASC
   LIMIT 1
   FOR UPDATE SKIP LOCKED;
  IF NOT FOUND THEN RETURN; END IF;

  -- Verify both sides can pay the agreement's terms.
  v_can_fire := TRUE;

  -- from_player's resources cover give_resources?
  FOR v_key, v_qty IN SELECT k, val::numeric FROM jsonb_each_text(v_agr.give_resources) AS j(k, val) LOOP
    IF (SELECT COALESCE(quantity, 0) FROM public.inventories
         WHERE player_id = v_agr.from_player_id AND resource_key = v_key) < v_qty THEN
      v_can_fire := FALSE; EXIT;
    END IF;
  END LOOP;

  -- to_player's resources cover receive_resources?
  IF v_can_fire THEN
    FOR v_key, v_qty IN SELECT k, val::numeric FROM jsonb_each_text(v_agr.receive_resources) AS j(k, val) LOOP
      IF (SELECT COALESCE(quantity, 0) FROM public.inventories
           WHERE player_id = v_agr.to_player_id AND resource_key = v_key) < v_qty THEN
        v_can_fire := FALSE; EXIT;
      END IF;
    END LOOP;
  END IF;

  -- Money checks.
  IF v_can_fire AND v_agr.give_money > 0 THEN
    SELECT money INTO v_from_money FROM public.player_profiles WHERE id = v_agr.from_player_id;
    IF v_from_money < v_agr.give_money THEN v_can_fire := FALSE; END IF;
  END IF;
  IF v_can_fire AND v_agr.receive_money > 0 THEN
    SELECT money INTO v_to_money FROM public.player_profiles WHERE id = v_agr.to_player_id;
    IF v_to_money < v_agr.receive_money THEN v_can_fire := FALSE; END IF;
  END IF;

  IF NOT v_can_fire THEN
    -- Skipped firing — leave last_fired_at alone so we retry next
    -- tick. Caller's choice; we don't bump the schedule on misses.
    RETURN;
  END IF;

  -- Apply give_resources: from → to
  FOR v_key, v_qty IN SELECT k, val::numeric FROM jsonb_each_text(v_agr.give_resources) AS j(k, val) LOOP
    UPDATE public.inventories SET quantity = quantity - v_qty
      WHERE player_id = v_agr.from_player_id AND resource_key = v_key;
    INSERT INTO public.inventories (player_id, resource_key, quantity)
      VALUES (v_agr.to_player_id, v_key, v_qty)
      ON CONFLICT (player_id, resource_key)
      DO UPDATE SET quantity = inventories.quantity + EXCLUDED.quantity;
  END LOOP;

  -- Apply receive_resources: to → from
  FOR v_key, v_qty IN SELECT k, val::numeric FROM jsonb_each_text(v_agr.receive_resources) AS j(k, val) LOOP
    UPDATE public.inventories SET quantity = quantity - v_qty
      WHERE player_id = v_agr.to_player_id AND resource_key = v_key;
    INSERT INTO public.inventories (player_id, resource_key, quantity)
      VALUES (v_agr.from_player_id, v_key, v_qty)
      ON CONFLICT (player_id, resource_key)
      DO UPDATE SET quantity = inventories.quantity + EXCLUDED.quantity;
  END LOOP;

  -- Apply money flows.
  IF v_agr.give_money > 0 THEN
    UPDATE public.player_profiles SET money = money - v_agr.give_money WHERE id = v_agr.from_player_id;
    UPDATE public.player_profiles SET money = money + v_agr.give_money WHERE id = v_agr.to_player_id;
  END IF;
  IF v_agr.receive_money > 0 THEN
    UPDATE public.player_profiles SET money = money - v_agr.receive_money WHERE id = v_agr.to_player_id;
    UPDATE public.player_profiles SET money = money + v_agr.receive_money WHERE id = v_agr.from_player_id;
  END IF;

  -- Advance schedule by exactly interval_minutes.
  UPDATE public.trade_agreements
     SET last_fired_at = last_fired_at + (interval_minutes || ' minutes')::interval
   WHERE id = v_agr.id;
END;
$$;

GRANT EXECUTE ON FUNCTION public._pp_run_agreements(UUID) TO authenticated;
-- Wire _pp_run_agreements into process_production after the processor
-- phase. Inventory-only side effect; safe to run at any post-production
-- point. Placed before services so a freshly-traded resource can feed
-- a service the same tick.

CREATE OR REPLACE FUNCTION public.process_production()
RETURNS json
LANGUAGE plpgsql SECURITY DEFINER
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_base constant integer := 5;
  v_tavern_bonus integer;
  v_supply integer;
  v_staffing record;
  v_total_produced numeric := 0;
  v_total_money integer := 0;
  v_total_upkeep integer := 0;
  v_food_drained numeric := 0;
  v_evolution_events json[];
  v_operating_services uuid[];
  v_partial numeric;
  v_population numeric;
  v_crime numeric;
BEGIN
  v_tavern_bonus := public._pp_tavern_bonus(v_uid);

  v_population := public._pp_update_population(v_uid);
  v_supply := FLOOR(v_population)::integer + v_tavern_bonus;

  SELECT staffed_ids, workers_needed, unstaffed_count
    INTO v_staffing
    FROM public._pp_staff_buildings(v_uid, v_supply);

  v_partial := public._pp_run_extractors(v_uid, v_staffing.staffed_ids);
  v_total_produced := v_total_produced + v_partial;
  v_partial := public._pp_run_food_extractors(v_uid, v_staffing.staffed_ids);
  v_total_produced := v_total_produced + v_partial;
  PERFORM public._pp_bump_boosters(v_uid, v_staffing.staffed_ids);
  v_partial := public._pp_run_processors(v_uid, v_staffing.staffed_ids);
  v_total_produced := v_total_produced + v_partial;

  -- Recurring trade agreements: at most one firing per call, only
  -- driven by the proposer side (from_player_id = v_uid).
  PERFORM public._pp_run_agreements(v_uid);

  v_operating_services := public._pp_run_services(v_uid, v_staffing.staffed_ids);
  v_total_money := public._pp_run_tax(v_uid, v_staffing.staffed_ids);
  v_total_upkeep := public._pp_run_upkeep(v_uid, v_staffing.staffed_ids);

  v_food_drained := public._pp_drain_housing_food(v_uid);

  v_evolution_events := public._pp_evolve_housing(v_uid, v_operating_services);

  v_crime := public._pp_update_crime(v_uid);

  v_supply := FLOOR(v_population)::integer + v_tavern_bonus;
  UPDATE public.player_profiles
  SET worker_capacity = v_supply,
      workers_used = LEAST(v_supply, v_staffing.workers_needed)
  WHERE id = v_uid;

  RETURN json_build_object(
    'total_produced', v_total_produced,
    'total_money_collected', v_total_money,
    'total_upkeep_paid', v_total_upkeep,
    'food_drained', v_food_drained,
    'evolution_events', array_to_json(v_evolution_events),
    'worker_supply', v_supply,
    'workers_needed', v_staffing.workers_needed,
    'unstaffed_count', v_staffing.unstaffed_count,
    'population', v_population,
    'happiness', (SELECT happiness FROM public.player_profiles WHERE id = v_uid),
    'crime', v_crime
  );
END;
$function$;
