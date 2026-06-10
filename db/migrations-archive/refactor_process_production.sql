-- Refactor: split process_production into composable phase helpers.
--
-- The function had grown to ~470 lines and every feature migration was
-- CREATE OR REPLACE-ing the whole thing, which led to subtle drift bugs
-- (the universal-road check was missed for extractors initially; the
-- earlier OUT-param collision; the food-gate flag mixup). New shape:
--
--   process_production()          (thin orchestrator)
--     └── _pp_compute_worker_supply(uid)        → integer
--     └── _pp_staff_buildings(uid, supply)      → (staffed_ids, needed, unstaffed)
--     └── _pp_run_extractors(uid, staffed_ids)  → numeric
--     └── _pp_run_food_extractors(uid, …)        → numeric
--     └── _pp_bump_boosters(uid, …)              → void
--     └── _pp_run_processors(uid, …)             → numeric
--     └── _pp_run_services(uid, …)               → uuid[]    (operating_services)
--     └── _pp_run_tax(uid, …)                    → integer
--     └── _pp_drain_housing_food(uid)            → numeric
--     └── _pp_evolve_housing(uid, op_services)   → json[]    (evolution events)
--
-- Each phase is independently re-definable. A migration that only
-- touches housing evaluation re-defines just _pp_evolve_housing instead
-- of the whole 500-line function. Behavior is byte-for-byte preserved
-- vs the prior monolithic process_production — the existing test suite
-- (260+ tests) is the regression check.
--
-- Apply: psql "$DB_URL" -f refactor_process_production.sql

-- ── 1a. Housing worker supply ──
-- Just the housing contribution. Caller adds the +5 base and the
-- tavern bonus separately (the tavern bonus is computed ONCE at the
-- start of process_production and reused at the end, since by then
-- the tavern's last_processed_at has been updated and re-evaluating
-- the bonus would incorrectly always-qualify).
CREATE OR REPLACE FUNCTION public._pp_housing_supply(p_uid uuid)
RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_housing integer := 0;
BEGIN
  SELECT COALESCE(SUM(htc.workers), 0) INTO v_housing
  FROM public.buildings b
  JOIN public.building_types bt ON bt.key = b.building_type_key
  JOIN public.housing_tier_config htc ON htc.tier = b.housing_tier
  WHERE b.player_id = p_uid AND b.status = 'active' AND bt.category = 'housing'
    AND (NOT htc.needs_road OR public.has_road_access(p_uid, b.x, b.y))
    AND (NOT htc.needs_well OR public.has_well_access(p_uid, b.x, b.y));
  RETURN v_housing;
END;
$$;

-- ── 1b. Tavern bonus (snapshot at call time) ──
-- A staffed tavern with both inputs covering the elapsed tick adds
-- output_rate (default 10) to the player's worker capacity. Computed
-- once at the START of process_production; reused at the end so the
-- post-service-loop timestamp updates don't make every tavern look
-- "qualified" by virtue of zero elapsed time.
CREATE OR REPLACE FUNCTION public._pp_tavern_bonus(p_uid uuid)
RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_now timestamptz := now();
  v_tavern integer := 0;
BEGIN
  SELECT COALESCE(SUM(bt.output_rate), 0)::integer INTO v_tavern
  FROM public.buildings b
  JOIN public.building_types bt ON bt.key = b.building_type_key
  WHERE b.player_id = p_uid AND b.status = 'active' AND bt.key = 'tavern'
    AND public.has_road_access(p_uid, b.x, b.y)
    AND COALESCE(
          (SELECT i.quantity FROM public.inventories i
            WHERE i.player_id = p_uid AND i.resource_key = bt.input_resource_key), 0)
        >= ((EXTRACT(EPOCH FROM (v_now - b.last_processed_at)) / 60.0) * bt.input_rate)
    AND COALESCE(
          (SELECT i.quantity FROM public.inventories i
            WHERE i.player_id = p_uid AND i.resource_key = bt.input_resource_key_2), 0)
        >= ((EXTRACT(EPOCH FROM (v_now - b.last_processed_at)) / 60.0) * bt.input_rate_2);
  RETURN v_tavern;
END;
$$;

-- Old single-helper kept as a thin wrapper for any callers we haven't
-- audited yet. Sums housing + tavern + base.
CREATE OR REPLACE FUNCTION public._pp_compute_worker_supply(p_uid uuid)
RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  RETURN 5 + public._pp_housing_supply(p_uid) + public._pp_tavern_bonus(p_uid);
END;
$$;

-- ── 2. Staffing ──
CREATE OR REPLACE FUNCTION public._pp_staff_buildings(
  p_uid uuid,
  p_supply integer,
  OUT staffed_ids uuid[],
  OUT workers_needed integer,
  OUT unstaffed_count integer
) RETURNS record
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_remaining integer := p_supply;
  v_b record;
BEGIN
  staffed_ids := ARRAY[]::uuid[];
  workers_needed := 0;
  unstaffed_count := 0;
  FOR v_b IN
    SELECT b.id, bt.worker_cost
    FROM public.buildings b
    JOIN public.building_types bt ON bt.key = b.building_type_key
    WHERE b.player_id = p_uid AND b.status = 'active'
      AND bt.category IN ('extractor','food_extractor','booster','processor','tax','service')
      AND public.has_road_access(p_uid, b.x, b.y)
    ORDER BY b.staffing_priority DESC, b.created_at ASC
  LOOP
    workers_needed := workers_needed + v_b.worker_cost;
    IF v_remaining >= v_b.worker_cost THEN
      staffed_ids := staffed_ids || v_b.id;
      v_remaining := v_remaining - v_b.worker_cost;
    ELSE
      unstaffed_count := unstaffed_count + 1;
    END IF;
  END LOOP;
END;
$$;

-- ── 3. Extractors ──
CREATE OR REPLACE FUNCTION public._pp_run_extractors(p_uid uuid, p_staffed_ids uuid[])
RETURNS numeric
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_now timestamptz := now();
  v_total numeric := 0;
  v_b record;
  v_elapsed numeric;
  v_path_factor numeric;
  v_boost numeric;
  v_amount numeric;
  v_canonical constant integer := 4;
BEGIN
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
    v_amount := (v_elapsed / 60.0) * v_b.output_rate * v_path_factor * v_boost;
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

-- ── 4. Food extractors ──
CREATE OR REPLACE FUNCTION public._pp_run_food_extractors(p_uid uuid, p_staffed_ids uuid[])
RETURNS numeric
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_now timestamptz := now();
  v_total numeric := 0;
  v_b record;
  v_elapsed numeric;
  v_boost numeric;
  v_amount numeric;
BEGIN
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
    v_amount := (v_elapsed / 60.0) * v_b.output_rate * v_boost;
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

-- ── 5. Boosters: stamp last_processed_at on staffed ones ──
CREATE OR REPLACE FUNCTION public._pp_bump_boosters(p_uid uuid, p_staffed_ids uuid[])
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  UPDATE public.buildings b
  SET last_processed_at = now()
  FROM public.building_types bt
  WHERE bt.key = b.building_type_key
    AND bt.category = 'booster'
    AND b.player_id = p_uid AND b.status = 'active'
    AND b.id = ANY(p_staffed_ids)
    AND b.last_processed_at <> now();
END;
$$;

-- ── 6. Processors (multi-input capable) ──
CREATE OR REPLACE FUNCTION public._pp_run_processors(p_uid uuid, p_staffed_ids uuid[])
RETURNS numeric
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_now timestamptz := now();
  v_total numeric := 0;
  v_b record;
  v_elapsed numeric;
BEGIN
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
        v_made := (v_elapsed / 60.0) * v_b.output_rate * v_progress;
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

-- ── 7. Services: consume inputs, build operating_services array ──
CREATE OR REPLACE FUNCTION public._pp_run_services(p_uid uuid, p_staffed_ids uuid[])
RETURNS uuid[]
LANGUAGE plpgsql SECURITY DEFINER AS $$
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
      v_need1 numeric := COALESCE((v_elapsed / 60.0) * v_b.input_rate,   0);
      v_need2 numeric := COALESCE((v_elapsed / 60.0) * v_b.input_rate_2, 0);
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
$$;

-- ── 8. Tax revenue ──
CREATE OR REPLACE FUNCTION public._pp_run_tax(p_uid uuid, p_staffed_ids uuid[])
RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_now timestamptz := now();
  v_total integer := 0;
  v_b record;
  v_elapsed numeric;
  v_amt numeric;
BEGIN
  FOR v_b IN
    SELECT b.id, b.last_processed_at, bt.output_rate
    FROM public.buildings b
    JOIN public.building_types bt ON bt.key = b.building_type_key
    WHERE b.player_id = p_uid AND b.status = 'active' AND bt.category = 'tax'
      AND b.id = ANY(p_staffed_ids)
    FOR UPDATE OF b
  LOOP
    v_elapsed := EXTRACT(EPOCH FROM (v_now - v_b.last_processed_at));
    v_amt := FLOOR((v_elapsed / 60.0) * v_b.output_rate);
    IF v_amt > 0 THEN
      UPDATE public.player_profiles SET money = money + v_amt::integer WHERE id = p_uid;
      v_total := v_total + v_amt::integer;
    END IF;
    UPDATE public.buildings SET last_processed_at = v_now WHERE id = v_b.id;
  END LOOP;
  RETURN v_total;
END;
$$;

-- ── 9. Housing food drain ──
CREATE OR REPLACE FUNCTION public._pp_drain_housing_food(p_uid uuid)
RETURNS numeric
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_now timestamptz := now();
  v_elapsed numeric;
  v_rate numeric := 0;
  v_needed numeric := 0;
  v_avail numeric := 0;
  v_drain numeric := 0;
  v_factor numeric := 1;
  v_drained numeric := 0;
BEGIN
  SELECT EXTRACT(EPOCH FROM (v_now - last_food_tick_at)) INTO v_elapsed
  FROM public.player_profiles WHERE id = p_uid;
  IF v_elapsed IS NULL OR v_elapsed < 0 THEN v_elapsed := 0; END IF;

  SELECT COALESCE(SUM(htc.food_per_minute), 0) INTO v_rate
  FROM public.buildings b
  JOIN public.building_types bt ON bt.key = b.building_type_key
  JOIN public.housing_tier_config htc ON htc.tier = b.housing_tier
  WHERE b.player_id = p_uid AND b.status = 'active' AND bt.category = 'housing'
    AND htc.food_per_minute > 0;

  v_needed := (v_elapsed / 60.0) * v_rate;

  IF v_needed > 0 THEN
    SELECT COALESCE(SUM(i.quantity), 0) INTO v_avail
    FROM public.inventories i
    JOIN public.resources r ON r.key = i.resource_key
    WHERE i.player_id = p_uid AND r.is_food;

    IF v_avail > 0 THEN
      v_drain := LEAST(v_needed, v_avail);
      v_factor := 1.0 - (v_drain / v_avail);
      UPDATE public.inventories i
      SET quantity = i.quantity * v_factor
      FROM public.resources r
      WHERE i.resource_key = r.key AND r.is_food
        AND i.player_id = p_uid;
      v_drained := v_drain;
    END IF;
  END IF;

  UPDATE public.player_profiles SET last_food_tick_at = v_now WHERE id = p_uid;
  RETURN v_drained;
END;
$$;

-- ── 10. Housing evolution (upgrade / devolve per house) ──
CREATE OR REPLACE FUNCTION public._pp_evolve_housing(p_uid uuid, p_operating_services uuid[])
RETURNS json[]
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_now timestamptz := now();
  v_events json[] := ARRAY[]::json[];
  v_house record;
  v_cur_tier record;
  v_next_tier record;
  v_prev_tier record;
  v_elapsed numeric;
  v_has_road boolean;
  v_has_well boolean;
  v_has_school boolean;
  v_has_temple boolean;
  v_has_bathhouse boolean;
  v_has_food boolean;
  v_has_luxury_food boolean;
  v_has_industrial_luxury boolean;
  v_has_all_industrial_luxuries boolean;
  v_il_count integer;
  v_il_total integer;
  v_should_upgrade boolean;
  v_should_devolve boolean;
BEGIN
  -- Player-wide food/luxury booleans (post-drain).
  SELECT EXISTS (
    SELECT 1 FROM public.inventories i
    JOIN public.resources r ON r.key = i.resource_key
    WHERE i.player_id = p_uid AND r.is_food AND i.quantity > 0
  ) INTO v_has_food;

  SELECT EXISTS (
    SELECT 1 FROM public.inventories i
    JOIN public.resources r ON r.key = i.resource_key
    WHERE i.player_id = p_uid AND r.is_luxury_food AND i.quantity > 0
  ) INTO v_has_luxury_food;

  SELECT EXISTS (
    SELECT 1 FROM public.inventories i
    JOIN public.resources r ON r.key = i.resource_key
    WHERE i.player_id = p_uid AND r.is_industrial_luxury AND i.quantity > 0
  ) INTO v_has_industrial_luxury;

  SELECT COUNT(*) INTO v_il_count
  FROM public.inventories i
  JOIN public.resources r ON r.key = i.resource_key
  WHERE i.player_id = p_uid AND r.is_industrial_luxury AND i.quantity > 0;

  SELECT COUNT(*) INTO v_il_total
  FROM public.resources WHERE is_industrial_luxury;

  v_has_all_industrial_luxuries := (v_il_total > 0 AND v_il_count >= v_il_total);

  FOR v_house IN
    SELECT b.id, b.x, b.y, b.housing_tier, b.last_processed_at
    FROM public.buildings b
    JOIN public.building_types bt ON bt.key = b.building_type_key
    WHERE b.player_id = p_uid AND b.status = 'active' AND bt.category = 'housing'
    FOR UPDATE OF b
  LOOP
    SELECT * INTO v_cur_tier  FROM public.housing_tier_config WHERE tier = v_house.housing_tier;
    SELECT * INTO v_next_tier FROM public.housing_tier_config WHERE tier = v_house.housing_tier + 1;
    SELECT * INTO v_prev_tier FROM public.housing_tier_config WHERE tier = v_house.housing_tier - 1;
    v_elapsed := EXTRACT(EPOCH FROM (v_now - v_house.last_processed_at));
    v_has_road := public.has_road_access(p_uid, v_house.x, v_house.y);
    v_has_well := public.has_well_access(p_uid, v_house.x, v_house.y);
    v_has_school := EXISTS (
      SELECT 1 FROM public.buildings b2
      WHERE b2.player_id = p_uid AND b2.building_type_key = 'school'
        AND b2.id = ANY(p_operating_services)
        AND ABS(b2.x - v_house.x) + ABS(b2.y - v_house.y) <= 5);
    v_has_temple := EXISTS (
      SELECT 1 FROM public.buildings b2
      WHERE b2.player_id = p_uid AND b2.building_type_key = 'temple'
        AND b2.id = ANY(p_operating_services)
        AND ABS(b2.x - v_house.x) + ABS(b2.y - v_house.y) <= 6);
    v_has_bathhouse := EXISTS (
      SELECT 1 FROM public.buildings b2
      WHERE b2.player_id = p_uid AND b2.building_type_key = 'bathhouse'
        AND b2.id = ANY(p_operating_services)
        AND ABS(b2.x - v_house.x) + ABS(b2.y - v_house.y) <= 4);

    v_should_upgrade := v_next_tier IS NOT NULL
      AND v_elapsed >= COALESCE(v_cur_tier.upgrade_secs, 60)
      AND (NOT v_next_tier.needs_road OR v_has_road)
      AND (NOT v_next_tier.needs_well OR v_has_well)
      AND (NOT v_next_tier.needs_food OR v_has_food)
      AND (NOT v_next_tier.needs_school OR v_has_school)
      AND (NOT v_next_tier.needs_temple OR v_has_temple)
      AND (NOT v_next_tier.needs_luxury_food OR v_has_luxury_food)
      AND (NOT v_next_tier.needs_industrial_luxury OR v_has_industrial_luxury)
      AND (NOT v_next_tier.needs_all_industrial_luxuries OR v_has_all_industrial_luxuries);

    v_should_devolve := v_prev_tier IS NOT NULL
      AND ((v_cur_tier.needs_road AND NOT v_has_road)
           OR (v_cur_tier.needs_well AND NOT v_has_well)
           OR (v_cur_tier.needs_food AND NOT v_has_food)
           OR (v_cur_tier.needs_school AND NOT v_has_school)
           OR (v_cur_tier.needs_temple AND NOT v_has_temple)
           OR (v_cur_tier.needs_luxury_food AND NOT v_has_luxury_food)
           OR (v_cur_tier.needs_industrial_luxury AND NOT v_has_industrial_luxury)
           OR (v_cur_tier.needs_all_industrial_luxuries AND NOT v_has_all_industrial_luxuries))
      AND NOT v_has_bathhouse
      AND v_elapsed >= COALESCE(v_cur_tier.devolve_secs, 30);

    IF v_should_upgrade THEN
      UPDATE public.buildings SET housing_tier = housing_tier + 1, last_processed_at = v_now
      WHERE id = v_house.id;
      v_events := v_events || jsonb_build_object(
        'building_id', v_house.id, 'event', 'upgrade',
        'from_tier', v_house.housing_tier, 'to_tier', v_house.housing_tier + 1
      )::json;
    ELSIF v_should_devolve THEN
      UPDATE public.buildings SET housing_tier = housing_tier - 1, last_processed_at = v_now
      WHERE id = v_house.id;
      v_events := v_events || jsonb_build_object(
        'building_id', v_house.id, 'event', 'devolve',
        'from_tier', v_house.housing_tier, 'to_tier', v_house.housing_tier - 1
      )::json;
    END IF;
  END LOOP;
  RETURN v_events;
END;
$$;

-- ── 11. Orchestrator ──
CREATE OR REPLACE FUNCTION public.process_production()
RETURNS json
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_base constant integer := 5;
  v_tavern_bonus integer;
  v_supply integer;
  v_staffing record;
  v_total_produced numeric := 0;
  v_total_money integer := 0;
  v_food_drained numeric := 0;
  v_evolution_events json[];
  v_operating_services uuid[];
  v_partial numeric;
BEGIN
  -- Capture tavern bonus ONCE up front. The service loop will update
  -- the tavern's last_processed_at, so re-evaluating this at the end
  -- would always succeed (zero elapsed → zero need → trivially met).
  v_tavern_bonus := public._pp_tavern_bonus(v_uid);
  v_supply := v_base + public._pp_housing_supply(v_uid) + v_tavern_bonus;

  SELECT staffed_ids, workers_needed, unstaffed_count
    INTO v_staffing
    FROM public._pp_staff_buildings(v_uid, v_supply);

  v_partial := public._pp_run_extractors(v_uid, v_staffing.staffed_ids);
  v_total_produced := v_total_produced + v_partial;
  v_partial := public._pp_run_food_extractors(v_uid, v_staffing.staffed_ids);
  v_total_produced := v_total_produced + v_partial;
  PERFORM public._pp_bump_boosters(v_uid, v_staffing.staffed_ids);
  v_partial := public._pp_run_processors(v_uid, v_staffing.staffed_ids);
  v_total_produced := v_total_produced + v_partial;

  v_operating_services := public._pp_run_services(v_uid, v_staffing.staffed_ids);
  v_total_money := public._pp_run_tax(v_uid, v_staffing.staffed_ids);

  v_food_drained := public._pp_drain_housing_food(v_uid);

  v_evolution_events := public._pp_evolve_housing(v_uid, v_operating_services);

  -- Re-evaluate housing only (tier may have changed via evolution);
  -- reuse the start-of-tick tavern bonus.
  v_supply := v_base + public._pp_housing_supply(v_uid) + v_tavern_bonus;
  UPDATE public.player_profiles
  SET worker_capacity = v_supply,
      workers_used = LEAST(v_supply, v_staffing.workers_needed)
  WHERE id = v_uid;

  RETURN json_build_object(
    'total_produced', v_total_produced,
    'total_money_collected', v_total_money,
    'food_drained', v_food_drained,
    'evolution_events', array_to_json(v_evolution_events),
    'worker_supply', v_supply,
    'workers_needed', v_staffing.workers_needed,
    'unstaffed_count', v_staffing.unstaffed_count
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.process_production() TO authenticated;
