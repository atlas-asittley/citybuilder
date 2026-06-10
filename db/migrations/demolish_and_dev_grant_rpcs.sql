-- ─────────────────────────────────────────────────────────────────────
-- Two new RPCs to remove direct table writes from the JS:
--
-- demolish_building(p_building_id uuid) — replaces the JS path
--   `sb.from('buildings').delete().eq(id, X).eq(player_id, me)`. The
--   old path bypassed cash ledger (50% refund applied client-side
--   only), bypassed any future demolish-time logic (e.g. resource
--   refund parity), and required UPDATE/DELETE policies on buildings
--   that were a privilege-escalation surface (a player could
--   directly mutate building_type_key, x, y, housing_tier, etc).
--
-- dev_grant_money(p_amount integer) — replaces the triple-tap
--   topbar cheat that was directly UPDATE-ing player_profiles.money.
--   Same direct-write attack surface (any authenticated player could
--   set their money to anything via PostgREST). RPC wraps the
--   change + emits a ledger_adjustment row.
--
-- After this migration the buildings + player_profiles UPDATE/INSERT/
-- DELETE policies become unnecessary; following migration drops them.
-- ─────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.demolish_building(p_building_id uuid)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_b record;
  v_bt record;
  v_refund integer;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'auth required'; END IF;

  SELECT * INTO v_b FROM public.buildings WHERE id = p_building_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Building not found'; END IF;
  IF v_b.player_id <> v_uid THEN
    RAISE EXCEPTION 'Not your building';
  END IF;

  SELECT * INTO v_bt FROM public.building_types WHERE key = v_b.building_type_key;
  v_refund := COALESCE(FLOOR(v_bt.build_cost * 0.5)::integer, 0);

  -- Order matters for the FKs:
  --   - map_tiles.occupied_building_id has ON DELETE SET NULL via FK
  --   - map_tiles.claimed_by_building_id likewise
  -- so DELETE FROM buildings cascades cleanly.
  DELETE FROM public.buildings WHERE id = p_building_id;

  IF v_refund > 0 THEN
    UPDATE public.player_profiles
       SET money = money + v_refund
     WHERE id = v_uid;
    INSERT INTO public.cash_transactions
      (player_id, source, amount, context)
    VALUES
      (v_uid, 'demolish_refund', v_refund,
       jsonb_build_object('building_id', p_building_id,
                          'building_type_key', v_b.building_type_key,
                          'build_cost', v_bt.build_cost));
  END IF;

  RETURN json_build_object(
    'building_id', p_building_id,
    'refund', v_refund,
    'money', (SELECT money FROM public.player_profiles WHERE id = v_uid)
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.demolish_building(uuid) TO authenticated;


CREATE OR REPLACE FUNCTION public.dev_grant_money(p_amount integer)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_new_money integer;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'auth required'; END IF;
  IF p_amount <= 0 OR p_amount > 1000000 THEN
    RAISE EXCEPTION 'amount must be between 1 and 1000000';
  END IF;

  UPDATE public.player_profiles
     SET money = money + p_amount
   WHERE id = v_uid
   RETURNING money INTO v_new_money;

  INSERT INTO public.cash_transactions (player_id, source, amount, context)
  VALUES (v_uid, 'ledger_adjustment', p_amount,
          jsonb_build_object('reason', 'triple_tap_cheat'));

  RETURN json_build_object('money', v_new_money, 'granted', p_amount);
END;
$function$;

GRANT EXECUTE ON FUNCTION public.dev_grant_money(integer) TO authenticated;
