-- ====================================================================
-- Desirability v1: per-tile score (visible-but-ungated)
-- ====================================================================
-- Atlas: "maybe there should be a desirability meter for the houses
-- as well. ... if pollution or crime are too high, that becomes an
-- issue for that home, and it devolves down a tier."
--
-- Each owned tile gets a `desirability` integer (0..100) recomputed
-- each tick from a city-wide base (food variety, crime, tax pressure)
-- plus per-tile pollution penalty + nearby-service bonus.
--
-- v1 SHIPS THE COMPUTE + UI but NOT THE HOUSING GATE. Same playbook
-- as pollution v1 — let players see the score, plan with parks /
-- services to push it up, then flip the upgrade-gate / devolve-gate
-- in v2 once existing housing has time to react. The
-- min_desirability column on housing_tier_config is populated with
-- thresholds for v2 to consume.

ALTER TABLE public.map_tiles
  ADD COLUMN IF NOT EXISTS desirability integer NOT NULL DEFAULT 50;

ALTER TABLE public.housing_tier_config
  ADD COLUMN IF NOT EXISTS min_desirability integer NOT NULL DEFAULT 0;

UPDATE public.housing_tier_config SET min_desirability = 0  WHERE tier = 0;  -- Shanty
UPDATE public.housing_tier_config SET min_desirability = 25 WHERE tier = 1;  -- Mud Hut
UPDATE public.housing_tier_config SET min_desirability = 40 WHERE tier = 2;  -- Cottage
UPDATE public.housing_tier_config SET min_desirability = 50 WHERE tier = 3;  -- Townhouse
UPDATE public.housing_tier_config SET min_desirability = 60 WHERE tier = 4;  -- Villa
UPDATE public.housing_tier_config SET min_desirability = 70 WHERE tier = 5;  -- Manor
UPDATE public.housing_tier_config SET min_desirability = 80 WHERE tier = 6;  -- Mansion
UPDATE public.housing_tier_config SET min_desirability = 88 WHERE tier = 7;  -- Estate
UPDATE public.housing_tier_config SET min_desirability = 94 WHERE tier = 8;  -- Palace

CREATE OR REPLACE FUNCTION public._pp_update_desirability(p_uid uuid)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
AS $$
DECLARE
  v_food_variety integer;
  v_crime numeric;
  v_tax_count integer;
  v_city_base integer;
BEGIN
  SELECT COUNT(DISTINCT i.resource_key) INTO v_food_variety
  FROM public.inventories i
  JOIN public.resources r ON r.key = i.resource_key
  WHERE i.player_id = p_uid AND r.is_food AND i.quantity > 0;

  SELECT COALESCE(crime, 0) INTO v_crime
  FROM public.player_profiles WHERE id = p_uid;

  SELECT COUNT(*) INTO v_tax_count
  FROM public.buildings b
  JOIN public.building_types bt ON bt.key = b.building_type_key
  WHERE b.player_id = p_uid AND b.status = 'active' AND bt.category = 'tax';

  v_city_base := 50
    + LEAST(10, v_food_variety * 2)
    - LEAST(20, GREATEST(0, FLOOR((v_crime - 30) / 10)::integer * 2))
    - LEAST(15, v_tax_count * 3);

  UPDATE public.map_tiles mt SET desirability = LEAST(100, GREATEST(0,
    v_city_base
    - LEAST(30, mt.pollution::integer)
    + COALESCE((
        SELECT SUM(CASE bt.key
          WHEN 'well'      THEN 5
          WHEN 'school'    THEN 5
          WHEN 'temple'    THEN 5
          WHEN 'bathhouse' THEN 5
          WHEN 'tavern'    THEN 3
          ELSE 0 END)
        FROM public.buildings b
        JOIN public.building_types bt ON bt.key = b.building_type_key
        WHERE b.player_id = p_uid AND b.status = 'active' AND b.is_staffed
          AND bt.category = 'service'
          AND ABS(b.x - mt.x) + ABS(b.y - mt.y) <=
              CASE bt.key
                WHEN 'well'      THEN 4
                WHEN 'school'    THEN 5
                WHEN 'temple'    THEN 6
                WHEN 'bathhouse' THEN 4
                WHEN 'tavern'    THEN 4
                ELSE 0 END
      ), 0)
  )) WHERE mt.owner_player_id = p_uid;
END;
$$;

GRANT EXECUTE ON FUNCTION public._pp_update_desirability(uuid) TO authenticated;

-- Hook into process_production AFTER pollution + crime so desirability
-- can read both, BEFORE housing eval so a future v2 gate can consume
-- it on the same tick.
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
BEGIN
  v_tavern_bonus := public._pp_tavern_bonus(v_uid);
  v_population := public._pp_update_population(v_uid);
  v_supply := FLOOR(v_population)::integer + v_tavern_bonus;

  SELECT staffed_ids, workers_needed, unstaffed_count
    INTO v_staffing
    FROM public._pp_staff_buildings(v_uid, v_supply);

  PERFORM public._pp_update_pollution(v_uid);

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
    'migration_rate', (SELECT migration_rate FROM public.player_profiles WHERE id = v_uid)
  );
END;
$$;
