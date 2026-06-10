-- ── Transport Network: server unlock logic + expand RPC (2026-05-08) ──
-- Continues transport_network_schema.sql.
--
-- This patch:
--  1. Extends _trader_is_unlocked to handle transport_mode-bound
--     traders (the 6 new airport/seaport/train traders).
--  2. Adds expand_transport_hub(building_id) RPC for paying to upgrade
--     a hub's expansion_level.
--  3. Adds a helper view of city-wide transport tier counts.

-- Helper: total transport tiers in the city for a given mode.
-- A mode tier = (1 + expansion_level) summed over road-connected hubs.
-- We use existing has_road_access for the connectivity check.
CREATE OR REPLACE FUNCTION public._city_transport_tiers(p_player_id uuid, p_mode text)
RETURNS integer
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
AS $$
DECLARE
  v_city_id uuid;
  v_total integer := 0;
BEGIN
  SELECT city_id INTO v_city_id FROM public.player_profiles WHERE id = p_player_id;
  IF v_city_id IS NULL THEN RETURN 0; END IF;

  -- Sum (1 + expansion_level) across all road-connected hubs of this
  -- mode in the city. Hub categories: airport=transport_hub of building_key
  -- 'airport', seaport='seaport', train='train_depot'.
  SELECT COALESCE(SUM(1 + b.expansion_level), 0) INTO v_total
  FROM public.buildings b
  JOIN public.building_types bt ON bt.key = b.building_type_key
  JOIN public.player_profiles pp ON pp.id = b.player_id
  WHERE pp.city_id = v_city_id
    AND b.status = 'active'
    AND bt.category = 'transport_hub'
    AND ((p_mode = 'airport'  AND b.building_type_key = 'airport')
      OR (p_mode = 'seaport'  AND b.building_type_key = 'seaport')
      OR (p_mode = 'train'    AND b.building_type_key = 'train_depot'))
    AND public.has_road_access(b.player_id, b.x, b.y);

  RETURN v_total;
END;
$$;

-- Helper: does this player have access to mode M's traders? (Either
-- owns a road-connected hub of that mode, OR owns a road-connected
-- truck depot AND the city has any road-connected hub of that mode.)
CREATE OR REPLACE FUNCTION public._player_has_transport_access(p_player_id uuid, p_mode text)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
AS $$
DECLARE
  v_owns_hub boolean;
  v_owns_truck boolean;
  v_city_has_hub boolean;
  v_city_id uuid;
BEGIN
  -- Direct hub ownership (with road access).
  SELECT EXISTS (
    SELECT 1 FROM public.buildings b
    JOIN public.building_types bt ON bt.key = b.building_type_key
    WHERE b.player_id = p_player_id
      AND b.status = 'active'
      AND bt.category = 'transport_hub'
      AND ((p_mode = 'airport'  AND b.building_type_key = 'airport')
        OR (p_mode = 'seaport'  AND b.building_type_key = 'seaport')
        OR (p_mode = 'train'    AND b.building_type_key = 'train_depot'))
      AND public.has_road_access(p_player_id, b.x, b.y)
  ) INTO v_owns_hub;
  IF v_owns_hub THEN RETURN TRUE; END IF;

  -- Truck depot ownership (road-connected) + any city hub of mode.
  SELECT EXISTS (
    SELECT 1 FROM public.buildings b
    WHERE b.player_id = p_player_id
      AND b.status = 'active'
      AND b.building_type_key = 'truck_depot'
      AND public.has_road_access(p_player_id, b.x, b.y)
  ) INTO v_owns_truck;
  IF NOT v_owns_truck THEN RETURN FALSE; END IF;

  SELECT city_id INTO v_city_id FROM public.player_profiles WHERE id = p_player_id;
  IF v_city_id IS NULL THEN RETURN FALSE; END IF;

  SELECT EXISTS (
    SELECT 1 FROM public.buildings b
    JOIN public.building_types bt ON bt.key = b.building_type_key
    JOIN public.player_profiles pp ON pp.id = b.player_id
    WHERE pp.city_id = v_city_id
      AND b.status = 'active'
      AND bt.category = 'transport_hub'
      AND ((p_mode = 'airport'  AND b.building_type_key = 'airport')
        OR (p_mode = 'seaport'  AND b.building_type_key = 'seaport')
        OR (p_mode = 'train'    AND b.building_type_key = 'train_depot'))
      AND public.has_road_access(b.player_id, b.x, b.y)
  ) INTO v_city_has_hub;

  RETURN v_city_has_hub;
END;
$$;

-- Updated _trader_is_unlocked: legacy traders use existing rules,
-- transport-mode traders use the new helpers.
CREATE OR REPLACE FUNCTION public._trader_is_unlocked(p_player_id uuid, p_trader_key text)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
AS $$
DECLARE
  v_total_buildings integer;
  v_mode text;
  v_tier integer;
  v_city_tiers integer;
BEGIN
  -- Legacy gates first (river / desert / mountain).
  IF p_trader_key = 'river_traders' THEN RETURN TRUE; END IF;
  IF p_trader_key = 'desert_caravan' THEN
    RETURN EXISTS (
      SELECT 1 FROM public.buildings b
      JOIN public.building_types bt ON bt.key = b.building_type_key
      WHERE b.player_id = p_player_id AND b.status = 'active'
        AND bt.category = 'processor');
  END IF;
  IF p_trader_key = 'mountain_folk' THEN
    SELECT COUNT(*) INTO v_total_buildings
    FROM public.buildings WHERE player_id = p_player_id;
    RETURN v_total_buildings >= 3;
  END IF;

  -- Transport-mode traders.
  SELECT transport_mode, tier INTO v_mode, v_tier
  FROM public.traders WHERE key = p_trader_key;
  IF v_mode IS NULL OR v_tier IS NULL THEN RETURN FALSE; END IF;

  v_city_tiers := public._city_transport_tiers(p_player_id, v_mode);
  IF v_tier > v_city_tiers THEN RETURN FALSE; END IF;

  RETURN public._player_has_transport_access(p_player_id, v_mode);
END;
$$;

-- ── expand_transport_hub RPC ──
-- Pay to bump a hub's expansion_level by 1. Cost = 2× build_cost ×
-- (current_level + 1). Anyone can pay, not just the building's owner —
-- per Atlas's "shared upgrades" intent.
CREATE OR REPLACE FUNCTION public.expand_transport_hub(p_building_id uuid)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_b record;
  v_bt record;
  v_cost integer;
  v_money integer;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;

  SELECT * INTO v_b FROM public.buildings WHERE id = p_building_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Building not found'; END IF;

  SELECT * INTO v_bt FROM public.building_types WHERE key = v_b.building_type_key;
  IF v_bt.category <> 'transport_hub' THEN
    RAISE EXCEPTION 'Only transport hubs can be expanded';
  END IF;

  -- Cap at 1 expansion for MVP (so each hub yields max 2 traders).
  IF v_b.expansion_level >= 1 THEN
    RAISE EXCEPTION 'Hub is already at max expansion';
  END IF;

  -- Cost: 2× build_cost × (current_level + 1). For the first
  -- expansion: 2 × build_cost × 1 = $80k for an airport.
  v_cost := (v_bt.build_cost * 2 * (v_b.expansion_level + 1))::integer;

  SELECT money INTO v_money FROM public.player_profiles WHERE id = v_uid;
  IF v_money < v_cost THEN
    RAISE EXCEPTION 'Need $% to expand (you have $%)', v_cost, v_money;
  END IF;

  UPDATE public.player_profiles SET money = money - v_cost WHERE id = v_uid;
  INSERT INTO public.cash_transactions (player_id, source, amount, context)
  VALUES (v_uid, 'build_cost', -v_cost,
          jsonb_build_object('reason', 'transport_expansion',
                             'building_id', p_building_id,
                             'building_type', v_b.building_type_key,
                             'new_level', v_b.expansion_level + 1));

  UPDATE public.buildings SET expansion_level = expansion_level + 1
    WHERE id = p_building_id;

  RETURN json_build_object(
    'building_id', p_building_id,
    'new_level', v_b.expansion_level + 1,
    'cost', v_cost,
    'money', v_money - v_cost
  );
END;
$$;
GRANT EXECUTE ON FUNCTION public.expand_transport_hub(uuid) TO authenticated;

-- ── Update _pp_workers_needed to count transport buildings ──
-- Transport hubs and connectors need workers + road access (matched
-- to the client's prodBuildings filter in computeLaborAllocation).
CREATE OR REPLACE FUNCTION public._pp_workers_needed(p_uid uuid)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  v_total integer;
BEGIN
  SELECT COALESCE(SUM(bt.worker_cost), 0) INTO v_total
  FROM public.buildings b
  JOIN public.building_types bt ON bt.key = b.building_type_key
  WHERE b.player_id = p_uid AND b.status = 'active'
    AND bt.category IN ('extractor','food_extractor','booster','processor',
                        'tax','service','police',
                        'transport_hub','transport_connector')
    AND public.has_road_access(p_uid, b.x, b.y);
  RETURN v_total;
END;
$function$;
