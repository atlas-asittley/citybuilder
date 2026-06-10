-- ─────────────────────────────────────────────────────────────────────
-- Treasury chart aggregation pushed server-side (2026-05-09).
--
-- Bug: client did SELECT * FROM cash_transactions and bucketed in JS.
-- PostgREST defaults to a 1000-row cap on SELECT responses — Drew had
-- 1571 cash rows in the trailing 7 days, so the chart was missing ~36%
-- of his transactions, with no error to flag it. Order was also
-- unspecified, so which 575 got dropped was non-deterministic.
--
-- Two RPCs replace the client aggregation:
--   1. get_treasury_daily_series(p_days)
--      One row per day in the window with earned, spent, net, top
--      sources/sinks. Replicates the cross-midnight distribution the
--      client used to do for continuous-rate accruals (period_start
--      → created_at) so a 7-hour upkeep no longer shows as a single-
--      day spike.
--   2. get_cash_ledger_by_source(p_since)
--      Sum of amounts grouped by source, since the cutoff. Drives the
--      Income sources / Spending tables in the period selector.
--
-- Both are SECURITY DEFINER + auth-required + scoped to auth.uid().
-- ─────────────────────────────────────────────────────────────────────

-- ─────────────────────────────────────────────────────────────────────
-- get_treasury_daily_series
--
-- For each row, we expand it into N day-portions where N = number of
-- days the [period_start, created_at] window touches. Point events
-- (period_start NULL or = created_at) all belong to the created_at day.
-- Continuous-rate events (period_start < created_at) get their amount
-- split across days proportional to the seconds spent in each.
-- ─────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.get_treasury_daily_series(p_days int DEFAULT 7)
RETURNS TABLE(
  day date,
  earned numeric,
  spent numeric,
  net numeric,
  sources jsonb,
  sinks jsonb
)
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_days int := GREATEST(1, LEAST(COALESCE(p_days, 7), 90));
  v_since timestamptz := now() - (v_days || ' days')::interval;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'auth required'; END IF;

  -- All inner CTEs use `bucket` instead of `day` to avoid colliding
  -- with the OUT param of the same name.
  RETURN QUERY
  WITH day_grid AS (
    SELECT generate_series(
      date_trunc('day', v_since),
      date_trunc('day', now()),
      '1 day'::interval
    )::date AS bucket
  ),
  expanded AS (
    SELECT
      g.bucket,
      ct.source,
      ct.amount,
      GREATEST(
        1.0,
        EXTRACT(EPOCH FROM (ct.created_at - COALESCE(ct.period_start, ct.created_at)))
      )::numeric AS total_secs,
      GREATEST(
        0.0,
        EXTRACT(EPOCH FROM (
          LEAST(ct.created_at, (g.bucket + 1)::timestamptz) -
          GREATEST(COALESCE(ct.period_start, ct.created_at), g.bucket::timestamptz)
        ))
      )::numeric AS intersect_secs,
      ct.created_at,
      ct.period_start
    FROM public.cash_transactions ct
    JOIN day_grid g ON
      ct.created_at >= g.bucket::timestamptz
      AND COALESCE(ct.period_start, ct.created_at) < (g.bucket + 1)::timestamptz
    WHERE ct.player_id = v_uid
      AND ct.created_at >= v_since
  ),
  attributed AS (
    SELECT
      bucket,
      source,
      CASE
        WHEN total_secs <= 1 THEN
          CASE WHEN bucket = created_at::date THEN amount ELSE 0::numeric END
        ELSE
          amount * (intersect_secs / total_secs)
      END AS portion
    FROM expanded
  ),
  per_day AS (
    SELECT
      bucket,
      source,
      SUM(portion) AS portion_sum
    FROM attributed
    WHERE portion <> 0
    GROUP BY bucket, source
  ),
  per_day_rolled AS (
    SELECT
      bucket,
      COALESCE(SUM(CASE WHEN portion_sum > 0 THEN portion_sum END), 0) AS earned_,
      COALESCE(SUM(CASE WHEN portion_sum < 0 THEN -portion_sum END), 0) AS spent_,
      jsonb_object_agg(source, portion_sum)
        FILTER (WHERE portion_sum > 0) AS sources_,
      jsonb_object_agg(source, -portion_sum)
        FILTER (WHERE portion_sum < 0) AS sinks_
    FROM per_day
    GROUP BY bucket
  )
  SELECT
    g.bucket AS day,
    COALESCE(pdr.earned_, 0) AS earned,
    COALESCE(pdr.spent_, 0) AS spent,
    COALESCE(pdr.earned_, 0) - COALESCE(pdr.spent_, 0) AS net,
    COALESCE(pdr.sources_, '{}'::jsonb) AS sources,
    COALESCE(pdr.sinks_, '{}'::jsonb) AS sinks
  FROM day_grid g
  LEFT JOIN per_day_rolled pdr ON pdr.bucket = g.bucket
  ORDER BY g.bucket;
END;
$$;


-- ─────────────────────────────────────────────────────────────────────
-- get_cash_ledger_by_source
-- Period sum of amounts per source (positive amounts → earned, negative
-- → spent). Caller picks the cutoff. Replaces the SELECT-and-bucket
-- pattern in fetchCashLedger.
-- ─────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.get_cash_ledger_by_source(p_since timestamptz)
RETURNS TABLE(source text, amount numeric)
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_uid uuid := auth.uid();
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'auth required'; END IF;
  IF p_since IS NULL THEN p_since := '1970-01-01'::timestamptz; END IF;

  RETURN QUERY
  SELECT ct.source::text, SUM(ct.amount)::numeric AS amount
  FROM public.cash_transactions ct
  WHERE ct.player_id = v_uid
    AND ct.created_at >= p_since
  GROUP BY ct.source;
END;
$$;
