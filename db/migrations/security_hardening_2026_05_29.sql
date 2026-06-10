-- ============================================================================
-- security_hardening_2026_05_29.sql
-- ----------------------------------------------------------------------------
-- Closes a CRITICAL cross-player exploit surfaced by the 2026-05-29 security
-- audit, plus two upgrade_road hardening nits.
--
-- THE HOLE: the internal tick helpers (_pp_* and compute_*) are SECURITY
-- DEFINER, take a client-controlled p_uid, and were EXECUTE-granted to
-- `authenticated` + `anon`. Because DEFINER functions bypass RLS, any logged-in
-- (or anonymous) client could call e.g.
--     supabase.rpc('_pp_update_power', { p_uid: '<VICTIM>' })
-- to burn a victim's fuel inventory (no ledger, no rate limit), flip their
-- buildings unstaffed (_pp_staff_buildings), overwrite their metric columns, or
-- read a rival's derived metrics (compute_*). The intended entry point
-- process_production() gates on auth.uid() and calls _pp_for_uid() (already
-- correctly REVOKED) — but the leaf helpers were reachable directly.
--
-- FIX: revoke EXECUTE on every public _pp_* and compute_* helper from
-- authenticated + anon. They are only ever called internally by DEFINER
-- orchestrators, which run as the owner — so internal calls are unaffected
-- (proven by _pp_for_uid, already revoked, with the game working). Verified
-- the frontend calls NONE of these directly (only top-level RPCs).
--
-- This is a pre-existing codebase-wide pattern; the expansion widened it with
-- new cross-player writers (_pp_update_power burns inventory), so we fix the
-- whole family, not just the new functions.
-- ============================================================================

BEGIN;

-- 1. Revoke client EXECUTE on all internal tick helpers. -------------------
DO $$
DECLARE r record;
BEGIN
  FOR r IN
    SELECT p.oid::regprocedure AS sig
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND (p.proname LIKE '\_pp\_%' OR p.proname LIKE 'compute\_%')
  LOOP
    EXECUTE format('REVOKE EXECUTE ON FUNCTION %s FROM PUBLIC, authenticated, anon', r.sig);
  END LOOP;
END$$;

-- 2. upgrade_road hardening (L1 + L2 from the audit). -----------------------
-- L1: explicit NULL-auth guard (matches demolish_building) instead of relying
--     on a downstream NULL-comparison quirk.
-- L2: lock the building row FOR UPDATE and re-read tier, so two concurrent
--     upgrades on the same road can't both charge (self-overcharge race).
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

  RETURN json_build_object('building_id', p_building_id, 'building_type_key', p_target_key, 'money', v_player.money);
END;
$function$;

GRANT EXECUTE ON FUNCTION public.upgrade_road(uuid, text) TO authenticated;

COMMIT;
