-- ─────────────────────────────────────────────────────────────────────
-- Allow truck_depot (transport_connector) to be expanded (2026-05-27).
--
-- Bug: expand_transport_hub rejected any building whose category is not
-- 'transport_hub', but truck_depot has category 'transport_connector'.
-- The frontend already shows the Expand button for transport_connector
-- (InspectorPanel.js:410), and _city_transport_tiers already counts
-- SUM(1 + expansion_level) for truck_depots to determine truck trade
-- capacity. The server-side guard was simply never updated to match.
--
-- Fix:
--   1. Widen the category guard to also allow 'transport_connector'.
--   2. Add truck_depot → 'truck' to the trader-spawn CASE so expansion
--      adds a new truck-mode trade partner, consistent with how all
--      other transport hub expansions work.
-- ─────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.expand_transport_hub(p_building_id uuid)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_b record;
  v_bt record;
  v_cost integer;
  v_money integer;
  v_new_money integer;
  v_mode text;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;

  SELECT * INTO v_b FROM public.buildings WHERE id = p_building_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Building not found'; END IF;
  IF v_b.player_id <> v_uid THEN RAISE EXCEPTION 'Not your building'; END IF;

  SELECT * INTO v_bt FROM public.building_types WHERE key = v_b.building_type_key;
  IF v_bt.category NOT IN ('transport_hub', 'transport_connector') THEN
    RAISE EXCEPTION 'Only transport hubs can be expanded';
  END IF;

  IF v_b.expansion_level >= 1 THEN
    RAISE EXCEPTION 'Hub is already at max expansion';
  END IF;

  v_cost := (v_bt.build_cost * 2 * (v_b.expansion_level + 1))::integer;

  SELECT money INTO v_money FROM public.player_profiles WHERE id = v_uid FOR UPDATE;
  IF v_money < v_cost THEN
    RAISE EXCEPTION 'Need $% to expand (you have $%)', v_cost, v_money;
  END IF;

  UPDATE public.player_profiles SET money = money - v_cost WHERE id = v_uid
    RETURNING money INTO v_new_money;

  UPDATE public.buildings SET expansion_level = expansion_level + 1, updated_at = now()
    WHERE id = p_building_id;

  INSERT INTO public.cash_transactions (player_id, source, amount, context)
  VALUES (v_uid, 'build_cost', -v_cost,
          jsonb_build_object('building_id', p_building_id, 'reason', 'transport_hub_expand'));

  -- Each expansion adds a new procedural trade partner.
  v_mode := CASE v_b.building_type_key
    WHEN 'airport'     THEN 'airport'
    WHEN 'seaport'     THEN 'seaport'
    WHEN 'train_depot' THEN 'train'
    WHEN 'truck_depot' THEN 'truck'
    ELSE NULL
  END;
  IF v_mode IS NOT NULL THEN
    PERFORM public._spawn_random_trader(v_mode);
  END IF;

  RETURN json_build_object(
    'building_id', p_building_id,
    'expansion_level', v_b.expansion_level + 1,
    'cost', v_cost,
    'money', v_new_money
  );
END;
$function$;
