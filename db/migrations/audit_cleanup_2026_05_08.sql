-- ── Database integrity audit cleanup (2026-05-08 overnight) ──
-- Findings from a 10-check sweep of the public schema:
--
-- A2 (RLS coverage): three tables had RLS disabled with no policies —
--     counter / player_notifications / trade_offers. None are
--     referenced by any JS or server function. They are dead schema.
--     Enabling RLS without a SELECT policy denies all access (including
--     authenticated reads) so the rows are inaccessible. Keeping the
--     tables in place rather than dropping them in case Atlas wants
--     them later, but they're now locked down.
--
-- A3 (numeric bloat): missed one column in the earlier precision pass.
--     player_profiles.happiness comes from compute_happiness via
--     v_happiness in _pp_update_population, and goes into UPDATE
--     unrounded. Fix: ROUND(v_happiness, 2) at write time, plus
--     backfill the live rows.

-- ── A2: lock down dead tables ──
ALTER TABLE public.counter ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.player_notifications ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.trade_offers ENABLE ROW LEVEL SECURITY;

-- ── A3: round happiness in _pp_update_population ──
CREATE OR REPLACE FUNCTION public._pp_update_population(p_uid uuid)
 RETURNS numeric
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  v_target numeric;
  v_pop numeric;
  v_happiness numeric;
  v_last timestamptz;
  v_minutes numeric;
  v_max_rate constant numeric := 4.0;
  v_floor numeric;
  v_rate numeric;
  v_step integer;
BEGIN
  SELECT tutorial_step INTO v_step FROM public.player_profiles WHERE id = p_uid;
  v_floor := CASE WHEN COALESCE(v_step, 4) < 4 THEN 0 ELSE 15 END;
  v_target := v_floor + public._pp_housing_supply(p_uid);

  SELECT population, last_population_tick_at INTO v_pop, v_last
  FROM public.player_profiles WHERE id = p_uid;
  IF v_pop IS NULL THEN v_pop := v_floor; END IF;
  IF v_last IS NULL THEN v_last := now() - interval '1 minute'; END IF;

  v_minutes := GREATEST(0, EXTRACT(EPOCH FROM (now() - v_last)) / 60.0);
  IF v_minutes > 60 THEN v_minutes := 60; END IF;

  v_happiness := (public.compute_happiness(p_uid)->>'happiness')::numeric;

  IF v_pop > v_target THEN
    v_rate := 0;
    v_pop := v_target;
  ELSIF v_pop < v_floor THEN
    v_rate := v_max_rate;
    v_pop := LEAST(v_floor, v_pop + v_rate * v_minutes);
  ELSIF v_pop < v_target AND v_happiness >= 50 THEN
    v_rate := ((v_happiness - 50) / 50.0) * v_max_rate;
    v_pop := LEAST(v_target, v_pop + v_rate * v_minutes);
  ELSIF v_happiness < 50 AND v_pop > v_floor THEN
    v_rate := -((50 - v_happiness) / 50.0) * v_max_rate;
    v_pop := GREATEST(v_floor, v_pop + v_rate * v_minutes);
  ELSE
    v_rate := 0;
  END IF;

  -- Round before storing. compute_happiness derives v_happiness from
  -- divisions (staffing ratios, food variety scores) so even though
  -- it's a 0-100 score, the underlying numeric carries fractional
  -- precision that accumulates without rounding here.
  UPDATE public.player_profiles
  SET population = ROUND(v_pop, 6),
      happiness = ROUND(v_happiness, 2),
      migration_rate = ROUND(v_rate, 4),
      last_population_tick_at = now()
  WHERE id = p_uid;

  RETURN v_pop;
END;
$function$;

-- ── A3 backfill ──
UPDATE public.player_profiles
   SET happiness = ROUND(happiness, 2)
 WHERE length(happiness::text) > 10;
