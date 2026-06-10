-- demolish_highway_tile: lets a player remove a highway tile in their
-- own district. Converts the tile back to plain ground (terrain='ground',
-- buildable=true). They lose the shared road-cost connection through
-- that cell, which is "their own detriment" per Atlas — paths via that
-- tile drop to the off-road cost-3 walking, housing/processor road
-- access through that cell goes away unless they place their own road.
--
-- Apply: psql "$DB_URL" -f demolish_highway.sql

CREATE OR REPLACE FUNCTION public.demolish_highway_tile(p_tile_id uuid)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_tile record;
BEGIN
  SELECT * INTO v_tile FROM public.map_tiles WHERE id = p_tile_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Tile not found'; END IF;
  IF v_tile.owner_player_id IS NULL OR v_tile.owner_player_id <> v_uid THEN
    RAISE EXCEPTION 'Cannot demolish a highway tile you do not own';
  END IF;
  IF v_tile.terrain_type <> 'highway' THEN
    RAISE EXCEPTION 'Tile is not a highway tile';
  END IF;
  UPDATE public.map_tiles
  SET terrain_type = 'ground',
      buildable = true
  WHERE id = p_tile_id;
  -- Re-target any of this player's extractors whose path may have
  -- routed through the demolished cell.
  PERFORM public.recompute_extractor_paths(v_uid);
  RETURN json_build_object('tile_id', p_tile_id, 'x', v_tile.x, 'y', v_tile.y);
END;
$$;

GRANT EXECUTE ON FUNCTION public.demolish_highway_tile(uuid) TO authenticated;
