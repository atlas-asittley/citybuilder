-- Expose another player's tradeable money + inventory so the trade
-- dialog can annotate the "they give" side with what the counterparty
-- actually has. Read-only; no side effects.
--
-- Terrain resources are excluded — they're map-tile markers, not stocks.
-- Zero/negative inventory rows are excluded so the dropdown stays
-- meaningful.

CREATE OR REPLACE FUNCTION public.get_player_trade_view(p_player_id uuid)
RETURNS json
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_money integer;
  v_display text;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;
  IF p_player_id IS NULL THEN
    RAISE EXCEPTION 'Player ID required';
  END IF;

  SELECT money, display_name INTO v_money, v_display
  FROM public.player_profiles WHERE id = p_player_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Player not found';
  END IF;

  RETURN json_build_object(
    'player_id', p_player_id,
    'display_name', v_display,
    'money', v_money,
    'inventory', COALESCE(
      (SELECT json_object_agg(i.resource_key, i.quantity)
       FROM public.inventories i
       JOIN public.resources r ON r.key = i.resource_key
       WHERE i.player_id = p_player_id
         AND r.kind <> 'terrain'
         AND i.quantity > 0),
      '{}'::json
    )
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_player_trade_view(uuid) TO authenticated;
