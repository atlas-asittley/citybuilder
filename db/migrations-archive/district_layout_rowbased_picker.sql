-- District layout v2: row-based starters + player-picked expansion.
--
-- Rules:
--   * Each player reserves one row (chunk_y) at signup. Their starter
--     chunk is at (0, reserved_row). reserved_row = max(reserved_row)+1
--     across all players, or 0 if no players exist yet.
--   * Expansion: the client requests `expansion_candidates()` and shows
--     the player a list of unowned chunks orthogonally adjacent to their
--     district. Other players' reserved rows are excluded so the player
--     can never be trapped — at minimum the left and right edges of
--     their own reserved row are always available.
--   * `expand_district(chunk_x, chunk_y)` now takes explicit coords and
--     validates them against the candidate set.
--
-- Apply: psql "$DB_URL" -f district_layout_rowbased_picker.sql
-- One-shot: replaces the global spiral allocator entirely. Existing
-- chunks (including Atlas's stray (-1, -1)) are left as-is; new chunks
-- follow the new rules.

-- 1. Reserved-row column on player_profiles.
ALTER TABLE public.player_profiles
  ADD COLUMN IF NOT EXISTS reserved_row integer;

-- Backfill reserved_row for any existing player based on their starter
-- chunk (the row containing their home tile).
UPDATE public.player_profiles
SET reserved_row = floor(home_y::numeric / 15)::integer
WHERE reserved_row IS NULL AND home_y IS NOT NULL;

-- Uniqueness so two players can't reserve the same row.
CREATE UNIQUE INDEX IF NOT EXISTS player_profiles_reserved_row_key
  ON public.player_profiles (reserved_row)
  WHERE reserved_row IS NOT NULL;

-- 2. Drop the old global spiral allocator.
DROP FUNCTION IF EXISTS public.next_unowned_chunk_slot();

-- 3. New starter allocator: each new player gets a fresh row going down.
CREATE OR REPLACE FUNCTION public.next_starter_row()
RETURNS integer
LANGUAGE plpgsql
AS $$
DECLARE
  v_max_row integer;
BEGIN
  SELECT max(pp.reserved_row) INTO v_max_row
  FROM public.player_profiles pp
  WHERE pp.reserved_row IS NOT NULL;
  RETURN COALESCE(v_max_row + 1, 0);
END;
$$;

-- 4. Expansion candidate enumerator.
-- Returns every unowned chunk orthogonally adjacent to the player's
-- district that is NOT in another player's reserved row. By design the
-- left and right edges of the player's own reserved row are always in
-- the result, so an "empty candidates" outcome is impossible.
CREATE OR REPLACE FUNCTION public.expansion_candidates(p_player_id uuid)
RETURNS TABLE(chunk_x integer, chunk_y integer)
LANGUAGE plpgsql
AS $$
BEGIN
  RETURN QUERY
  WITH neighbors AS (
    -- All chunks orthogonally adjacent to any chunk owned by the player.
    SELECT DISTINCT cand_x, cand_y FROM (
      SELECT dc.chunk_x + 1 AS cand_x, dc.chunk_y AS cand_y FROM public.district_chunks dc WHERE dc.owner_player_id = p_player_id
      UNION ALL
      SELECT dc.chunk_x - 1, dc.chunk_y FROM public.district_chunks dc WHERE dc.owner_player_id = p_player_id
      UNION ALL
      SELECT dc.chunk_x, dc.chunk_y + 1 FROM public.district_chunks dc WHERE dc.owner_player_id = p_player_id
      UNION ALL
      SELECT dc.chunk_x, dc.chunk_y - 1 FROM public.district_chunks dc WHERE dc.owner_player_id = p_player_id
    ) raw
  ),
  reserved_rows AS (
    SELECT pp.reserved_row AS row
    FROM public.player_profiles pp
    WHERE pp.reserved_row IS NOT NULL AND pp.id <> p_player_id
  )
  SELECT n.cand_x, n.cand_y
  FROM neighbors n
  -- Exclude already-owned chunks.
  WHERE NOT EXISTS (
    SELECT 1 FROM public.district_chunks dc2
    WHERE dc2.chunk_x = n.cand_x AND dc2.chunk_y = n.cand_y
  )
  -- Exclude other players' reserved rows.
  AND NOT EXISTS (
    SELECT 1 FROM reserved_rows rr WHERE rr.row = n.cand_y
  )
  ORDER BY n.cand_y, n.cand_x;
END;
$$;

GRANT EXECUTE ON FUNCTION public.expansion_candidates(uuid) TO authenticated;

-- 5. choose_industry now sets reserved_row + uses next_starter_row.
CREATE OR REPLACE FUNCTION public.choose_industry(p_display_name text, p_industry_key text)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_profile record;
  v_chunks_owned integer;
  v_row integer;
BEGIN
  IF p_industry_key NOT IN ('timber', 'stone', 'grain', 'clay') THEN
    RAISE EXCEPTION 'Invalid industry. Choose timber, stone, grain, or clay.';
  END IF;
  IF length(trim(p_display_name)) < 2 THEN
    RAISE EXCEPTION 'Display name must be at least 2 characters.';
  END IF;

  INSERT INTO public.player_profiles (
    id, display_name, industry_key, money, worker_capacity, workers_used, chunks_owned
  ) VALUES (
    v_uid, trim(p_display_name), p_industry_key, 500, 5, 0, 0
  )
  ON CONFLICT (id) DO UPDATE SET
    display_name = trim(EXCLUDED.display_name),
    industry_key = EXCLUDED.industry_key,
    updated_at = now();

  -- Seed inventory rows for every known resource (zero quantity).
  INSERT INTO public.inventories (player_id, resource_key, quantity) VALUES
    (v_uid, 'timber', 0), (v_uid, 'lumber', 0),
    (v_uid, 'stone', 0),  (v_uid, 'brick', 0),
    (v_uid, 'grain', 0),  (v_uid, 'flour', 0),
    (v_uid, 'clay', 0),   (v_uid, 'pottery', 0),
    (v_uid, 'bread', 0),  (v_uid, 'furniture', 0),
    (v_uid, 'statuary', 0)
  ON CONFLICT (player_id, resource_key) DO NOTHING;

  -- Allocate first chunk on a fresh reserved row.
  SELECT chunks_owned INTO v_chunks_owned
  FROM public.player_profiles WHERE id = v_uid;

  IF v_chunks_owned = 0 THEN
    v_row := public.next_starter_row();
    UPDATE public.player_profiles SET reserved_row = v_row WHERE id = v_uid;
    PERFORM public.allocate_district_chunk(v_uid, 0, v_row);
  END IF;

  SELECT * INTO v_profile FROM public.player_profiles WHERE id = v_uid;

  RETURN json_build_object(
    'id', v_profile.id,
    'display_name', v_profile.display_name,
    'industry_key', v_profile.industry_key,
    'money', v_profile.money,
    'worker_capacity', v_profile.worker_capacity,
    'workers_used', v_profile.workers_used,
    'chunks_owned', v_profile.chunks_owned,
    'home_x', v_profile.home_x,
    'home_y', v_profile.home_y,
    'reserved_row', v_profile.reserved_row
  );
END;
$function$;

-- 6. expand_district now takes player-chosen coords and validates.
DROP FUNCTION IF EXISTS public.expand_district();

CREATE OR REPLACE FUNCTION public.expand_district(p_chunk_x integer, p_chunk_y integer)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_player record;
  v_cost integer;
  v_alloc json;
  v_base_cost integer := 500;
  v_is_candidate boolean;
BEGIN
  SELECT * INTO v_player FROM public.player_profiles WHERE id = v_uid;
  IF NOT FOUND THEN RAISE EXCEPTION 'Player not found'; END IF;

  v_cost := v_base_cost * v_player.chunks_owned * v_player.chunks_owned;

  IF v_player.money < v_cost THEN
    RAISE EXCEPTION 'Not enough money to expand (need %, have %)',
      v_cost, v_player.money;
  END IF;

  -- Validate that the chosen chunk is in the candidate set.
  SELECT EXISTS (
    SELECT 1 FROM public.expansion_candidates(v_uid) ec
    WHERE ec.chunk_x = p_chunk_x AND ec.chunk_y = p_chunk_y
  ) INTO v_is_candidate;

  IF NOT v_is_candidate THEN
    RAISE EXCEPTION 'Chunk (%, %) is not a valid expansion candidate', p_chunk_x, p_chunk_y;
  END IF;

  v_alloc := public.allocate_district_chunk(v_uid, p_chunk_x, p_chunk_y);

  UPDATE public.player_profiles
  SET money = money - v_cost
  WHERE id = v_uid
  RETURNING * INTO v_player;

  RETURN json_build_object(
    'chunk_x', p_chunk_x,
    'chunk_y', p_chunk_y,
    'cost', v_cost,
    'money', v_player.money,
    'chunks_owned', v_player.chunks_owned,
    'allocation', v_alloc
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.expand_district(integer, integer) TO authenticated;
