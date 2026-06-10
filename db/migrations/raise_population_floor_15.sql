-- ── Raise population floor: 5 → 15 ──
-- All extractors and food_extractors cost 10 workers each. The Well
-- (often the second thing a player builds, for service coverage) costs
-- 3 more. Worker capacity = floor(population), so a starter at
-- population 5 cannot staff a single 10-worker building.
--
-- Population only grows past floor when happiness ≥ 50, but happiness
-- depends heavily on food variety, which requires staffing a food
-- extractor — circular, unwinnable from the starter state.
--
-- Floor of 15 gives:
--   - Well (3) + first food extractor (10) = 13 workers, ✓
--   - 2 spare to grow into a second building as housing supply allows.
-- This is the minimum that lets the bootstrap economy actually start.
-- Population still grows above 15 toward target (5 + housing_supply)
-- when happiness ≥ 50 — the floor only changes the *minimum*, not the
-- target.

-- 1. Update the function constant.
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
  v_max_rate constant numeric := 1.0;
  v_floor constant numeric := 15;      -- raised from 5 to break the soft-lock
  v_rate numeric;
BEGIN
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

  UPDATE public.player_profiles
  SET population = v_pop,
      happiness = v_happiness,
      migration_rate = v_rate,
      last_population_tick_at = now()
  WHERE id = p_uid;

  RETURN v_pop;
END;
$function$;

-- 2. Bump existing players who are below the new floor.
UPDATE public.player_profiles
   SET population = 15
 WHERE population < 15;

-- 3. Update the column default for fresh inserts.
ALTER TABLE public.player_profiles ALTER COLUMN population SET DEFAULT 15;
