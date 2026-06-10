-- ─────────────────────────────────────────────────────────────────────
-- Restore procedural-trader spawn in expand_transport_hub (2026-05-22).
--
-- Regression: big_bug_sweep_2026_05_20 added a FOR UPDATE lock to
-- expand_transport_hub but inadvertently dropped the trader-spawn
-- PERFORM that the original procedural_traders.sql added. Net effect:
-- expanding a hub no longer adds a new trade partner — defeating the
-- documented purpose of expansion ("each expansion adds another
-- procedural trade partner to the city pool").
--
-- Caught by tests/db/test_procedural_traders.py::test_airport_build_then
-- _expand_spawns_two during the 2026-05-21 overnight sweep.
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
  IF v_bt.category <> 'transport_hub' THEN
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

  -- Procedural trader spawn — each expansion adds a new partner. This
  -- mirrors the original procedural_traders.sql behavior that
  -- big_bug_sweep_2026_05_20 accidentally dropped.
  v_mode := CASE v_b.building_type_key
    WHEN 'airport' THEN 'airport'
    WHEN 'seaport' THEN 'seaport'
    WHEN 'train_depot' THEN 'train'
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
