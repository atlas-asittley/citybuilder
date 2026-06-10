-- ─────────────────────────────────────────────────────────────────────
-- cash_transactions.period_start: spread catch-up charges over time.
--
-- Problem: when a player reconnects after being offline N minutes, the
-- next process_production tick computes upkeep + tax for the full N
-- minutes and inserts ONE cash_transactions row dated `now()` with the
-- whole amount. The Treasury daily-bar / cumulative-line charts then
-- show a single ugly spike on the day they reconnected, even though
-- the money was conceptually drained smoothly across the offline
-- window.
--
-- Fix: add `period_start timestamptz`. For continuous-rate phases
-- (upkeep, tax) we set period_start = the earliest staffed building's
-- previous last_processed_at — the moment accrual began for the
-- batch. For point-in-time events (build_cost, p2p_trade, etc.) we
-- leave it null, which the chart treats as a single instant. The
-- Treasury renderer pro-rates any row where period_start < created_at
-- across the daily buckets the window touches.
--
-- Discrete catch-up paths (agreements, trader visits) are left for a
-- follow-up — they're event-based, smaller per-tick, and the right
-- fix is backdating created_at, not spreading.
-- ─────────────────────────────────────────────────────────────────────

ALTER TABLE public.cash_transactions
  ADD COLUMN IF NOT EXISTS period_start timestamptz;

COMMENT ON COLUMN public.cash_transactions.period_start IS
  'For continuous-rate charges (upkeep, tax) catching up over an offline window: '
  'the moment accrual began. NULL for point-in-time events.';


-- ── upkeep ── (return type unchanged: integer)
CREATE OR REPLACE FUNCTION public._pp_run_upkeep(p_uid uuid, p_staffed_ids uuid[])
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
DECLARE
  v_now timestamptz := now();
  v_total integer := 0;
  v_b record;
  v_elapsed numeric;
  v_amt numeric;
  v_is_staffed boolean;
  v_period_start timestamptz;
BEGIN
  FOR v_b IN
    SELECT b.id, b.last_processed_at, bt.upkeep_per_minute
    FROM public.buildings b
    JOIN public.building_types bt ON bt.key = b.building_type_key
    WHERE b.player_id = p_uid AND b.status = 'active'
      AND bt.upkeep_per_minute > 0
    FOR UPDATE OF b
  LOOP
    v_is_staffed := v_b.id = ANY(p_staffed_ids);
    IF v_is_staffed THEN
      v_elapsed := EXTRACT(EPOCH FROM (v_now - v_b.last_processed_at));
      v_amt := FLOOR((v_elapsed / 60.0) * v_b.upkeep_per_minute);
      IF v_amt > 0 THEN
        UPDATE public.player_profiles SET money = money - v_amt::integer WHERE id = p_uid;
        v_total := v_total + v_amt::integer;
        -- Track the earliest accrual start across the staffed buildings
        -- that actually billed. The summary row's period_start is then
        -- a true lower bound on the accrual window.
        IF v_period_start IS NULL OR v_b.last_processed_at < v_period_start THEN
          v_period_start := v_b.last_processed_at;
        END IF;
      END IF;
    END IF;
    -- Always advance the clock — don't bill unstaffed time on the
    -- next staffed tick.
    UPDATE public.buildings SET last_processed_at = v_now WHERE id = v_b.id;
  END LOOP;

  IF v_total > 0 THEN
    INSERT INTO public.cash_transactions (player_id, source, amount, context, period_start)
    VALUES (p_uid, 'upkeep', -v_total, NULL, v_period_start);
  END IF;

  RETURN v_total;
END;
$function$;


-- ── tax ── (return type unchanged: integer)
CREATE OR REPLACE FUNCTION public._pp_run_tax(p_uid uuid, p_staffed_ids uuid[])
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
DECLARE
  v_now timestamptz := now();
  v_total integer := 0;
  v_b record;
  v_elapsed numeric;
  v_amt numeric;
  v_productivity numeric;
  v_population numeric;
  v_period_start timestamptz;
BEGIN
  SELECT COALESCE(productivity, 1.0), COALESCE(population, 0)
    INTO v_productivity, v_population
  FROM public.player_profiles WHERE id = p_uid;

  FOR v_b IN
    SELECT b.id, b.last_processed_at, bt.output_rate
    FROM public.buildings b
    JOIN public.building_types bt ON bt.key = b.building_type_key
    WHERE b.player_id = p_uid AND b.status = 'active' AND bt.category = 'tax'
      AND b.id = ANY(p_staffed_ids)
    FOR UPDATE OF b
  LOOP
    v_elapsed := EXTRACT(EPOCH FROM (v_now - v_b.last_processed_at));
    v_amt := FLOOR((v_elapsed / 60.0) * v_b.output_rate * (v_population / 100.0) * v_productivity);
    IF v_amt > 0 THEN
      UPDATE public.player_profiles SET money = money + v_amt::integer WHERE id = p_uid;
      v_total := v_total + v_amt::integer;
      IF v_period_start IS NULL OR v_b.last_processed_at < v_period_start THEN
        v_period_start := v_b.last_processed_at;
      END IF;
    END IF;
    UPDATE public.buildings SET last_processed_at = v_now WHERE id = v_b.id;
  END LOOP;

  IF v_total > 0 THEN
    INSERT INTO public.cash_transactions (player_id, source, amount, context, period_start)
    VALUES (p_uid, 'tax_revenue', v_total, NULL, v_period_start);
  END IF;

  RETURN v_total;
END;
$function$;
