-- ── Per-tier housing lifestyle demands (2026-05-07) ──
-- Atlas: every resource should have a domestic destination, not just an
-- export. Currently housing only consumes food. Higher tiers gate on
-- presence (luxury_food / industrial_luxury) but don't drain.
--
-- New mechanic: each housing tier above Mud Hut wants ongoing
-- consumption of one specific lifestyle good. Goods come from various
-- industries, so a clay player still benefits from buying timber's
-- furniture and stone's statuary. Goods ARE drained each tick. If
-- inventory hits 0 for a tier's required lifestyle good, the house
-- starts to devolve next tick.
--
-- Demands per tier (one resource each — keeps things tractable):
--   T2 Cottage    → pottery   (clay industry)
--   T3 Townhouse  → bread     (food, common via Bakery)
--   T4 Villa      → furniture (timber)
--   T5 Manor      → statuary  (stone)
-- T6+ keep their existing luxury_food / industrial_luxury gates plus
-- whatever lifestyle goods Atlas adds later.

CREATE TABLE IF NOT EXISTS public.housing_lifestyle_demands (
  tier integer NOT NULL,
  resource_key text NOT NULL REFERENCES public.resources(key) ON DELETE CASCADE,
  qty_per_minute numeric NOT NULL,
  PRIMARY KEY (tier, resource_key)
);

ALTER TABLE public.housing_lifestyle_demands ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS housing_lifestyle_demands_read ON public.housing_lifestyle_demands;
CREATE POLICY housing_lifestyle_demands_read ON public.housing_lifestyle_demands FOR SELECT USING (true);
GRANT SELECT ON public.housing_lifestyle_demands TO anon, authenticated;

INSERT INTO public.housing_lifestyle_demands (tier, resource_key, qty_per_minute) VALUES
  (2, 'pottery',   0.10),
  (3, 'bread',     0.10),
  (4, 'furniture', 0.10),
  (5, 'statuary',  0.10)
ON CONFLICT (tier, resource_key) DO UPDATE SET qty_per_minute = EXCLUDED.qty_per_minute;

-- ── Drain phase: extend _pp_drain_housing_food to also drain lifestyle goods ──
-- Reuses the same elapsed-time anchor (last_food_tick_at) so we don't
-- need a second timestamp column. Single timestamp update at the end.
CREATE OR REPLACE FUNCTION public._pp_drain_housing_food(p_uid uuid)
 RETURNS numeric
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  v_now timestamptz := now();
  v_elapsed numeric;
  v_minutes numeric;
  v_rate numeric := 0;
  v_needed numeric := 0;
  v_avail numeric := 0;
  v_drain numeric := 0;
  v_factor numeric := 1;
  v_drained numeric := 0;
  v_demand record;
  v_demand_needed numeric;
  v_demand_avail numeric;
BEGIN
  SELECT EXTRACT(EPOCH FROM (v_now - last_food_tick_at)) INTO v_elapsed
  FROM public.player_profiles WHERE id = p_uid;
  IF v_elapsed IS NULL OR v_elapsed < 0 THEN v_elapsed := 0; END IF;
  v_minutes := v_elapsed / 60.0;

  -- ── Food drain (existing) ──
  SELECT COALESCE(SUM(htc.food_per_minute), 0) INTO v_rate
  FROM public.buildings b
  JOIN public.building_types bt ON bt.key = b.building_type_key
  JOIN public.housing_tier_config htc ON htc.tier = b.housing_tier
  WHERE b.player_id = p_uid AND b.status = 'active' AND bt.category = 'housing'
    AND htc.food_per_minute > 0;

  v_needed := v_minutes * v_rate;
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

  -- ── Lifestyle goods drain (new) ──
  -- For each (resource, total_rate) demand across all the player's
  -- houses, drain qty proportional to elapsed minutes. Direct deduction
  -- per resource (no proportional split like food, since each row
  -- specifies a single resource).
  FOR v_demand IN
    SELECT hld.resource_key, SUM(hld.qty_per_minute) AS total_rate
    FROM public.buildings b
    JOIN public.building_types bt ON bt.key = b.building_type_key
    JOIN public.housing_lifestyle_demands hld ON hld.tier = b.housing_tier
    WHERE b.player_id = p_uid AND b.status = 'active' AND bt.category = 'housing'
    GROUP BY hld.resource_key
  LOOP
    v_demand_needed := v_minutes * v_demand.total_rate;
    IF v_demand_needed <= 0 THEN CONTINUE; END IF;
    SELECT COALESCE(quantity, 0) INTO v_demand_avail
    FROM public.inventories
    WHERE player_id = p_uid AND resource_key = v_demand.resource_key;
    IF v_demand_avail IS NULL OR v_demand_avail <= 0 THEN CONTINUE; END IF;
    UPDATE public.inventories
      SET quantity = GREATEST(0, quantity - v_demand_needed),
          updated_at = now()
      WHERE player_id = p_uid AND resource_key = v_demand.resource_key;
  END LOOP;

  UPDATE public.player_profiles SET last_food_tick_at = v_now WHERE id = p_uid;
  RETURN v_drained;
END;
$function$;

-- ── Evolve phase: lifestyle gate on upgrade + devolve ──
-- A house can't upgrade to a tier whose lifestyle demands aren't in
-- stock. A house at a tier whose lifestyle demand has run out
-- triggers the devolve gate (next tick after grace period).
CREATE OR REPLACE FUNCTION public._pp_evolve_housing(p_uid uuid, p_operating_services uuid[])
 RETURNS json[]
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
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
  v_has_any_well boolean;
  v_well_for_next boolean;
  v_well_for_cur boolean;
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
  v_desirability integer;
  v_skip_des boolean;
  v_in_tutorial boolean;
  v_lifestyle_for_cur_ok boolean;
  v_lifestyle_for_next_ok boolean;
BEGIN
  v_skip_des := COALESCE(current_setting('city.skip_desirability_gate', true), 'false') = 'true';

  SELECT (tutorial_step < 4) INTO v_in_tutorial
  FROM public.player_profiles WHERE id = p_uid;
  v_in_tutorial := COALESCE(v_in_tutorial, false);

  v_has_any_well := public.has_any_well(p_uid);

  SELECT EXISTS (SELECT 1 FROM public.inventories i JOIN public.resources r ON r.key = i.resource_key
                 WHERE i.player_id = p_uid AND r.is_food AND i.quantity > 0) INTO v_has_food;
  SELECT EXISTS (SELECT 1 FROM public.inventories i JOIN public.resources r ON r.key = i.resource_key
                 WHERE i.player_id = p_uid AND r.is_luxury_food AND i.quantity > 0) INTO v_has_luxury_food;
  SELECT EXISTS (SELECT 1 FROM public.inventories i JOIN public.resources r ON r.key = i.resource_key
                 WHERE i.player_id = p_uid AND r.is_industrial_luxury AND i.quantity > 0) INTO v_has_industrial_luxury;
  SELECT COUNT(*) INTO v_il_count FROM public.inventories i JOIN public.resources r ON r.key = i.resource_key
   WHERE i.player_id = p_uid AND r.is_industrial_luxury AND i.quantity > 0;
  SELECT COUNT(*) INTO v_il_total FROM public.resources WHERE is_industrial_luxury;
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
    v_has_school := EXISTS (SELECT 1 FROM public.buildings b2
      WHERE b2.player_id = p_uid AND b2.building_type_key = 'school'
        AND b2.id = ANY(p_operating_services)
        AND ABS(b2.x - v_house.x) + ABS(b2.y - v_house.y) <= 5);
    v_has_temple := EXISTS (SELECT 1 FROM public.buildings b2
      WHERE b2.player_id = p_uid AND b2.building_type_key = 'temple'
        AND b2.id = ANY(p_operating_services)
        AND ABS(b2.x - v_house.x) + ABS(b2.y - v_house.y) <= 6);
    v_has_bathhouse := EXISTS (SELECT 1 FROM public.buildings b2
      WHERE b2.player_id = p_uid AND b2.building_type_key = 'bathhouse'
        AND b2.id = ANY(p_operating_services)
        AND ABS(b2.x - v_house.x) + ABS(b2.y - v_house.y) <= 4);

    SELECT COALESCE(desirability, 50) INTO v_desirability
    FROM public.map_tiles
    WHERE x = v_house.x AND y = v_house.y AND owner_player_id = p_uid;

    v_well_for_next := CASE
      WHEN v_next_tier IS NULL THEN false
      WHEN v_next_tier.tier = 1 THEN v_has_any_well
      ELSE v_has_well
    END;
    v_well_for_cur := CASE
      WHEN v_cur_tier.tier = 1 THEN v_has_any_well
      ELSE v_has_well
    END;

    -- Lifestyle gate: each demand row for the cur/next tier requires
    -- that resource to be in stock (>0). NOT EXISTS = all demands met.
    SELECT NOT EXISTS (
      SELECT 1 FROM public.housing_lifestyle_demands hld
      WHERE hld.tier = v_house.housing_tier
        AND COALESCE((SELECT quantity FROM public.inventories i
                       WHERE i.player_id = p_uid AND i.resource_key = hld.resource_key), 0) <= 0
    ) INTO v_lifestyle_for_cur_ok;

    IF v_next_tier IS NOT NULL THEN
      SELECT NOT EXISTS (
        SELECT 1 FROM public.housing_lifestyle_demands hld
        WHERE hld.tier = v_next_tier.tier
          AND COALESCE((SELECT quantity FROM public.inventories i
                         WHERE i.player_id = p_uid AND i.resource_key = hld.resource_key), 0) <= 0
      ) INTO v_lifestyle_for_next_ok;
    ELSE
      v_lifestyle_for_next_ok := false;
    END IF;

    v_should_upgrade := v_next_tier IS NOT NULL
      AND v_elapsed >= COALESCE(v_cur_tier.upgrade_secs, 60)
      AND (NOT v_next_tier.needs_road OR v_has_road)
      AND (NOT v_next_tier.needs_well OR v_well_for_next)
      AND (NOT v_next_tier.needs_food OR v_has_food)
      AND (NOT v_next_tier.needs_school OR v_has_school)
      AND (NOT v_next_tier.needs_temple OR v_has_temple)
      AND (NOT v_next_tier.needs_luxury_food OR v_has_luxury_food)
      AND (NOT v_next_tier.needs_industrial_luxury OR v_has_industrial_luxury)
      AND (NOT v_next_tier.needs_all_industrial_luxuries OR v_has_all_industrial_luxuries)
      AND v_lifestyle_for_next_ok
      AND (v_skip_des OR v_desirability >= COALESCE(v_next_tier.min_desirability, 0));

    v_should_devolve := NOT v_in_tutorial
      AND v_prev_tier IS NOT NULL
      AND ((v_cur_tier.needs_road AND NOT v_has_road)
           OR (v_cur_tier.needs_well AND NOT v_well_for_cur)
           OR (v_cur_tier.needs_food AND NOT v_has_food)
           OR (v_cur_tier.needs_school AND NOT v_has_school)
           OR (v_cur_tier.needs_temple AND NOT v_has_temple)
           OR (v_cur_tier.needs_luxury_food AND NOT v_has_luxury_food)
           OR (v_cur_tier.needs_industrial_luxury AND NOT v_has_industrial_luxury)
           OR (v_cur_tier.needs_all_industrial_luxuries AND NOT v_has_all_industrial_luxuries)
           OR NOT v_lifestyle_for_cur_ok
           OR (NOT v_skip_des AND v_desirability < COALESCE(v_cur_tier.min_desirability, 0) - 30))
      AND NOT v_has_bathhouse
      AND v_elapsed >= COALESCE(v_cur_tier.devolve_secs, 30);

    IF v_should_upgrade THEN
      UPDATE public.buildings SET housing_tier = housing_tier + 1, last_processed_at = v_now
      WHERE id = v_house.id;
      v_events := v_events || jsonb_build_object(
        'building_id', v_house.id, 'event', 'upgrade',
        'from_tier', v_house.housing_tier, 'to_tier', v_house.housing_tier + 1
      )::json;
      UPDATE public.player_profiles
         SET highest_housing_tier_ever = GREATEST(highest_housing_tier_ever, v_house.housing_tier + 1)
       WHERE id = p_uid;
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
$function$;
