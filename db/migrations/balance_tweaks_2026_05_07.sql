-- ── Five balance tweaks from sandbox findings (2026-05-07 night) ──
-- See sandbox/BALANCE_NOTES.md for the empirical data driving these.
--
-- Three server-side changes here; two more (well-radius visualization,
-- tutorial copy) are client-side and live in their own commits.

-- 1. Tier-1 prereq is now "any well in district" instead of "well within
--    4 tiles". Spatial gameplay still matters for tier 2+ (Cottage and up
--    keep the positional has_well_access check). Lets a casual starter
--    place houses anywhere without watching the 4-tile manhattan radius.

CREATE OR REPLACE FUNCTION public.has_any_well(p_player_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.buildings b
    WHERE b.player_id = p_player_id
      AND b.building_type_key = 'well'
      AND b.status = 'active'
  );
$$;

-- _pp_housing_supply: tier-1 huts count when ANY well exists, regardless
-- of distance. Tier 2+ still need has_well_access (positional).
CREATE OR REPLACE FUNCTION public._pp_housing_supply(p_uid uuid)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
DECLARE
  v_housing integer := 0;
  v_in_tutorial boolean;
  v_has_any_well boolean;
BEGIN
  SELECT (tutorial_step < 4) INTO v_in_tutorial
  FROM public.player_profiles WHERE id = p_uid;
  v_in_tutorial := COALESCE(v_in_tutorial, false);

  v_has_any_well := public.has_any_well(p_uid);

  SELECT COALESCE(SUM(htc.workers), 0) INTO v_housing
  FROM public.buildings b
  JOIN public.building_types bt ON bt.key = b.building_type_key
  JOIN public.housing_tier_config htc ON htc.tier = b.housing_tier
  WHERE b.player_id = p_uid AND b.status = 'active' AND bt.category = 'housing'
    AND (NOT htc.needs_road OR public.has_road_access(p_uid, b.x, b.y))
    AND (
      v_in_tutorial
      OR NOT htc.needs_well
      OR (b.housing_tier = 1 AND v_has_any_well)
      OR (b.housing_tier > 1 AND public.has_well_access(p_uid, b.x, b.y))
    );
  RETURN v_housing;
END;
$function$;

-- _pp_evolve_housing: tier-1 evolution + tier-1 devolve gate use the
-- "any well" check. Higher tiers keep their positional check. Body is
-- the verbatim live source with v_has_well_for_tier1 added and the
-- relevant clauses updated.
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

    -- Tier-1 well requirement is "any well in district". Tier 2+
    -- still requires the positional within-4-tiles check.
    v_well_for_next := CASE
      WHEN v_next_tier IS NULL THEN false
      WHEN v_next_tier.tier = 1 THEN v_has_any_well
      ELSE v_has_well
    END;
    v_well_for_cur := CASE
      WHEN v_cur_tier.tier = 1 THEN v_has_any_well
      ELSE v_has_well
    END;

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

-- 2. Watch House upkeep 15 → 5/min. Police_station and constabulary keep
--    their higher upkeep (those are mid/late-game with bigger coverage).
UPDATE public.building_types SET upkeep_per_minute = 5 WHERE key = 'watch_house';

-- 3. Base crime 10 → 5. Starter cities can afford a few uncovered houses
--    without falling below the 50-happiness immigration threshold.
CREATE OR REPLACE FUNCTION public.compute_crime(p_uid uuid)
 RETURNS numeric
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
AS $function$
DECLARE
  v_population numeric;
  v_uncovered integer;
  v_taverns integer;
  v_score numeric;
BEGIN
  SELECT population INTO v_population FROM public.player_profiles WHERE id = p_uid;
  IF v_population IS NULL THEN v_population := 5; END IF;

  SELECT COUNT(*) INTO v_uncovered
  FROM public.buildings h
  JOIN public.building_types bt ON bt.key = h.building_type_key
  WHERE h.player_id = p_uid AND h.status = 'active' AND bt.category = 'housing'
    AND NOT EXISTS (
      SELECT 1 FROM public.buildings p
      JOIN public.building_types pt ON pt.key = p.building_type_key
      WHERE p.player_id = p_uid AND p.status = 'active' AND pt.category = 'police'
        AND p.is_staffed
        AND ABS(p.x - h.x) + ABS(p.y - h.y) <= pt.coverage_radius
    );

  SELECT COUNT(*) INTO v_taverns
  FROM public.buildings b
  WHERE b.player_id = p_uid AND b.status = 'active' AND b.building_type_key = 'tavern';

  -- Base crime 5 (was 10): a starter with no police shouldn't be
  -- flagged with a meaningful crime penalty for the empty police slot.
  v_score := 5
    + 4 * v_uncovered
    + LEAST(20, FLOOR(v_population / 10))
    + 1 * v_taverns;

  RETURN LEAST(100, GREATEST(0, v_score));
END;
$function$;
