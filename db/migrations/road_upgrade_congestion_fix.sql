-- ============================================================================
-- road_upgrade_congestion_fix.sql
-- ----------------------------------------------------------------------------
-- road_upgrade_congestion_refresh.sql shipped a call to refresh_congestion()
-- which was never created. The correct helper is _pp_update_congestion().
-- Jill saw "function public.refresh_congestion(uuid) does not exist" on every
-- road upgrade attempt (bug reports f0cca7c6, 4cb7af6b — 2026-05-29).
--
-- Fix: replace the non-existent refresh_congestion(v_uid) call with
-- _pp_update_congestion(v_uid) which computes and writes congestion back to
-- player_profiles and returns the new value.
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
  v_new_congestion numeric;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'auth required'; END IF;

  -- Lock the building row (FOR UPDATE OF b) so a concurrent upgrade of the
  -- same road serializes and re-reads the tier below.
  SELECT b.*, bt.category AS cur_category, bt.road_tier AS cur_road_tier
    INTO v_b
  FROM public.buildings b
  JOIN public.building_types bt ON bt.key = b.building_type_key
  WHERE b.id = p_building_id
  FOR UPDATE OF b;
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
    INSERT INTO public.cash_transactions (player_id, source, amount, context)
    VALUES (v_uid, 'build_cost', -v_target.build_cost,
            jsonb_build_object('road_upgrade', true, 'building_id', p_building_id,
                               'from', v_b.building_type_key, 'to', p_target_key));
  END IF;

  -- Recompute congestion immediately so the stat bar reflects the upgraded road.
  v_new_congestion := public._pp_update_congestion(v_uid);

  RETURN json_build_object(
    'building_id', p_building_id,
    'building_type_key', p_target_key,
    'money', v_player.money,
    'congestion', v_new_congestion
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.upgrade_road(uuid, text) TO authenticated;

COMMIT;
