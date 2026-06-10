-- ── Tutorial system + faster immigration ──
-- Two related changes from a playtest:
--
-- 1. New players go through a guided sequence: build a house → build a
--    well → build a food extractor → trade unlocks. The client filters
--    the build panel by tutorial_step so each step only shows the next
--    unlock. Step advances via an AFTER INSERT trigger on buildings.
--
--    The new `trade_unlocked` flag is sticky: once it flips on (when
--    the player places their first food extractor), it never reverts.
--    That replaces the old "must currently have extractor + food + tier-1
--    housing" gate, which punished the player for demolishing a hut.
--
-- 2. Immigration max rate was 1 person/min — slow enough that early
--    cities sit at the population floor for an hour after happiness
--    crosses 50. Bumped to 4/min so a happy city grows ~1/tick at
--    happiness 75 and ~2/tick at 100.
--
-- Existing players are backfilled to tutorial_step=3 / trade_unlocked=true
-- so they don't suddenly find their build panel locked down.

ALTER TABLE public.player_profiles
  ADD COLUMN IF NOT EXISTS tutorial_step integer NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS trade_unlocked boolean NOT NULL DEFAULT false;

-- Backfill: existing profiles have already played past these steps.
UPDATE public.player_profiles
   SET tutorial_step = 3,
       trade_unlocked = true;

-- Trigger function: advance tutorial when the player builds the
-- target building for their current step.
CREATE OR REPLACE FUNCTION public._advance_tutorial()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_step integer;
  v_category text;
BEGIN
  SELECT tutorial_step INTO v_step
  FROM public.player_profiles
  WHERE id = NEW.player_id;

  IF v_step IS NULL OR v_step >= 3 THEN
    RETURN NEW;
  END IF;

  SELECT category INTO v_category
  FROM public.building_types
  WHERE key = NEW.building_type_key;

  IF v_step = 0 AND v_category = 'housing' THEN
    UPDATE public.player_profiles
       SET tutorial_step = 1
     WHERE id = NEW.player_id;
  ELSIF v_step = 1 AND NEW.building_type_key = 'well' THEN
    UPDATE public.player_profiles
       SET tutorial_step = 2
     WHERE id = NEW.player_id;
  ELSIF v_step = 2 AND v_category = 'food_extractor' THEN
    UPDATE public.player_profiles
       SET tutorial_step = 3,
           trade_unlocked = true
     WHERE id = NEW.player_id;
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS buildings_advance_tutorial ON public.buildings;
CREATE TRIGGER buildings_advance_tutorial
AFTER INSERT ON public.buildings
FOR EACH ROW EXECUTE FUNCTION public._advance_tutorial();

-- is_trade_unlocked now reads the sticky flag instead of recomputing
-- requirements every call. The old "must have extractor + food + hut
-- right now" check made trade flicker off if the player demolished
-- anything; now it's earned once and kept.
CREATE OR REPLACE FUNCTION public.is_trade_unlocked(p_player_id uuid)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
AS $$
DECLARE
  v_unlocked boolean;
BEGIN
  SELECT trade_unlocked INTO v_unlocked
  FROM public.player_profiles
  WHERE id = p_player_id;
  RETURN COALESCE(v_unlocked, false);
END;
$$;

-- Faster immigration: max rate 1.0 → 4.0 person/min. Happy cities now
-- grow at a perceptible pace instead of trickling in one citizen
-- every several minutes.
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
  v_max_rate constant numeric := 4.0;   -- was 1.0; bumped per playtest
  v_floor constant numeric := 15;
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
