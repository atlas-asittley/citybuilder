-- ── Numeric precision fix: extractors / processors / services / agreements ──
-- The earlier precision fix (numeric_precision_fix.sql) caught only
-- _pp_drain_housing_food. After Atlas spotted Drew's lumber stock
-- with 340+ trailing digits, an audit found the same problem family
-- in every other inventory-touching server function.
--
-- The pattern: a local numeric variable is computed from a fractional
-- expression like (v_elapsed / 60.0) * v_rate * v_progress * v_productivity,
-- then UPDATE inventories SET quantity = quantity ± that-variable.
-- PostgreSQL `numeric` is unbounded precision — each tick adds the
-- variable's precision to the running quantity. After hours, rows
-- balloon to thousands of digits.
--
-- Same fix as before: wrap every inventory-bound numeric expression
-- in ROUND(..., 6). Six decimals = 0.000001-unit granularity, far
-- below any rate or recipe we'll ship, but bounded so storage stays
-- sane.
--
-- Backfill UPDATE at the bottom rounds existing bloated rows. A row
-- that was 2.5305473824999999...(335 more digits) becomes 2.530547 —
-- same player-visible value, sane storage width.

-- ── _pp_run_processors ──
CREATE OR REPLACE FUNCTION public._pp_run_processors(p_uid uuid, p_staffed_ids uuid[])
 RETURNS numeric
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
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
          -- ROUND at the local-variable level so the inventory UPDATE
          -- doesn't carry forward division-precision into quantity.
          v_used1 := ROUND(v_need1 * v_progress, 6);
          UPDATE public.inventories SET quantity = quantity - v_used1
          WHERE player_id = p_uid AND resource_key = v_b.input_resource_key;
        END IF;
        IF v_need2 > 0 AND v_b.input_resource_key_2 IS NOT NULL THEN
          v_used2 := ROUND(v_need2 * v_progress, 6);
          UPDATE public.inventories SET quantity = quantity - v_used2
          WHERE player_id = p_uid AND resource_key = v_b.input_resource_key_2;
        END IF;
        v_made := ROUND((v_elapsed / 60.0) * v_b.output_rate * v_progress * v_productivity, 6);
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
$function$;

-- ── _pp_run_extractors ──
CREATE OR REPLACE FUNCTION public._pp_run_extractors(p_uid uuid, p_staffed_ids uuid[])
 RETURNS numeric
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
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
    v_amount := ROUND((v_elapsed / 60.0) * v_b.output_rate * v_path_factor * v_boost * v_productivity, 6);
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
$function$;

-- ── _pp_run_food_extractors ──
CREATE OR REPLACE FUNCTION public._pp_run_food_extractors(p_uid uuid, p_staffed_ids uuid[])
 RETURNS numeric
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
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
    v_amount := ROUND((v_elapsed / 60.0) * v_b.output_rate * v_boost * v_productivity, 6);
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
$function$;

-- ── _pp_run_services ──
CREATE OR REPLACE FUNCTION public._pp_run_services(p_uid uuid, p_staffed_ids uuid[])
 RETURNS uuid[]
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  v_now timestamptz := now();
  v_op uuid[] := ARRAY[]::uuid[];
  v_b record;
  v_elapsed numeric;
BEGIN
  FOR v_b IN
    SELECT b.id, b.last_processed_at, b.building_type_key,
           bt.input_resource_key, bt.input_rate,
           bt.input_resource_key_2, bt.input_rate_2,
           bt.output_rate
    FROM public.buildings b
    JOIN public.building_types bt ON bt.key = b.building_type_key
    WHERE b.player_id = p_uid AND b.status = 'active' AND bt.category = 'service'
      AND b.id = ANY(p_staffed_ids)
    FOR UPDATE OF b
  LOOP
    v_elapsed := EXTRACT(EPOCH FROM (v_now - v_b.last_processed_at));
    DECLARE
      -- Round at declaration so the gate check (v_avail >= v_need)
      -- and the subtraction both use the same bounded value.
      v_need1 numeric := COALESCE(ROUND((v_elapsed / 60.0) * v_b.input_rate,   6), 0);
      v_need2 numeric := COALESCE(ROUND((v_elapsed / 60.0) * v_b.input_rate_2, 6), 0);
      v_avail1 numeric := 0;
      v_avail2 numeric := 0;
      v_operating boolean;
    BEGIN
      IF v_b.input_resource_key IS NOT NULL THEN
        SELECT COALESCE(quantity, 0) INTO v_avail1 FROM public.inventories
        WHERE player_id = p_uid AND resource_key = v_b.input_resource_key;
      END IF;
      IF v_b.input_resource_key_2 IS NOT NULL THEN
        SELECT COALESCE(quantity, 0) INTO v_avail2 FROM public.inventories
        WHERE player_id = p_uid AND resource_key = v_b.input_resource_key_2;
      END IF;
      v_operating :=
        (v_b.input_resource_key   IS NULL OR v_avail1 >= v_need1)
        AND (v_b.input_resource_key_2 IS NULL OR v_avail2 >= v_need2);
      IF v_operating THEN
        IF v_need1 > 0 AND v_b.input_resource_key IS NOT NULL THEN
          UPDATE public.inventories SET quantity = quantity - v_need1
          WHERE player_id = p_uid AND resource_key = v_b.input_resource_key;
        END IF;
        IF v_need2 > 0 AND v_b.input_resource_key_2 IS NOT NULL THEN
          UPDATE public.inventories SET quantity = quantity - v_need2
          WHERE player_id = p_uid AND resource_key = v_b.input_resource_key_2;
        END IF;
        v_op := v_op || v_b.id;
      END IF;
      UPDATE public.buildings SET last_processed_at = v_now WHERE id = v_b.id;
    END;
  END LOOP;
  RETURN v_op;
END;
$function$;

-- ── Backfill: round every inflated row in place ──
-- Same pattern as the earlier precision fix — sane storage width
-- without changing the player-visible quantity.
UPDATE public.inventories
   SET quantity = ROUND(quantity, 6),
       updated_at = now()
 WHERE length(quantity::text) > 20;
