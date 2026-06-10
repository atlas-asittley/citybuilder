-- ── Numeric precision fix: population + migration_rate ──
-- Atlas asked to scan every numeric column for the same bloat
-- pattern. Found two more on player_profiles:
--   population         — 45-char values (Drew + Jill)
--   migration_rate     — 23-char values (Drew + Jill)
--
-- Source: _pp_update_population builds v_rate from a division
-- ((happiness − 50) / 50.0) × max_rate, then v_pop := v_pop + v_rate
-- × v_minutes. v_minutes is fractional (epoch_seconds / 60), v_rate
-- carries the division precision, and the running sum into v_pop
-- accumulates trailing digits every tick.
--
-- Fix: ROUND v_pop to 6 decimals (≈ 0.000001 person — well below
-- display granularity) and v_rate to 4 decimals (rates are usually
-- in [-4, 4]; 4 decimals = 0.0001/min resolution). Both bounded so
-- storage stays sane.
--
-- Backfill UPDATE collapses existing inflated rows in place.

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

  -- Round before storing — without this, every tick adds another
  -- ~20 digits of division-precision to player_profiles.population.
  -- 6 decimals on population (sub-millionth-of-a-person), 4 on rate
  -- (sub-0.0001/min). Both well below any display granularity.
  UPDATE public.player_profiles
  SET population = ROUND(v_pop, 6),
      happiness = v_happiness,
      migration_rate = ROUND(v_rate, 4),
      last_population_tick_at = now()
  WHERE id = p_uid;

  RETURN v_pop;
END;
$function$;

-- ── Backfill ──
UPDATE public.player_profiles
   SET population = ROUND(population, 6),
       migration_rate = ROUND(migration_rate, 4)
 WHERE length(population::text) > 20
    OR length(migration_rate::text) > 20;
