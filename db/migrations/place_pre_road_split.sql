-- Split place_pre_road like recompute_extractor_paths.
--
-- The public version has the auth check (added in
-- rpc_auth_lockdown.sql). The internal version `_place_pre_road`
-- does the same work without the auth check, so allocate_district_chunk
-- (which is itself auth-checked at the top) and conftest test setup
-- can call it without tripping over the cross-player guard.

CREATE OR REPLACE FUNCTION public._place_pre_road(p_player_id uuid, p_x integer, p_y integer)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
DECLARE
  v_tile record;
  v_bid uuid;
BEGIN
  SELECT * INTO v_tile FROM public.map_tiles
  WHERE x = p_x AND y = p_y AND owner_player_id = p_player_id;
  IF NOT FOUND THEN RETURN; END IF;
  IF v_tile.occupied_building_id IS NOT NULL THEN RETURN; END IF;
  IF v_tile.resource_node_key IS NOT NULL THEN
    UPDATE public.map_tiles SET resource_node_key = NULL WHERE id = v_tile.id;
  END IF;
  INSERT INTO public.buildings (player_id, building_type_key, tile_id, x, y)
  VALUES (p_player_id, 'road', v_tile.id, p_x, p_y)
  RETURNING id INTO v_bid;
  UPDATE public.map_tiles SET occupied_building_id = v_bid WHERE id = v_tile.id;
END;
$function$;

-- Update allocate_district_chunk's place_pre_road calls to internal.
-- Easiest: swap every place_pre_road inside the body with
-- _place_pre_road. We CREATE OR REPLACE with the patched body.
DO $$
DECLARE
  v_body text;
BEGIN
  SELECT pg_get_functiondef('public.allocate_district_chunk(uuid,integer,integer)'::regprocedure) INTO v_body;
  v_body := replace(v_body, 'PERFORM public.place_pre_road', 'PERFORM public._place_pre_road');
  -- Drop the trailing `+` and execute.
  EXECUTE v_body || ';';
END $$;
