-- ─────────────────────────────────────────────────────────────────────
-- Expansion: drop reserved-row gate, add post-claim reachability check
-- (2026-05-21).
--
-- Old design: each player had a reserved_row stamped at signup, and
-- expansion_candidates excluded any chunk whose y matched ANOTHER
-- player's reserved row. Jill spawned on row 3, Drew on row 4 — Jill
-- could never expand into row 4 even if Drew was three chunks east.
-- Players got boxed into horizontal strips.
--
-- New design: candidates ignore reserved_row entirely; players see
-- every unclaimed orthogonal neighbor of their parcel, in all four
-- directions. To prevent one player from completely surrounding
-- another, expand_district now simulates the claim and rejects it if
-- any OTHER player would end up with zero expansion candidates as a
-- result. Pre-existing 0-candidate players are ignored — we don't
-- block a claim because someone else was already boxed in.
--
-- reserved_row stays on player_profiles and is still used by
-- allocate_district_chunk to pick a fresh row for new joiners' starter
-- chunks. It's just no longer a lifetime expansion gate.
-- ─────────────────────────────────────────────────────────────────────


-- ── expansion_candidates: drop reserved-row filter ──────────────────
CREATE OR REPLACE FUNCTION public.expansion_candidates(p_player_id uuid)
RETURNS TABLE(chunk_x integer, chunk_y integer)
LANGUAGE plpgsql
AS $function$
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
  )
  SELECT n.cand_x, n.cand_y
  FROM neighbors n
  -- Exclude chunks anyone already owns.
  WHERE NOT EXISTS (
    SELECT 1 FROM public.district_chunks dc2
    WHERE dc2.chunk_x = n.cand_x AND dc2.chunk_y = n.cand_y
  )
  ORDER BY n.cand_y, n.cand_x;
END;
$function$;


-- ── expand_district: reachability invariant ─────────────────────────
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
  v_base_cost integer := 10000;
  v_is_candidate boolean;
  v_other record;
  v_pre_count integer;
  v_post_count integer;
BEGIN
  SELECT * INTO v_player FROM public.player_profiles WHERE id = v_uid FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Player not found'; END IF;

  v_cost := v_base_cost * v_player.chunks_owned * v_player.chunks_owned;

  IF v_player.money < v_cost THEN
    RAISE EXCEPTION 'Not enough money to expand (need %, have %)', v_cost, v_player.money;
  END IF;

  SELECT EXISTS (
    SELECT 1 FROM public.expansion_candidates(v_uid) ec
    WHERE ec.chunk_x = p_chunk_x AND ec.chunk_y = p_chunk_y
  ) INTO v_is_candidate;
  IF NOT v_is_candidate THEN
    RAISE EXCEPTION 'Chunk (%, %) is not a valid expansion candidate', p_chunk_x, p_chunk_y;
  END IF;

  -- Reachability invariant: walk every OTHER player who currently has
  -- ≥1 expansion candidate, simulate this claim, and ensure they STILL
  -- have ≥1 candidate. If any would be reduced to zero, refuse the
  -- claim — that player would be completely surrounded by other-owned
  -- chunks (and the wilderness past the world edge isn't a chunk).
  -- Players already at 0 candidates pre-claim are not made worse by
  -- this claim; we don't punish the claimant for someone else's
  -- prior boxing-in.
  FOR v_other IN
    SELECT pp.id, pp.display_name
    FROM public.player_profiles pp
    WHERE pp.id <> v_uid
      AND EXISTS (
        SELECT 1 FROM public.district_chunks dc WHERE dc.owner_player_id = pp.id
      )
  LOOP
    SELECT COUNT(*) INTO v_pre_count
    FROM public.expansion_candidates(v_other.id);

    IF v_pre_count = 0 THEN CONTINUE; END IF;

    SELECT COUNT(*) INTO v_post_count
    FROM public.expansion_candidates(v_other.id) ec
    WHERE NOT (ec.chunk_x = p_chunk_x AND ec.chunk_y = p_chunk_y);

    IF v_post_count = 0 THEN
      RAISE EXCEPTION
        'Claiming (%, %) would completely surround % — leave them an escape parcel and try elsewhere',
        p_chunk_x, p_chunk_y, v_other.display_name;
    END IF;
  END LOOP;

  v_alloc := public.allocate_district_chunk(v_uid, p_chunk_x, p_chunk_y);

  UPDATE public.player_profiles
  SET money = money - v_cost
  WHERE id = v_uid
  RETURNING * INTO v_player;

  INSERT INTO public.cash_transactions (player_id, source, amount, context)
  VALUES (v_uid, 'expansion_cost', -v_cost,
          jsonb_build_object('chunk_x', p_chunk_x, 'chunk_y', p_chunk_y));

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
