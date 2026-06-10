-- ====================================================================
-- Productivity v1: per-player multiplier on production outputs
-- ====================================================================
-- Per `docs/PRODUCTIVITY.md`: a single global multiplier in [0.7, 1.3]
-- on every production building's output. v1 ships TWO levers (crime
-- drag + tavern bonus); the doc describes more (education / tools /
-- worker buffer) which can layer on later. Default 1.0 means no
-- effect for fresh players or the median equilibrium.
--
-- Multiplier applies to: extractor / food_extractor / processor / tax
-- output amounts. Boosters and services are unaffected (boosters give
-- a per-tile bonus that already multiplies; services don't have an
-- output_rate axis to scale).
--
-- Compute is dirt cheap (one read of crime, one EXISTS for tavern).
-- Each production phase reads `productivity` from player_profiles at
-- the start of its work and multiplies output by it.

ALTER TABLE public.player_profiles
  ADD COLUMN IF NOT EXISTS productivity numeric NOT NULL DEFAULT 1.0;


-- ── Compute helper ────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public._pp_compute_productivity(p_uid uuid)
RETURNS numeric
LANGUAGE plpgsql SECURITY DEFINER
AS $$
DECLARE
  v_crime numeric;
  v_tavern boolean;
  v_score numeric := 0;
  v_productivity numeric;
BEGIN
  -- Crime drag: -0.005 per crime point above 50, max -0.10
  SELECT COALESCE(crime, 0) INTO v_crime FROM public.player_profiles WHERE id = p_uid;
  IF v_crime > 50 THEN
    v_score := v_score - LEAST(0.10, (v_crime - 50) * 0.005);
  END IF;

  -- Tavern bonus: +0.05 if any staffed tavern operating
  SELECT EXISTS (
    SELECT 1 FROM public.buildings b
    JOIN public.building_types bt ON bt.key = b.building_type_key
    WHERE b.player_id = p_uid AND b.status = 'active' AND b.is_staffed
      AND bt.key = 'tavern'
  ) INTO v_tavern;
  IF v_tavern THEN v_score := v_score + 0.05; END IF;

  -- Clamp and store
  v_productivity := GREATEST(0.7, LEAST(1.3, 1.0 + v_score));
  UPDATE public.player_profiles SET productivity = v_productivity WHERE id = p_uid;
  RETURN v_productivity;
END;
$$;
GRANT EXECUTE ON FUNCTION public._pp_compute_productivity(uuid) TO authenticated;


-- ── Modify production phase helpers to multiply by productivity ──

CREATE OR REPLACE FUNCTION public._pp_run_extractors(p_uid uuid, p_staffed_ids uuid[])
RETURNS numeric
LANGUAGE plpgsql SECURITY DEFINER
AS $$
DECLARE
  v_now timestamptz := now();
  v_total numeric := 0;
  v_b record;
  v_elapsed numeric;
  v_path_factor numeric;
  v_boost numeric;
  v_amount numeric;
  v_canonical constant integer := 4;
  v_productivity numeric;
BEGIN
  SELECT COALESCE(productivity, 1.0) INTO v_productivity
  FROM public.player_profiles WHERE id = p_uid;

  FOR v_b IN
    SELECT b.id, b.x, b.y, b.last_processed_at, b.path_length,
           bt.output_resource_key, bt.output_rate
    FROM public.buildings b
    JOIN public.building_types bt ON bt.key = b.building_type_key
    WHERE b.player_id = p_uid AND b.status = 'active' AND bt.category = 'extractor'
      AND b.id = ANY(p_staffed_ids)
    FOR UPDATE OF b
  LOOP
    IF v_b.path_length IS NULL THEN
      UPDATE public.buildings SET last_processed_at = v_now WHERE id = v_b.id;
      CONTINUE;
    END IF;
    v_elapsed := EXTRACT(EPOCH FROM (v_now - v_b.last_processed_at));
    v_path_factor := LEAST(1.0, v_canonical::numeric / v_b.path_length);
    SELECT COALESCE(MAX(bt2.boost_multiplier), 1.0) INTO v_boost
    FROM public.buildings b2
    JOIN public.building_types bt2 ON bt2.key = b2.building_type_key
    WHERE b2.player_id = p_uid AND b2.status = 'active'
      AND bt2.category = 'booster' AND bt2.boost_target = 'extractor'
      AND b2.id = ANY(p_staffed_ids)
      AND ABS(b2.x - v_b.x) + ABS(b2.y - v_b.y) <= bt2.boost_range;
    v_amount := (v_elapsed / 60.0) * v_b.output_rate * v_path_factor * v_boost * v_productivity;
    IF v_amount > 0 THEN
      INSERT INTO public.inventories (player_id, resource_key, quantity)
      VALUES (p_uid, v_b.output_resource_key, v_amount)
      ON CONFLICT (player_id, resource_key)
      DO UPDATE SET quantity = public.inventories.quantity + EXCLUDED.quantity;
      v_total := v_total + v_amount;
    END IF;
    UPDATE public.buildings SET last_processed_at = v_now WHERE id = v_b.id;
  END LOOP;
  RETURN v_total;
END;
$$;


CREATE OR REPLACE FUNCTION public._pp_run_food_extractors(p_uid uuid, p_staffed_ids uuid[])
RETURNS numeric
LANGUAGE plpgsql SECURITY DEFINER
AS $$
DECLARE
  v_now timestamptz := now();
  v_total numeric := 0;
  v_b record;
  v_elapsed numeric;
  v_boost numeric;
  v_amount numeric;
  v_productivity numeric;
BEGIN
  SELECT COALESCE(productivity, 1.0) INTO v_productivity
  FROM public.player_profiles WHERE id = p_uid;

  FOR v_b IN
    SELECT b.id, b.x, b.y, b.last_processed_at,
           bt.output_resource_key, bt.output_rate
    FROM public.buildings b
    JOIN public.building_types bt ON bt.key = b.building_type_key
    WHERE b.player_id = p_uid AND b.status = 'active' AND bt.category = 'food_extractor'
      AND b.id = ANY(p_staffed_ids)
    FOR UPDATE OF b
  LOOP
    v_elapsed := EXTRACT(EPOCH FROM (v_now - v_b.last_processed_at));
    SELECT COALESCE(MAX(bt2.boost_multiplier), 1.0) INTO v_boost
    FROM public.buildings b2
    JOIN public.building_types bt2 ON bt2.key = b2.building_type_key
    WHERE b2.player_id = p_uid AND b2.status = 'active'
      AND bt2.category = 'booster' AND bt2.boost_target = 'food_extractor'
      AND b2.id = ANY(p_staffed_ids)
      AND ABS(b2.x - v_b.x) + ABS(b2.y - v_b.y) <= bt2.boost_range;
    v_amount := (v_elapsed / 60.0) * v_b.output_rate * v_boost * v_productivity;
    IF v_amount > 0 THEN
      INSERT INTO public.inventories (player_id, resource_key, quantity)
      VALUES (p_uid, v_b.output_resource_key, v_amount)
      ON CONFLICT (player_id, resource_key)
      DO UPDATE SET quantity = public.inventories.quantity + EXCLUDED.quantity;
      v_total := v_total + v_amount;
    END IF;
    UPDATE public.buildings SET last_processed_at = v_now WHERE id = v_b.id;
  END LOOP;
  RETURN v_total;
END;
$$;


CREATE OR REPLACE FUNCTION public._pp_run_processors(p_uid uuid, p_staffed_ids uuid[])
RETURNS numeric
LANGUAGE plpgsql SECURITY DEFINER
AS $$
DECLARE
  v_now timestamptz := now();
  v_total numeric := 0;
  v_b record;
  v_elapsed numeric;
  v_productivity numeric;
BEGIN
  SELECT COALESCE(productivity, 1.0) INTO v_productivity
  FROM public.player_profiles WHERE id = p_uid;

  FOR v_b IN
    SELECT b.id, b.last_processed_at,
           bt.input_resource_key, bt.input_rate,
           bt.input_resource_key_2, bt.input_rate_2,
           bt.output_resource_key, bt.output_rate
    FROM public.buildings b
    JOIN public.building_types bt ON bt.key = b.building_type_key
    WHERE b.player_id = p_uid AND b.status = 'active' AND bt.category = 'processor'
      AND b.id = ANY(p_staffed_ids)
    FOR UPDATE OF b
  LOOP
    v_elapsed := EXTRACT(EPOCH FROM (v_now - v_b.last_processed_at));
    DECLARE
      v_need1 numeric := COALESCE((v_elapsed / 60.0) * v_b.input_rate,   0);
      v_need2 numeric := COALESCE((v_elapsed / 60.0) * v_b.input_rate_2, 0);
      v_avail1 numeric := 0;
      v_avail2 numeric := 0;
      v_used1 numeric := 0;
      v_used2 numeric := 0;
      v_progress numeric := 1;
      v_made numeric := 0;
    BEGIN
      IF v_b.input_resource_key IS NOT NULL THEN
        SELECT COALESCE(quantity, 0) INTO v_avail1 FROM public.inventories
        WHERE player_id = p_uid AND resource_key = v_b.input_resource_key;
      END IF;
      IF v_b.input_resource_key_2 IS NOT NULL THEN
        SELECT COALESCE(quantity, 0) INTO v_avail2 FROM public.inventories
        WHERE player_id = p_uid AND resource_key = v_b.input_resource_key_2;
      END IF;
      IF v_need1 > 0 THEN v_progress := LEAST(v_progress, v_avail1 / v_need1); END IF;
      IF v_need2 > 0 THEN v_progress := LEAST(v_progress, v_avail2 / v_need2); END IF;
      v_progress := GREATEST(0, v_progress);
      IF v_progress > 0 THEN
        IF v_need1 > 0 AND v_b.input_resource_key IS NOT NULL THEN
          v_used1 := v_need1 * v_progress;
          UPDATE public.inventories SET quantity = quantity - v_used1
          WHERE player_id = p_uid AND resource_key = v_b.input_resource_key;
        END IF;
        IF v_need2 > 0 AND v_b.input_resource_key_2 IS NOT NULL THEN
          v_used2 := v_need2 * v_progress;
          UPDATE public.inventories SET quantity = quantity - v_used2
          WHERE player_id = p_uid AND resource_key = v_b.input_resource_key_2;
        END IF;
        v_made := (v_elapsed / 60.0) * v_b.output_rate * v_progress * v_productivity;
        IF v_made > 0 AND v_b.output_resource_key IS NOT NULL THEN
          INSERT INTO public.inventories (player_id, resource_key, quantity)
          VALUES (p_uid, v_b.output_resource_key, v_made)
          ON CONFLICT (player_id, resource_key)
          DO UPDATE SET quantity = public.inventories.quantity + EXCLUDED.quantity;
          v_total := v_total + v_made;
        END IF;
      END IF;
      UPDATE public.buildings SET last_processed_at = v_now WHERE id = v_b.id;
    END;
  END LOOP;
  RETURN v_total;
END;
$$;


CREATE OR REPLACE FUNCTION public._pp_run_tax(p_uid uuid, p_staffed_ids uuid[])
RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER
AS $$
DECLARE
  v_now timestamptz := now();
  v_total integer := 0;
  v_b record;
  v_elapsed numeric;
  v_amt numeric;
  v_productivity numeric;
BEGIN
  SELECT COALESCE(productivity, 1.0) INTO v_productivity
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
    v_amt := FLOOR((v_elapsed / 60.0) * v_b.output_rate * v_productivity);
    IF v_amt > 0 THEN
      UPDATE public.player_profiles SET money = money + v_amt::integer WHERE id = p_uid;
      v_total := v_total + v_amt::integer;
    END IF;
    UPDATE public.buildings SET last_processed_at = v_now WHERE id = v_b.id;
  END LOOP;

  IF v_total > 0 THEN
    INSERT INTO public.cash_transactions (player_id, source, amount, context)
    VALUES (p_uid, 'tax_revenue', v_total, NULL);
  END IF;

  RETURN v_total;
END;
$$;


-- ── Hook into process_production ────────────────────────────────
-- Compute productivity AFTER staffing (so the tavern check can see
-- is_staffed) and BEFORE the production phases (so they read it).

CREATE OR REPLACE FUNCTION public.process_production()
RETURNS json
LANGUAGE plpgsql SECURITY DEFINER
AS $$
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
  v_productivity numeric;
BEGIN
  v_tavern_bonus := public._pp_tavern_bonus(v_uid);
  v_population := public._pp_update_population(v_uid);
  v_supply := FLOOR(v_population)::integer + v_tavern_bonus;

  SELECT staffed_ids, workers_needed, unstaffed_count
    INTO v_staffing
    FROM public._pp_staff_buildings(v_uid, v_supply);

  PERFORM public._pp_update_pollution(v_uid);

  -- Compute productivity once per tick — used by every production phase
  -- below. Reads previous tick's crime; tavern is_staffed status is
  -- fresh from the staffing call above.
  v_productivity := public._pp_compute_productivity(v_uid);

  v_partial := public._pp_run_extractors(v_uid, v_staffing.staffed_ids);
  v_total_produced := v_total_produced + v_partial;
  v_partial := public._pp_run_food_extractors(v_uid, v_staffing.staffed_ids);
  v_total_produced := v_total_produced + v_partial;
  PERFORM public._pp_bump_boosters(v_uid, v_staffing.staffed_ids);
  v_partial := public._pp_run_processors(v_uid, v_staffing.staffed_ids);
  v_total_produced := v_total_produced + v_partial;

  PERFORM public._pp_run_agreements(v_uid);

  v_operating_services := public._pp_run_services(v_uid, v_staffing.staffed_ids);
  v_total_money := public._pp_run_tax(v_uid, v_staffing.staffed_ids);
  v_total_upkeep := public._pp_run_upkeep(v_uid, v_staffing.staffed_ids);

  v_food_drained := public._pp_drain_housing_food(v_uid);

  v_crime := public._pp_update_crime(v_uid);
  PERFORM public._pp_update_desirability(v_uid);
  v_evolution_events := public._pp_evolve_housing(v_uid, v_operating_services);

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
    'crime', v_crime,
    'migration_rate', (SELECT migration_rate FROM public.player_profiles WHERE id = v_uid),
    'productivity', v_productivity
  );
END;
$$;
