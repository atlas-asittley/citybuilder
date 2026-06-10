-- compute_happiness: replace the messy double-overwrite staffing block
-- with a single clean ratio.
--
-- The old code tried to count "staffed" buildings via a building-id
-- ANY-match against an array, then overwrote v_staffed with a count
-- of buildings WITHOUT road access — i.e. it ended up measuring
-- "road-connected worker buildings" not staffing. With max workers
-- needed but zero capacity, the player would still get the full +20
-- happiness as long as roads existed. That's wrong.
--
-- Correct signal: ratio of worker_capacity to workers_needed, capped
-- at 1.0. Both are already computed for the player —
-- worker_capacity is on player_profiles (last tick); workers_needed
-- comes from the existing _pp_workers_needed helper (current state).

CREATE OR REPLACE FUNCTION public.compute_happiness(p_uid uuid)
RETURNS json
LANGUAGE plpgsql STABLE SECURITY DEFINER AS $$
DECLARE
  v_base constant numeric := 30;
  v_services integer := 0;
  v_avg_tier numeric := 0;
  v_food_variety integer := 0;
  v_tax_count integer := 0;
  v_workers_needed integer := 0;
  v_worker_capacity integer := 0;
  v_staffing_ratio numeric := 1.0;  -- 1.0 = fully staffed, 0 = none
  v_score numeric;
BEGIN
  -- Operational services. Well counts when active + road-connected.
  -- Tavern/bathhouse/school/temple: staffed (active) + road-adjacent +
  -- inputs in stock. Looser than the per-tick service-feed check
  -- (which validates input rate × elapsed) so happiness doesn't
  -- pingpong on every drained-then-refilled input.
  IF EXISTS (
    SELECT 1 FROM public.buildings b
    JOIN public.building_types bt ON bt.key = b.building_type_key
    WHERE b.player_id = p_uid AND b.status = 'active' AND bt.key = 'well'
      AND public.has_road_access(p_uid, b.x, b.y)
  ) THEN v_services := v_services + 1; END IF;

  v_services := v_services + (
    SELECT COUNT(DISTINCT bt.key) FROM public.buildings b
    JOIN public.building_types bt ON bt.key = b.building_type_key
    WHERE b.player_id = p_uid AND b.status = 'active'
      AND bt.category = 'service' AND bt.key <> 'well'
      AND public.has_road_access(p_uid, b.x, b.y)
      AND COALESCE((SELECT quantity FROM public.inventories i
                    WHERE i.player_id = p_uid AND i.resource_key = bt.input_resource_key), 0) > 0
      AND (bt.input_resource_key_2 IS NULL
           OR COALESCE((SELECT quantity FROM public.inventories i
                        WHERE i.player_id = p_uid AND i.resource_key = bt.input_resource_key_2), 0) > 0)
  );

  -- Average tier across active housing.
  SELECT COALESCE(AVG(b.housing_tier), 0) INTO v_avg_tier
  FROM public.buildings b
  JOIN public.building_types bt ON bt.key = b.building_type_key
  WHERE b.player_id = p_uid AND b.status = 'active' AND bt.category = 'housing';

  -- Distinct in-stock foods.
  SELECT COUNT(*) INTO v_food_variety
  FROM public.inventories i
  JOIN public.resources r ON r.key = i.resource_key
  WHERE i.player_id = p_uid AND r.is_food AND i.quantity > 0;

  -- Active tax offices.
  SELECT COUNT(*) INTO v_tax_count
  FROM public.buildings b
  JOIN public.building_types bt ON bt.key = b.building_type_key
  WHERE b.player_id = p_uid AND b.status = 'active' AND bt.category = 'tax';

  -- Staffing ratio: how much of the worker demand is met. Read
  -- worker_capacity from player_profiles (set at end of last tick) and
  -- workers_needed via the same helper used by place_building +
  -- _pp_staff_buildings, so the two never drift.
  SELECT worker_capacity INTO v_worker_capacity
  FROM public.player_profiles WHERE id = p_uid;
  v_workers_needed := public._pp_workers_needed(p_uid);
  IF v_workers_needed > 0 THEN
    v_staffing_ratio := LEAST(1.0, v_worker_capacity::numeric / v_workers_needed::numeric);
  END IF;

  v_score :=
    v_base
    + 3 * v_services                                 -- max +15 (5 services)
    + 2 * v_avg_tier                                 -- max +16 at tier 8
    + LEAST(15, v_food_variety * 2)                  -- max +15 at 7+ foods
    - 3 * v_tax_count                                -- −3 per tax office
    + 20 * v_staffing_ratio;                         -- max +20 at full staffing

  RETURN json_build_object(
    'happiness', LEAST(100, GREATEST(0, v_score)),
    'breakdown', json_build_object(
      'base', v_base,
      'services', v_services,
      'avg_tier', v_avg_tier,
      'food_variety', v_food_variety,
      'tax_count', v_tax_count,
      'worker_capacity', v_worker_capacity,
      'workers_needed', v_workers_needed,
      'staffing_ratio', v_staffing_ratio
    )
  );
END;
$$;
GRANT EXECUTE ON FUNCTION public.compute_happiness(uuid) TO authenticated;
