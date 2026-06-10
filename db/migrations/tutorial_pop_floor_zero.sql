-- ── Tutorial: start at 0 population, +6 per house ──
-- The 15-population floor was the fix for the original soft-lock, but
-- with the tutorial flow now actively guiding the player to build
-- houses (which auto-bump to tier 1 = 6 workers), the floor makes the
-- starting population feel unearned. Better: start at 0 and let each
-- tutorial house add the 6 workers it provides.
--
-- Three changes:
--   (a) player_profiles.population default → 0 (was 15)
--   (b) _pp_update_population uses floor 0 during tutorial (step < 4)
--       and 15 after — so post-tutorial players still have the safety
--       net that prevents a total collapse.
--   (c) Trigger sets population to GREATEST(current, housing_supply)
--       on each tutorial house, instead of GREATEST(current, 15 + supply).
--       That way 4 huts = 24 pop exactly, no hidden bonus.

ALTER TABLE public.player_profiles ALTER COLUMN population SET DEFAULT 0;

CREATE OR REPLACE FUNCTION public._advance_tutorial()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_step integer;
  v_category text;
  v_house_count integer;
  v_supply integer;
BEGIN
  SELECT tutorial_step INTO v_step
  FROM public.player_profiles
  WHERE id = NEW.player_id;

  IF v_step IS NULL OR v_step >= 4 THEN
    RETURN NEW;
  END IF;

  SELECT category INTO v_category
  FROM public.building_types
  WHERE key = NEW.building_type_key;

  IF v_step = 0 AND v_category = 'housing' THEN
    UPDATE public.buildings
       SET housing_tier = 1, last_processed_at = now()
     WHERE id = NEW.id AND housing_tier = 0;

    -- Snap population to housing supply (no floor bonus during tutorial).
    -- Each tier-1 hut adds 6, so 4 huts = 24 pop.
    v_supply := public._pp_housing_supply(NEW.player_id);
    UPDATE public.player_profiles
       SET population = GREATEST(population, v_supply)
     WHERE id = NEW.player_id;

    SELECT COUNT(*) INTO v_house_count
      FROM public.buildings b
      JOIN public.building_types bt ON bt.key = b.building_type_key
     WHERE b.player_id = NEW.player_id
       AND b.status = 'active'
       AND bt.category = 'housing';
    IF v_house_count >= 4 THEN
      UPDATE public.player_profiles
         SET tutorial_step = 1
       WHERE id = NEW.player_id;
    END IF;

  ELSIF v_step = 1 AND NEW.building_type_key = 'well' THEN
    UPDATE public.player_profiles
       SET tutorial_step = 2
     WHERE id = NEW.player_id;

  ELSIF v_step = 2 AND v_category = 'food_extractor' THEN
    UPDATE public.player_profiles
       SET tutorial_step = 3
     WHERE id = NEW.player_id;

  ELSIF v_step = 3 AND v_category = 'extractor' THEN
    UPDATE public.player_profiles
       SET tutorial_step = 4,
           trade_unlocked = true
     WHERE id = NEW.player_id;
  END IF;

  RETURN NEW;
END;
$$;

-- _pp_update_population: floor depends on tutorial state.
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
  -- During the tutorial the floor is 0 — population is purely earned
  -- from the 4 starter huts. After tutorial the floor is 15, so a
  -- post-tutorial player who demolishes all housing isn't completely
  -- locked out of recovery.
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

  UPDATE public.player_profiles
  SET population = v_pop,
      happiness = v_happiness,
      migration_rate = v_rate,
      last_population_tick_at = now()
  WHERE id = p_uid;

  RETURN v_pop;
END;
$function$;
