-- Refine population dynamics: immigration is instant (population fills
-- empty housing the moment it appears); emigration is slow and gated
-- on unhappiness. This matches builder-game intuition ("build a house,
-- get workers") and unblocks the tests that expect housing → worker
-- capacity in a single tick.
--
-- Behavior:
--   target > pop                : pop := target   (instant fill)
--   target ≤ pop, happiness <50 : pop drifts down at ((50-h)/50) /min
--   target ≤ pop, happiness ≥50 : pop := min(target, pop)  (clamp)

CREATE OR REPLACE FUNCTION public._pp_update_population(p_uid uuid)
RETURNS numeric
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_target numeric;
  v_pop numeric;
  v_happiness numeric;
  v_last timestamptz;
  v_minutes numeric;
  v_max_rate constant numeric := 1.0;
  v_delta numeric;
BEGIN
  v_target := 5 + public._pp_housing_supply(p_uid);

  SELECT population, last_population_tick_at INTO v_pop, v_last
  FROM public.player_profiles WHERE id = p_uid;
  IF v_pop IS NULL THEN v_pop := 5; END IF;
  IF v_last IS NULL THEN v_last := now() - interval '1 minute'; END IF;

  v_minutes := GREATEST(0, EXTRACT(EPOCH FROM (now() - v_last)) / 60.0);
  IF v_minutes > 60 THEN v_minutes := 60; END IF;

  v_happiness := (public.compute_happiness(p_uid)->>'happiness')::numeric;

  IF v_target > v_pop THEN
    -- Empty homes fill instantly with new arrivals.
    v_pop := v_target;
  ELSIF v_happiness < 50 THEN
    -- At/above target but unhappy → citizens slowly leave.
    v_delta := ((50 - v_happiness) / 50.0) * v_max_rate * v_minutes;
    v_pop := GREATEST(0, LEAST(v_target, v_pop - v_delta));
  ELSE
    -- At/above target and content → clamp down to target if housing was lost.
    v_pop := LEAST(v_target, v_pop);
  END IF;

  UPDATE public.player_profiles
  SET population = v_pop,
      happiness = v_happiness,
      last_population_tick_at = now()
  WHERE id = p_uid;

  RETURN v_pop;
END;
$$;
GRANT EXECUTE ON FUNCTION public._pp_update_population(uuid) TO authenticated;
