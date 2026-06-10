-- ─────────────────────────────────────────────────────────────────────
-- Truck Depot trader: opens one new trade partner of its own.
--
-- Previously the truck_depot only granted ACCESS to other players'
-- airport / seaport / train_depot traders (city-shared transport tier).
-- Now it also unlocks "Regional Hauliers" — a local-region trader
-- that fills the niche between the starter Neighboring City (broad,
-- modest cap) and the specialized hubs (narrow + bulk).
--
-- Niche: cheap raw materials at moderate cap. Useful mid-game for
-- players whose own industry doesn't cover what their housing tier
-- demands, and as a worthwhile reward for the truck_depot's 8000 cost.
-- ─────────────────────────────────────────────────────────────────────

-- 1) New trader.
INSERT INTO public.traders
  (key, name, description, is_active, visit_capacity, visit_interval_minutes,
   display_order, base_request_qty,
   soft_deadline_minutes, transport_mode, tier)
VALUES
  ('regional_hauliers', 'Regional Hauliers',
   'Local hauling co-op. Frequent runs to nearby villages with raw materials and household goods.',
   TRUE, 25, 12, 90, 5, 60, 'truck', 1)
ON CONFLICT (key) DO UPDATE SET
  name = EXCLUDED.name,
  description = EXCLUDED.description,
  is_active = EXCLUDED.is_active,
  visit_capacity = EXCLUDED.visit_capacity,
  visit_interval_minutes = EXCLUDED.visit_interval_minutes,
  transport_mode = EXCLUDED.transport_mode,
  tier = EXCLUDED.tier;

-- 2) Catalog. Raw materials + one lifestyle staple. Prices sit
-- between Neighboring City (river_traders) and the bulk hubs
-- (coastal_merchants / inland_caravans).
INSERT INTO public.trader_prices
  (trader_key, resource_key, buy_price, sell_price, daily_buy_cap, daily_sell_cap, is_active)
VALUES
  ('regional_hauliers', 'timber',  4,  7, 250, 200, TRUE),
  ('regional_hauliers', 'stone',   5,  9, 250, 200, TRUE),
  ('regional_hauliers', 'clay',    3,  5, 250, 200, TRUE),
  ('regional_hauliers', 'iron',    7, 13, 200, 150, TRUE),
  ('regional_hauliers', 'pottery', 12, 19, 200, 150, TRUE)
ON CONFLICT (trader_key, resource_key) DO UPDATE SET
  buy_price = EXCLUDED.buy_price,
  sell_price = EXCLUDED.sell_price,
  daily_buy_cap = EXCLUDED.daily_buy_cap,
  daily_sell_cap = EXCLUDED.daily_sell_cap,
  is_active = EXCLUDED.is_active;

-- 3a) Extend _city_transport_tiers to recognize 'truck'. The tier count
-- for truck is the count of road-connected truck_depots in the city
-- (each depot contributes 1 + expansion_level, mirroring the hub rule).
CREATE OR REPLACE FUNCTION public._city_transport_tiers(p_player_id uuid, p_mode text)
RETURNS integer
LANGUAGE plpgsql
STABLE SECURITY DEFINER
AS $function$
DECLARE
  v_city_id uuid;
  v_total integer := 0;
BEGIN
  SELECT city_id INTO v_city_id FROM public.player_profiles WHERE id = p_player_id;
  IF v_city_id IS NULL THEN RETURN 0; END IF;

  -- truck mode: count road-connected truck_depots (transport_connector
  -- category, not transport_hub). Hub modes use the existing rule.
  IF p_mode = 'truck' THEN
    SELECT COALESCE(SUM(1 + b.expansion_level), 0) INTO v_total
    FROM public.buildings b
    JOIN public.player_profiles pp ON pp.id = b.player_id
    WHERE pp.city_id = v_city_id
      AND b.status = 'active'
      AND b.building_type_key = 'truck_depot'
      AND public.has_road_access(b.player_id, b.x, b.y);
    RETURN v_total;
  END IF;

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
$function$;

-- 3b) Extend _player_has_transport_access to recognize the 'truck' mode.
-- For 'truck', the only requirement is that the player owns a
-- road-connected truck_depot. (The existing 'airport'/'seaport'/'train'
-- branches stay unchanged, including the city-shared truck-depot path.)
CREATE OR REPLACE FUNCTION public._player_has_transport_access(p_player_id uuid, p_mode text)
RETURNS boolean
LANGUAGE plpgsql
STABLE
AS $function$
DECLARE
  v_owns_hub boolean;
  v_owns_truck boolean;
  v_city_has_hub boolean;
  v_city_id uuid;
BEGIN
  -- 'truck' mode: direct truck_depot ownership (with road access).
  IF p_mode = 'truck' THEN
    RETURN EXISTS (
      SELECT 1 FROM public.buildings b
      WHERE b.player_id = p_player_id
        AND b.status = 'active'
        AND b.building_type_key = 'truck_depot'
        AND public.has_road_access(p_player_id, b.x, b.y)
    );
  END IF;

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
$function$;
