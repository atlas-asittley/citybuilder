-- More housing tiers: Mansion (6), Estate (7), Palace (8). Uses the
-- luxury foods (spirits/caviar/spices/ale) and industrial luxuries
-- (cabinets/monuments/mosaics/machinery) shipped in Phases B and C2 as
-- escalating prereqs.
--
-- Schema additions:
--   resources.is_luxury_food        — spirits/caviar/spices/ale
--   resources.is_industrial_luxury  — cabinets/monuments/mosaics/machinery
--   housing_tier_config.needs_luxury_food                — tier 6+
--   housing_tier_config.needs_industrial_luxury          — tier 7+
--   housing_tier_config.needs_all_industrial_luxuries    — tier 8 only
--
-- New tiers (cumulative on top of existing road/well/food/school/temple):
--   6 Mansion:  50w, +luxury_food
--   7 Estate:   70w, +industrial_luxury (any of the 4)
--   8 Palace:  100w, +all_industrial_luxuries (all 4 in stock at once →
--                    forces a fully-traded city)
--
-- The "all 4 industrial luxuries" gate is checked by counting how many
-- distinct is_industrial_luxury resources have quantity > 0 in inventory
-- and comparing against COUNT(*) of is_industrial_luxury resources —
-- generalizes if more industrial luxuries get added later.
--
-- Apply: psql "$DB_URL" -f more_housing_tiers.sql

-- ── 1. Resource flags ──
ALTER TABLE public.resources
  ADD COLUMN IF NOT EXISTS is_luxury_food boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS is_industrial_luxury boolean NOT NULL DEFAULT false;

UPDATE public.resources SET is_luxury_food = true
  WHERE key IN ('spirits', 'caviar', 'spices', 'ale');
UPDATE public.resources SET is_industrial_luxury = true
  WHERE key IN ('cabinets', 'monuments', 'mosaics', 'machinery');

-- ── 2. Housing tier prereq columns ──
ALTER TABLE public.housing_tier_config
  ADD COLUMN IF NOT EXISTS needs_luxury_food boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS needs_industrial_luxury boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS needs_all_industrial_luxuries boolean NOT NULL DEFAULT false;

-- ── 3. Insert tier rows 6, 7, 8 ──
-- Cumulative prereq pattern matches tier 5 (road/well/food/school/temple
-- all true) plus the new luxury gates.
INSERT INTO public.housing_tier_config
  (tier, name, label, workers, needs_road, upgrade_secs, devolve_secs,
   needs_well, needs_school, needs_temple, needs_food, food_per_minute,
   needs_luxury_food, needs_industrial_luxury, needs_all_industrial_luxuries)
VALUES
  (6, 'Mansion', 'Mn', 50,  true, 480, 180, true, true, true, true, 0.40,
   true, false, false),
  (7, 'Estate',  'E',  70,  true, 720, 240, true, true, true, true, 0.60,
   true, true,  false),
  (8, 'Palace',  'P', 100,  true, 1200, 300, true, true, true, true, 0.90,
   true, true,  true)
ON CONFLICT (tier) DO UPDATE SET
  name = EXCLUDED.name, label = EXCLUDED.label, workers = EXCLUDED.workers,
  needs_road = EXCLUDED.needs_road, upgrade_secs = EXCLUDED.upgrade_secs,
  devolve_secs = EXCLUDED.devolve_secs,
  needs_well = EXCLUDED.needs_well, needs_school = EXCLUDED.needs_school,
  needs_temple = EXCLUDED.needs_temple, needs_food = EXCLUDED.needs_food,
  food_per_minute = EXCLUDED.food_per_minute,
  needs_luxury_food = EXCLUDED.needs_luxury_food,
  needs_industrial_luxury = EXCLUDED.needs_industrial_luxury,
  needs_all_industrial_luxuries = EXCLUDED.needs_all_industrial_luxuries;

-- ── 4. process_production: check new prereqs in housing eval ──
CREATE OR REPLACE FUNCTION public.process_production()
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_now timestamptz := now();
  v_total_produced numeric := 0;
  v_evolution_events json[] := ARRAY[]::json[];
  v_total_money_collected integer := 0;
  v_base_workers constant integer := 5;
  v_housing_workers integer := 0;
  v_worker_supply integer := 0;
  v_workers_needed integer := 0;
  v_workers_remaining integer := 0;
  v_staffed_ids uuid[];
  v_unstaffed_count integer := 0;
  v_operating_services uuid[] := ARRAY[]::uuid[];
  v_tavern_bonus integer := 0;
  v_has_food boolean := false;
  v_has_luxury_food boolean := false;
  v_has_industrial_luxury boolean := false;
  v_has_all_industrial_luxuries boolean := false;
  v_food_elapsed_secs numeric := 0;
  v_food_rate numeric := 0;
  v_food_needed numeric := 0;
  v_food_avail numeric := 0;
  v_food_drain numeric := 0;
  v_food_factor numeric := 1;
  v_total_food_drained numeric := 0;
  v_building record;
  v_elapsed_secs numeric;
  v_amount numeric;
  v_house record;
  v_cur_tier record;
  v_next_tier record;
  v_prev_tier record;
  v_has_road boolean;
  v_has_well boolean;
  v_has_school boolean;
  v_has_temple boolean;
  v_has_bathhouse boolean;
  v_should_upgrade boolean;
  v_should_devolve boolean;
  v_canonical_path integer := 4;
  v_path_factor numeric;
  v_boost numeric;
  v_industrial_luxury_count integer;
  v_industrial_luxury_total integer;
BEGIN
  SELECT COALESCE(SUM(htc.workers), 0) INTO v_housing_workers
  FROM public.buildings b
  JOIN public.building_types bt ON bt.key = b.building_type_key
  JOIN public.housing_tier_config htc ON htc.tier = b.housing_tier
  WHERE b.player_id = v_uid AND b.status = 'active' AND bt.category = 'housing'
    AND (NOT htc.needs_road OR public.has_road_access(v_uid, b.x, b.y))
    AND (NOT htc.needs_well OR public.has_well_access(v_uid, b.x, b.y));

  SELECT COALESCE(SUM(bt.output_rate), 0)::integer INTO v_tavern_bonus
  FROM public.buildings b
  JOIN public.building_types bt ON bt.key = b.building_type_key
  WHERE b.player_id = v_uid AND b.status = 'active' AND bt.key = 'tavern'
    AND public.has_road_access(v_uid, b.x, b.y)
    AND COALESCE(
          (SELECT i.quantity FROM public.inventories i
            WHERE i.player_id = v_uid AND i.resource_key = bt.input_resource_key), 0)
        >= ((EXTRACT(EPOCH FROM (v_now - b.last_processed_at)) / 60.0) * bt.input_rate)
    AND COALESCE(
          (SELECT i.quantity FROM public.inventories i
            WHERE i.player_id = v_uid AND i.resource_key = bt.input_resource_key_2), 0)
        >= ((EXTRACT(EPOCH FROM (v_now - b.last_processed_at)) / 60.0) * bt.input_rate_2);

  v_worker_supply := v_base_workers + v_housing_workers + v_tavern_bonus;
  v_workers_remaining := v_worker_supply;
  v_staffed_ids := ARRAY[]::uuid[];

  FOR v_building IN
    SELECT b.id, bt.worker_cost
    FROM public.buildings b
    JOIN public.building_types bt ON bt.key = b.building_type_key
    WHERE b.player_id = v_uid AND b.status = 'active'
      AND (
        bt.category = 'extractor'
        OR bt.category = 'food_extractor'
        OR bt.category = 'booster'
        OR (bt.category = 'processor' AND public.has_road_access(v_uid, b.x, b.y))
        OR (bt.category = 'tax'       AND public.has_road_access(v_uid, b.x, b.y))
        OR (bt.category = 'service'   AND public.has_road_access(v_uid, b.x, b.y))
      )
    ORDER BY b.staffing_priority DESC, b.created_at ASC
  LOOP
    v_workers_needed := v_workers_needed + v_building.worker_cost;
    IF v_workers_remaining >= v_building.worker_cost THEN
      v_staffed_ids := v_staffed_ids || v_building.id;
      v_workers_remaining := v_workers_remaining - v_building.worker_cost;
    ELSE
      v_unstaffed_count := v_unstaffed_count + 1;
    END IF;
  END LOOP;

  -- Extractors
  FOR v_building IN
    SELECT b.id, b.x, b.y, b.last_processed_at, b.path_length,
           bt.output_resource_key, bt.output_rate
    FROM public.buildings b
    JOIN public.building_types bt ON bt.key = b.building_type_key
    WHERE b.player_id = v_uid AND b.status = 'active' AND bt.category = 'extractor'
      AND b.id = ANY(v_staffed_ids)
    FOR UPDATE OF b
  LOOP
    IF v_building.path_length IS NULL THEN
      UPDATE public.buildings SET last_processed_at = v_now WHERE id = v_building.id;
      CONTINUE;
    END IF;
    v_elapsed_secs := EXTRACT(EPOCH FROM (v_now - v_building.last_processed_at));
    v_path_factor := LEAST(1.0, v_canonical_path::numeric / v_building.path_length);
    SELECT COALESCE(MAX(bt2.boost_multiplier), 1.0) INTO v_boost
    FROM public.buildings b2
    JOIN public.building_types bt2 ON bt2.key = b2.building_type_key
    WHERE b2.player_id = v_uid AND b2.status = 'active'
      AND bt2.category = 'booster'
      AND bt2.boost_target = 'extractor'
      AND b2.id = ANY(v_staffed_ids)
      AND ABS(b2.x - v_building.x) + ABS(b2.y - v_building.y) <= bt2.boost_range;
    v_amount := (v_elapsed_secs / 60.0) * v_building.output_rate * v_path_factor * v_boost;
    IF v_amount > 0 THEN
      INSERT INTO public.inventories (player_id, resource_key, quantity)
      VALUES (v_uid, v_building.output_resource_key, v_amount)
      ON CONFLICT (player_id, resource_key)
      DO UPDATE SET quantity = inventories.quantity + EXCLUDED.quantity;
      v_total_produced := v_total_produced + v_amount;
    END IF;
    UPDATE public.buildings SET last_processed_at = v_now WHERE id = v_building.id;
  END LOOP;

  -- Food extractors
  FOR v_building IN
    SELECT b.id, b.x, b.y, b.last_processed_at,
           bt.output_resource_key, bt.output_rate
    FROM public.buildings b
    JOIN public.building_types bt ON bt.key = b.building_type_key
    WHERE b.player_id = v_uid AND b.status = 'active' AND bt.category = 'food_extractor'
      AND b.id = ANY(v_staffed_ids)
    FOR UPDATE OF b
  LOOP
    v_elapsed_secs := EXTRACT(EPOCH FROM (v_now - v_building.last_processed_at));
    SELECT COALESCE(MAX(bt2.boost_multiplier), 1.0) INTO v_boost
    FROM public.buildings b2
    JOIN public.building_types bt2 ON bt2.key = b2.building_type_key
    WHERE b2.player_id = v_uid AND b2.status = 'active'
      AND bt2.category = 'booster'
      AND bt2.boost_target = 'food_extractor'
      AND b2.id = ANY(v_staffed_ids)
      AND ABS(b2.x - v_building.x) + ABS(b2.y - v_building.y) <= bt2.boost_range;
    v_amount := (v_elapsed_secs / 60.0) * v_building.output_rate * v_boost;
    IF v_amount > 0 THEN
      INSERT INTO public.inventories (player_id, resource_key, quantity)
      VALUES (v_uid, v_building.output_resource_key, v_amount)
      ON CONFLICT (player_id, resource_key)
      DO UPDATE SET quantity = inventories.quantity + EXCLUDED.quantity;
      v_total_produced := v_total_produced + v_amount;
    END IF;
    UPDATE public.buildings SET last_processed_at = v_now WHERE id = v_building.id;
  END LOOP;

  -- Boosters: just bump last_processed_at on staffed ones.
  UPDATE public.buildings b
  SET last_processed_at = v_now
  FROM public.building_types bt
  WHERE bt.key = b.building_type_key
    AND bt.category = 'booster'
    AND b.player_id = v_uid AND b.status = 'active'
    AND b.id = ANY(v_staffed_ids)
    AND b.last_processed_at <> v_now;

  -- Processors (multi-input capable)
  FOR v_building IN
    SELECT b.id, b.last_processed_at,
           bt.input_resource_key, bt.input_rate,
           bt.input_resource_key_2, bt.input_rate_2,
           bt.output_resource_key, bt.output_rate
    FROM public.buildings b
    JOIN public.building_types bt ON bt.key = b.building_type_key
    WHERE b.player_id = v_uid AND b.status = 'active' AND bt.category = 'processor'
      AND b.id = ANY(v_staffed_ids)
    FOR UPDATE OF b
  LOOP
    v_elapsed_secs := EXTRACT(EPOCH FROM (v_now - v_building.last_processed_at));
    DECLARE
      v_need1 numeric := COALESCE((v_elapsed_secs / 60.0) * v_building.input_rate,   0);
      v_need2 numeric := COALESCE((v_elapsed_secs / 60.0) * v_building.input_rate_2, 0);
      v_avail1 numeric := 0;
      v_avail2 numeric := 0;
      v_used1 numeric := 0;
      v_used2 numeric := 0;
      v_progress numeric := 1;
      v_output_made numeric := 0;
    BEGIN
      IF v_building.input_resource_key IS NOT NULL THEN
        SELECT COALESCE(quantity, 0) INTO v_avail1
        FROM public.inventories
        WHERE player_id = v_uid AND resource_key = v_building.input_resource_key;
      END IF;
      IF v_building.input_resource_key_2 IS NOT NULL THEN
        SELECT COALESCE(quantity, 0) INTO v_avail2
        FROM public.inventories
        WHERE player_id = v_uid AND resource_key = v_building.input_resource_key_2;
      END IF;

      IF v_need1 > 0 THEN
        v_progress := LEAST(v_progress, v_avail1 / v_need1);
      END IF;
      IF v_need2 > 0 THEN
        v_progress := LEAST(v_progress, v_avail2 / v_need2);
      END IF;
      v_progress := GREATEST(0, v_progress);

      IF v_progress > 0 THEN
        IF v_need1 > 0 AND v_building.input_resource_key IS NOT NULL THEN
          v_used1 := v_need1 * v_progress;
          UPDATE public.inventories SET quantity = quantity - v_used1
          WHERE player_id = v_uid AND resource_key = v_building.input_resource_key;
        END IF;
        IF v_need2 > 0 AND v_building.input_resource_key_2 IS NOT NULL THEN
          v_used2 := v_need2 * v_progress;
          UPDATE public.inventories SET quantity = quantity - v_used2
          WHERE player_id = v_uid AND resource_key = v_building.input_resource_key_2;
        END IF;
        v_output_made := (v_elapsed_secs / 60.0) * v_building.output_rate * v_progress;
        IF v_output_made > 0 AND v_building.output_resource_key IS NOT NULL THEN
          INSERT INTO public.inventories (player_id, resource_key, quantity)
          VALUES (v_uid, v_building.output_resource_key, v_output_made)
          ON CONFLICT (player_id, resource_key)
          DO UPDATE SET quantity = inventories.quantity + EXCLUDED.quantity;
          v_total_produced := v_total_produced + v_output_made;
        END IF;
      END IF;
      UPDATE public.buildings SET last_processed_at = v_now WHERE id = v_building.id;
    END;
  END LOOP;

  -- Services
  FOR v_building IN
    SELECT b.id, b.last_processed_at, b.building_type_key,
           bt.input_resource_key, bt.input_rate,
           bt.input_resource_key_2, bt.input_rate_2,
           bt.output_rate
    FROM public.buildings b
    JOIN public.building_types bt ON bt.key = b.building_type_key
    WHERE b.player_id = v_uid AND b.status = 'active' AND bt.category = 'service'
      AND b.id = ANY(v_staffed_ids)
    FOR UPDATE OF b
  LOOP
    v_elapsed_secs := EXTRACT(EPOCH FROM (v_now - v_building.last_processed_at));
    DECLARE
      v_need1 numeric := COALESCE((v_elapsed_secs / 60.0) * v_building.input_rate,   0);
      v_need2 numeric := COALESCE((v_elapsed_secs / 60.0) * v_building.input_rate_2, 0);
      v_avail1 numeric := 0;
      v_avail2 numeric := 0;
      v_operating boolean;
    BEGIN
      IF v_building.input_resource_key IS NOT NULL THEN
        SELECT COALESCE(quantity, 0) INTO v_avail1
        FROM public.inventories
        WHERE player_id = v_uid AND resource_key = v_building.input_resource_key;
      END IF;
      IF v_building.input_resource_key_2 IS NOT NULL THEN
        SELECT COALESCE(quantity, 0) INTO v_avail2
        FROM public.inventories
        WHERE player_id = v_uid AND resource_key = v_building.input_resource_key_2;
      END IF;

      v_operating :=
        (v_building.input_resource_key   IS NULL OR v_avail1 >= v_need1)
        AND
        (v_building.input_resource_key_2 IS NULL OR v_avail2 >= v_need2);

      IF v_operating THEN
        IF v_need1 > 0 AND v_building.input_resource_key IS NOT NULL THEN
          UPDATE public.inventories SET quantity = quantity - v_need1
          WHERE player_id = v_uid AND resource_key = v_building.input_resource_key;
        END IF;
        IF v_need2 > 0 AND v_building.input_resource_key_2 IS NOT NULL THEN
          UPDATE public.inventories SET quantity = quantity - v_need2
          WHERE player_id = v_uid AND resource_key = v_building.input_resource_key_2;
        END IF;
        v_operating_services := v_operating_services || v_building.id;
      END IF;
      UPDATE public.buildings SET last_processed_at = v_now WHERE id = v_building.id;
    END;
  END LOOP;

  -- Tax
  FOR v_building IN
    SELECT b.id, b.last_processed_at, bt.output_rate
    FROM public.buildings b
    JOIN public.building_types bt ON bt.key = b.building_type_key
    WHERE b.player_id = v_uid AND b.status = 'active' AND bt.category = 'tax'
      AND b.id = ANY(v_staffed_ids)
    FOR UPDATE OF b
  LOOP
    v_elapsed_secs := EXTRACT(EPOCH FROM (v_now - v_building.last_processed_at));
    v_amount := FLOOR((v_elapsed_secs / 60.0) * v_building.output_rate);
    IF v_amount > 0 THEN
      UPDATE public.player_profiles SET money = money + v_amount::integer WHERE id = v_uid;
      v_total_money_collected := v_total_money_collected + v_amount::integer;
    END IF;
    UPDATE public.buildings SET last_processed_at = v_now WHERE id = v_building.id;
  END LOOP;

  -- Housing food consumption
  SELECT EXTRACT(EPOCH FROM (v_now - last_food_tick_at)) INTO v_food_elapsed_secs
  FROM public.player_profiles WHERE id = v_uid;
  IF v_food_elapsed_secs IS NULL OR v_food_elapsed_secs < 0 THEN
    v_food_elapsed_secs := 0;
  END IF;

  SELECT COALESCE(SUM(htc.food_per_minute), 0) INTO v_food_rate
  FROM public.buildings b
  JOIN public.building_types bt ON bt.key = b.building_type_key
  JOIN public.housing_tier_config htc ON htc.tier = b.housing_tier
  WHERE b.player_id = v_uid AND b.status = 'active' AND bt.category = 'housing'
    AND htc.food_per_minute > 0;

  v_food_needed := (v_food_elapsed_secs / 60.0) * v_food_rate;

  IF v_food_needed > 0 THEN
    SELECT COALESCE(SUM(i.quantity), 0) INTO v_food_avail
    FROM public.inventories i
    JOIN public.resources r ON r.key = i.resource_key
    WHERE i.player_id = v_uid AND r.is_food;

    IF v_food_avail > 0 THEN
      v_food_drain := LEAST(v_food_needed, v_food_avail);
      v_food_factor := 1.0 - (v_food_drain / v_food_avail);
      UPDATE public.inventories i
      SET quantity = i.quantity * v_food_factor
      FROM public.resources r
      WHERE i.resource_key = r.key AND r.is_food
        AND i.player_id = v_uid;
      v_total_food_drained := v_food_drain;
    END IF;
  END IF;

  UPDATE public.player_profiles SET last_food_tick_at = v_now WHERE id = v_uid;

  -- Compute housing-eval prereq booleans (post-drain)
  SELECT EXISTS (
    SELECT 1 FROM public.inventories i
    JOIN public.resources r ON r.key = i.resource_key
    WHERE i.player_id = v_uid AND r.is_food AND i.quantity > 0
  ) INTO v_has_food;

  SELECT EXISTS (
    SELECT 1 FROM public.inventories i
    JOIN public.resources r ON r.key = i.resource_key
    WHERE i.player_id = v_uid AND r.is_luxury_food AND i.quantity > 0
  ) INTO v_has_luxury_food;

  SELECT EXISTS (
    SELECT 1 FROM public.inventories i
    JOIN public.resources r ON r.key = i.resource_key
    WHERE i.player_id = v_uid AND r.is_industrial_luxury AND i.quantity > 0
  ) INTO v_has_industrial_luxury;

  -- "All industrial luxuries" = count of distinct ones in stock equals
  -- the total number of industrial luxuries defined.
  SELECT COUNT(*) INTO v_industrial_luxury_count
  FROM public.inventories i
  JOIN public.resources r ON r.key = i.resource_key
  WHERE i.player_id = v_uid AND r.is_industrial_luxury AND i.quantity > 0;

  SELECT COUNT(*) INTO v_industrial_luxury_total
  FROM public.resources WHERE is_industrial_luxury;

  v_has_all_industrial_luxuries :=
    (v_industrial_luxury_total > 0
     AND v_industrial_luxury_count >= v_industrial_luxury_total);

  -- Housing evolution
  FOR v_house IN
    SELECT b.id, b.x, b.y, b.housing_tier, b.last_processed_at
    FROM public.buildings b
    JOIN public.building_types bt ON bt.key = b.building_type_key
    WHERE b.player_id = v_uid AND b.status = 'active' AND bt.category = 'housing'
    FOR UPDATE OF b
  LOOP
    SELECT * INTO v_cur_tier  FROM public.housing_tier_config WHERE tier = v_house.housing_tier;
    SELECT * INTO v_next_tier FROM public.housing_tier_config WHERE tier = v_house.housing_tier + 1;
    SELECT * INTO v_prev_tier FROM public.housing_tier_config WHERE tier = v_house.housing_tier - 1;
    v_elapsed_secs := EXTRACT(EPOCH FROM (v_now - v_house.last_processed_at));
    v_has_road := public.has_road_access(v_uid, v_house.x, v_house.y);
    v_has_well := public.has_well_access(v_uid, v_house.x, v_house.y);
    v_has_school := EXISTS (
      SELECT 1 FROM public.buildings b2
      WHERE b2.player_id = v_uid AND b2.building_type_key = 'school'
        AND b2.id = ANY(v_operating_services)
        AND ABS(b2.x - v_house.x) + ABS(b2.y - v_house.y) <= 5);
    v_has_temple := EXISTS (
      SELECT 1 FROM public.buildings b2
      WHERE b2.player_id = v_uid AND b2.building_type_key = 'temple'
        AND b2.id = ANY(v_operating_services)
        AND ABS(b2.x - v_house.x) + ABS(b2.y - v_house.y) <= 6);
    v_has_bathhouse := EXISTS (
      SELECT 1 FROM public.buildings b2
      WHERE b2.player_id = v_uid AND b2.building_type_key = 'bathhouse'
        AND b2.id = ANY(v_operating_services)
        AND ABS(b2.x - v_house.x) + ABS(b2.y - v_house.y) <= 4);

    v_should_upgrade := v_next_tier IS NOT NULL
      AND v_elapsed_secs >= COALESCE(v_cur_tier.upgrade_secs, 60)
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
      AND v_elapsed_secs >= COALESCE(v_cur_tier.devolve_secs, 30);

    IF v_should_upgrade THEN
      UPDATE public.buildings SET housing_tier = housing_tier + 1, last_processed_at = v_now
      WHERE id = v_house.id;
      v_evolution_events := v_evolution_events || jsonb_build_object(
        'building_id', v_house.id, 'event', 'upgrade',
        'from_tier', v_house.housing_tier, 'to_tier', v_house.housing_tier + 1
      )::json;
    ELSIF v_should_devolve THEN
      UPDATE public.buildings SET housing_tier = housing_tier - 1, last_processed_at = v_now
      WHERE id = v_house.id;
      v_evolution_events := v_evolution_events || jsonb_build_object(
        'building_id', v_house.id, 'event', 'devolve',
        'from_tier', v_house.housing_tier, 'to_tier', v_house.housing_tier - 1
      )::json;
    END IF;
  END LOOP;

  SELECT 5 + COALESCE(SUM(htc.workers), 0) INTO v_worker_supply
  FROM public.buildings b
  JOIN public.building_types bt ON bt.key = b.building_type_key
  JOIN public.housing_tier_config htc ON htc.tier = b.housing_tier
  WHERE b.player_id = v_uid AND b.status = 'active' AND bt.category = 'housing'
    AND (NOT htc.needs_road OR public.has_road_access(v_uid, b.x, b.y))
    AND (NOT htc.needs_well OR public.has_well_access(v_uid, b.x, b.y));
  v_worker_supply := v_worker_supply + v_tavern_bonus;

  UPDATE public.player_profiles
  SET worker_capacity = v_worker_supply,
      workers_used = LEAST(v_worker_supply, v_workers_needed)
  WHERE id = v_uid;

  RETURN json_build_object(
    'total_produced', v_total_produced,
    'total_money_collected', v_total_money_collected,
    'food_drained', v_total_food_drained,
    'evolution_events', array_to_json(v_evolution_events),
    'worker_supply', v_worker_supply,
    'workers_needed', v_workers_needed,
    'unstaffed_count', v_unstaffed_count
  );
END;
$function$;
