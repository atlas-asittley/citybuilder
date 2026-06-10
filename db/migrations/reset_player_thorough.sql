-- ── Make reset_player thorough ──
-- Player-reset was leaving the old district visible on the broader map.
-- The original function only deleted by owner_player_id / player_id, so
-- any tile or building whose owner had been stranded (e.g. by a partial
-- prior reset, or a future schema bug that nulls ownership) survived.
--
-- New version: also wipe every tile and every building inside the
-- bounds of any chunk the player currently owns, regardless of who
-- owns them right now. Order matters because buildings.tile_id is
-- ON DELETE RESTRICT — buildings must go before tiles.

CREATE OR REPLACE FUNCTION public.reset_player(p_player_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  -- (1) Buildings inside the player's chunk footprints, regardless of
  -- player_id. Player-only chunks shouldn't have other players'
  -- buildings, but be defensive.
  DELETE FROM public.buildings
   WHERE EXISTS (
     SELECT 1 FROM public.district_chunks dc
      WHERE dc.owner_player_id = p_player_id
        AND buildings.x BETWEEN dc.chunk_x * 15 AND dc.chunk_x * 15 + 14
        AND buildings.y BETWEEN dc.chunk_y * 15 AND dc.chunk_y * 15 + 14
   );

  -- (2) All buildings still owned by this player (anywhere — should
  -- already be empty after step 1 but catch outliers).
  DELETE FROM public.buildings WHERE player_id = p_player_id;

  -- (3) Tiles inside the chunk footprints. This is the key new step —
  -- catches tiles whose owner_player_id got nulled out for any reason.
  DELETE FROM public.map_tiles
   WHERE EXISTS (
     SELECT 1 FROM public.district_chunks dc
      WHERE dc.owner_player_id = p_player_id
        AND map_tiles.x BETWEEN dc.chunk_x * 15 AND dc.chunk_x * 15 + 14
        AND map_tiles.y BETWEEN dc.chunk_y * 15 AND dc.chunk_y * 15 + 14
   );

  -- (4) Tiles still flagged as owned by this player anywhere else.
  DELETE FROM public.map_tiles WHERE owner_player_id = p_player_id;

  -- (5) Now safe to drop chunks, inventories, profile.
  DELETE FROM public.district_chunks WHERE owner_player_id = p_player_id;
  DELETE FROM public.inventories WHERE player_id = p_player_id;
  DELETE FROM public.player_profiles WHERE id = p_player_id;
END;
$$;
