-- Bump district expansion cost: $500 base → $1000 base.
-- Atlas's call: chunk #2 = $500 was too easy to afford. Now:
--   chunk #2 (chunks_owned=1²×1000) = $1,000
--   chunk #3 (chunks_owned=2²×1000) = $4,000
--   chunk #4 (chunks_owned=3²×1000) = $9,000
--   chunk #5 (chunks_owned=4²×1000) = $16,000
--
-- Client previews (js/ui.js title and js/map.js confirm flow) match
-- the new constant.

CREATE OR REPLACE FUNCTION public.expand_district(p_chunk_x integer, p_chunk_y integer)
RETURNS json
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_player record;
  v_cost integer;
  v_alloc json;
  v_base_cost integer := 1000;
  v_is_candidate boolean;
BEGIN
  SELECT * INTO v_player FROM public.player_profiles WHERE id = v_uid;
  IF NOT FOUND THEN RAISE EXCEPTION 'Player not found'; END IF;

  v_cost := v_base_cost * v_player.chunks_owned * v_player.chunks_owned;

  IF v_player.money < v_cost THEN
    RAISE EXCEPTION 'Not enough money to expand (need %, have %)',
      v_cost, v_player.money;
  END IF;

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
$$;

GRANT EXECUTE ON FUNCTION public.expand_district(integer, integer) TO authenticated;
