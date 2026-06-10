-- ============================================================================
-- road_upgrade_rpc.sql  — upgrade a road tier in place (Jill bug report
-- e2b47efb, 2026-05-29): "let me click a road and upgrade it instead of
-- demolishing + rebuilding."
--
-- Requires fancier_roads.sql (road_tier column + the tiers). Independent of
-- the metric functions. Charges the TARGET tier's full build_cost + material
-- costs (you keep connectivity and skip the demolish/rebuild dance), deducts
-- money + resources, writes the cash-ledger row, and swaps building_type_key
-- in place. All roads are 1×1 so the footprint/tile claims are unchanged.
-- ============================================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.upgrade_road(p_building_id uuid, p_target_key text)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_b record;
  v_cur_tier smallint;
  v_target record;
  v_player record;
  v_cost record;
  v_have numeric;
  v_missing text;
  v_missing_list text := '';
BEGIN
  SELECT b.*, bt.category AS cur_category, bt.road_tier AS cur_road_tier
    INTO v_b
  FROM public.buildings b
  JOIN public.building_types bt ON bt.key = b.building_type_key
  WHERE b.id = p_building_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Road not found'; END IF;
  IF v_b.player_id <> v_uid THEN RAISE EXCEPTION 'Not your road'; END IF;
  IF v_b.cur_category <> 'road' THEN RAISE EXCEPTION 'That building is not a road'; END IF;
  v_cur_tier := v_b.cur_road_tier;

  SELECT * INTO v_target FROM public.building_types
    WHERE key = p_target_key AND is_active AND category = 'road';
  IF NOT FOUND THEN RAISE EXCEPTION 'Unknown road type'; END IF;
  IF v_target.road_tier <= v_cur_tier THEN
    RAISE EXCEPTION 'Can only upgrade to a higher road tier';
  END IF;

  SELECT * INTO v_player FROM public.player_profiles WHERE id = v_uid FOR UPDATE;
  IF v_player.money < v_target.build_cost THEN
    RAISE EXCEPTION 'Not enough money (need %, have %)', v_target.build_cost, v_player.money;
  END IF;

  -- Material check (same missing-list pattern as place_building).
  FOR v_cost IN
    SELECT btrc.resource_key, btrc.quantity, r.name AS resource_name
    FROM public.building_type_resource_costs btrc
    JOIN public.resources r ON r.key = btrc.resource_key
    WHERE btrc.building_type_key = p_target_key
  LOOP
    SELECT COALESCE(quantity, 0) INTO v_have
    FROM public.inventories WHERE player_id = v_uid AND resource_key = v_cost.resource_key FOR UPDATE;
    v_have := COALESCE(v_have, 0);
    IF v_have < v_cost.quantity THEN
      v_missing := v_cost.quantity || ' ' || v_cost.resource_name || ' (have ' || FLOOR(v_have)::text || ')';
      v_missing_list := CASE WHEN v_missing_list = '' THEN v_missing ELSE v_missing_list || ', ' || v_missing END;
    END IF;
  END LOOP;
  IF v_missing_list <> '' THEN RAISE EXCEPTION 'Not enough resources: need %', v_missing_list; END IF;

  -- Deduct materials + money, swap the type in place.
  FOR v_cost IN
    SELECT resource_key, quantity FROM public.building_type_resource_costs WHERE building_type_key = p_target_key
  LOOP
    UPDATE public.inventories SET quantity = quantity - v_cost.quantity, updated_at = now()
      WHERE player_id = v_uid AND resource_key = v_cost.resource_key;
  END LOOP;

  UPDATE public.buildings SET building_type_key = p_target_key WHERE id = p_building_id;

  UPDATE public.player_profiles SET money = money - v_target.build_cost
    WHERE id = v_uid RETURNING * INTO v_player;

  IF v_target.build_cost > 0 THEN
    -- 'build_cost' is the allowed ledger source (cash_source_check); the
    -- context tags it as a road upgrade (from/to) for the Treasury panel.
    INSERT INTO public.cash_transactions (player_id, source, amount, context)
    VALUES (v_uid, 'build_cost', -v_target.build_cost,
            jsonb_build_object('road_upgrade', true, 'building_id', p_building_id,
                               'from', v_b.building_type_key, 'to', p_target_key));
  END IF;

  RETURN json_build_object('building_id', p_building_id, 'building_type_key', p_target_key, 'money', v_player.money);
END;
$function$;

GRANT EXECUTE ON FUNCTION public.upgrade_road(uuid, text) TO authenticated;

COMMIT;
