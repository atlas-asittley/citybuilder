-- Resource tile rules:
--   1. place_building rejects tiles that still have a resource_node_key.
--   2. New RPC clear_resource_tile(p_tile_id) lets the player clear a
--      resource (sets resource_node_key = NULL) so they can build there.
--
-- Apply: psql "$DB_URL" -f resource_tile_rules.sql
-- Surgical: only adds a single new check to place_building (so the rest
-- of the function stays as the existing baseline_schema.sql ships it),
-- and adds one new function + GRANT.

-- 1. Placement guard. Drop and recreate place_building? No — too much
--    surface area to redeclare. Instead, layer the check as a trigger
--    on buildings.INSERT so it works regardless of which place_building
--    version is installed.
CREATE OR REPLACE FUNCTION public.reject_build_on_resource()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  v_resource text;
BEGIN
  SELECT mt.resource_node_key INTO v_resource
  FROM public.map_tiles mt WHERE mt.id = NEW.tile_id;
  IF v_resource IS NOT NULL THEN
    RAISE EXCEPTION 'Cannot build on a resource tile — clear the % resource first', v_resource;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS reject_build_on_resource ON public.buildings;
CREATE TRIGGER reject_build_on_resource
  BEFORE INSERT ON public.buildings
  FOR EACH ROW
  EXECUTE FUNCTION public.reject_build_on_resource();

-- 2. Clear-resource RPC. Free for now; the player simply burns the
--    timber / quarries the boulder / fills the pit. Charging a fee can
--    come later if it's too easy.
CREATE OR REPLACE FUNCTION public.clear_resource_tile(p_tile_id uuid)
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
    RAISE EXCEPTION 'Cannot clear a resource tile you do not own';
  END IF;
  IF v_tile.resource_node_key IS NULL THEN
    RAISE EXCEPTION 'Tile has no resource to clear';
  END IF;
  -- Reject if an extractor is currently targeting this tile — the
  -- player should demolish the extractor first so the dependency is
  -- explicit.
  IF v_tile.claimed_by_building_id IS NOT NULL THEN
    RAISE EXCEPTION 'Demolish the extractor targeting this tile before clearing it';
  END IF;
  UPDATE public.map_tiles
  SET resource_node_key = NULL
  WHERE id = p_tile_id;
  RETURN json_build_object(
    'tile_id', p_tile_id,
    'cleared_resource', v_tile.resource_node_key,
    'x', v_tile.x,
    'y', v_tile.y
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.clear_resource_tile(uuid) TO authenticated;
