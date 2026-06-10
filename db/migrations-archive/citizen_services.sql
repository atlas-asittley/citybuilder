-- Four new citizen-job buildings, each consuming a unique pair of resources
-- to force inter-player trade.
--
--   tavern    (service): bread + pottery → +10 flat worker capacity
--   bathhouse (service): brick + clay    → housing within 4 tiles won't devolve
--   school    (service): lumber + flour  → gates Townhouse (tier 3+) within 5
--   temple    (service): statuary + brick→ gates Villa (tier 4+) within 6
--
-- A service is "operating" only when it is staffed AND both inputs are
-- currently available. Drop either input → houses can devolve, tavern
-- bonus disappears, school/temple gates close. This is the trade-pressure
-- knob: stop trading and your city contracts.
--
-- Apply: psql "$DB_URL" -f citizen_services.sql

-- ── 0. Schema: second-input columns + new housing tier gates ──
ALTER TABLE public.building_types
  ADD COLUMN IF NOT EXISTS input_resource_key_2 text,
  ADD COLUMN IF NOT EXISTS input_rate_2 numeric NOT NULL DEFAULT 0;

ALTER TABLE public.housing_tier_config
  ADD COLUMN IF NOT EXISTS needs_school boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS needs_temple boolean NOT NULL DEFAULT false;

UPDATE public.housing_tier_config SET needs_school = true WHERE tier >= 3;
UPDATE public.housing_tier_config SET needs_temple = true WHERE tier >= 4;

-- ── 1. building_types rows ──
-- worker_cost = 5 (mid; bigger than well's 3, smaller than processor's 10)
-- worker_cost = 10 for school/temple (high-tier civic buildings)
-- output_rate carries the worker bonus for tavern; otherwise 0.
INSERT INTO public.building_types
  (key, name, tier, industry_key, category, build_cost, worker_cost,
   input_resource_key, input_rate, input_resource_key_2, input_rate_2,
   output_resource_key, output_rate, is_active, workers_provided)
VALUES
  ('tavern',    'Tavern',    2, 'common', 'service', 350, 5,
   'bread',    0.5, 'pottery', 0.5, NULL, 10, true, 0),
  ('bathhouse', 'Bathhouse', 2, 'common', 'service', 300, 5,
   'brick',    0.5, 'clay',    0.5, NULL, 0,  true, 0),
  ('school',    'School',    3, 'common', 'service', 600, 10,
   'lumber',   0.3, 'flour',   0.3, NULL, 0,  true, 0),
  ('temple',    'Temple',    3, 'common', 'service', 800, 10,
   'statuary', 0.25,'brick',   0.5, NULL, 0,  true, 0)
ON CONFLICT (key) DO UPDATE SET
  name = EXCLUDED.name,
  tier = EXCLUDED.tier,
  industry_key = EXCLUDED.industry_key,
  category = EXCLUDED.category,
  build_cost = EXCLUDED.build_cost,
  worker_cost = EXCLUDED.worker_cost,
  input_resource_key = EXCLUDED.input_resource_key,
  input_rate = EXCLUDED.input_rate,
  input_resource_key_2 = EXCLUDED.input_resource_key_2,
  input_rate_2 = EXCLUDED.input_rate_2,
  output_resource_key = EXCLUDED.output_resource_key,
  output_rate = EXCLUDED.output_rate,
  is_active = EXCLUDED.is_active;

-- ── 2. process_production: feed services + apply effects ──
-- Service buildings now charge two inputs and only "operate" if staffed
-- AND both inputs were available. The set of operating service ids drives:
--   - tavern: +output_rate to worker supply
--   - bathhouse: blocks housing devolve in a 4-tile radius
--   - school: gates housing tier 3+ in a 5-tile radius
--   - temple: gates housing tier 4+ in a 6-tile radius
-- Well's existing gate (tier 1+, 4-tile radius) is unchanged.
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
BEGIN
  SELECT COALESCE(SUM(htc.workers), 0) INTO v_housing_workers
  FROM public.buildings b
  JOIN public.building_types bt ON bt.key = b.building_type_key
  JOIN public.housing_tier_config htc ON htc.tier = b.housing_tier
  WHERE b.player_id = v_uid AND b.status = 'active' AND bt.category = 'housing'
    AND (NOT htc.needs_road OR public.has_road_access(v_uid, b.x, b.y))
    AND (NOT htc.needs_well OR public.has_well_access(v_uid, b.x, b.y));

  v_worker_supply := v_base_workers + v_housing_workers;
  v_workers_remaining := v_worker_supply;
  v_staffed_ids := ARRAY[]::uuid[];

  FOR v_building IN
    SELECT b.id, bt.worker_cost
    FROM public.buildings b
    JOIN public.building_types bt ON bt.key = b.building_type_key
    WHERE b.player_id = v_uid AND b.status = 'active'
      AND (
        bt.category = 'extractor'
        OR (bt.category = 'processor' AND public.has_road_access(v_uid, b.x, b.y))
        OR (bt.category = 'tax'       AND public.has_road_access(v_uid, b.x, b.y))
        OR (bt.category = 'service'   AND public.has_road_access(v_uid, b.x, b.y))
      )
    ORDER BY b.created_at ASC
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
    SELECT b.id, b.last_processed_at, b.path_length,
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
    v_amount := (v_elapsed_secs / 60.0) * v_building.output_rate * v_path_factor;
    IF v_amount > 0 THEN
      INSERT INTO public.inventories (player_id, resource_key, quantity)
      VALUES (v_uid, v_building.output_resource_key, v_amount)
      ON CONFLICT (player_id, resource_key)
      DO UPDATE SET quantity = inventories.quantity + EXCLUDED.quantity;
      v_total_produced := v_total_produced + v_amount;
    END IF;
    UPDATE public.buildings SET last_processed_at = v_now WHERE id = v_building.id;
  END LOOP;

  -- Processors
  FOR v_building IN
    SELECT b.id, b.last_processed_at, b.stored_input,
           bt.input_resource_key, bt.input_rate,
           bt.output_resource_key, bt.output_rate
    FROM public.buildings b
    JOIN public.building_types bt ON bt.key = b.building_type_key
    WHERE b.player_id = v_uid AND b.status = 'active' AND bt.category = 'processor'
      AND b.id = ANY(v_staffed_ids)
    FOR UPDATE OF b
  LOOP
    v_elapsed_secs := EXTRACT(EPOCH FROM (v_now - v_building.last_processed_at));
    DECLARE
      v_input_needed numeric := (v_elapsed_secs / 60.0) * v_building.input_rate;
      v_input_avail numeric;
      v_input_used numeric;
      v_output_made numeric;
    BEGIN
      SELECT COALESCE(quantity, 0) INTO v_input_avail
      FROM public.inventories
      WHERE player_id = v_uid AND resource_key = v_building.input_resource_key;
      v_input_used := LEAST(v_input_needed, COALESCE(v_input_avail, 0));
      IF v_input_used > 0 THEN
        UPDATE public.inventories SET quantity = quantity - v_input_used
        WHERE player_id = v_uid AND resource_key = v_building.input_resource_key;
        v_output_made := v_input_used * (v_building.output_rate / NULLIF(v_building.input_rate, 0));
        IF v_output_made > 0 THEN
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

  -- Services: feed both inputs proportional to elapsed time. A service
  -- "operates" (effect applies) only if it was staffed AND both inputs
  -- were fully available for the elapsed window. Wells are treated as a
  -- special case — they have no inputs (input_resource_key IS NULL) and
  -- always operate when staffed.
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
        IF v_building.building_type_key = 'tavern' THEN
          v_tavern_bonus := v_tavern_bonus + COALESCE(v_building.output_rate::integer, 0);
        END IF;
      END IF;
      UPDATE public.buildings SET last_processed_at = v_now WHERE id = v_building.id;
    END;
  END LOOP;

  -- Apply tavern bonus to worker supply (so housing evolution + tax / processor staffing
  -- in the next tick can use it; this tick's staffing already happened above).
  IF v_tavern_bonus > 0 THEN
    v_worker_supply := v_worker_supply + v_tavern_bonus;
  END IF;

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
      AND (NOT v_next_tier.needs_school OR v_has_school)
      AND (NOT v_next_tier.needs_temple OR v_has_temple);
    v_should_devolve := v_prev_tier IS NOT NULL
      AND ((v_cur_tier.needs_road AND NOT v_has_road)
           OR (v_cur_tier.needs_well AND NOT v_has_well)
           OR (v_cur_tier.needs_school AND NOT v_has_school)
           OR (v_cur_tier.needs_temple AND NOT v_has_temple))
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

  -- Re-derive supply (housing tiers may have changed); re-add tavern bonus.
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
    'evolution_events', array_to_json(v_evolution_events),
    'worker_supply', v_worker_supply,
    'workers_needed', v_workers_needed,
    'unstaffed_count', v_unstaffed_count
  );
END;
$function$;
