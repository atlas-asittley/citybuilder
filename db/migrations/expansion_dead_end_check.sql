-- ─────────────────────────────────────────────────────────────────────────────
-- Expansion: extend reachability check to catch dead-end boxing (2026-05-28).
-- Also adds 'expansion_refund' to cash_source_check so bug-fix refunds can
-- be recorded in the ledger.
--
-- Prior behaviour: expand_district refused any claim that left another player
-- with *zero* expansion candidates — i.e., completely surrounded right now.
--
-- Gap: a claim that leaves a player with exactly ONE candidate is also
-- dangerous when that single candidate is itself a dead-end (claiming it would
-- leave the player at zero candidates). Drew's purchase of (-2, 4) left Max
-- with only (-1, 4), whose four orthogonal neighbours are all owned — so Max
-- would be permanently enclosed after taking their only remaining parcel.
--
-- Fix: when a claim would reduce another player to exactly 1 candidate,
-- additionally verify that the surviving candidate has ≥ 1 unclaimed
-- orthogonal neighbour (other than the tile being claimed now). If not, the
-- claim is rejected with the same "surrounding" error class.
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.expand_district(p_chunk_x integer, p_chunk_y integer)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
DECLARE
  v_uid         uuid := auth.uid();
  v_player      record;
  v_cost        integer;
  v_alloc       json;
  v_base_cost   integer := 10000;
  v_is_candidate boolean;
  v_other       record;
  v_pre_count   integer;
  v_post_count  integer;
  v_last_x      integer;
  v_last_y      integer;
  v_escape_count integer;
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
  -- claim — that player would be completely surrounded.
  -- Players already at 0 candidates pre-claim are not made worse; skip them.
  --
  -- Extended check (2026-05-28): when a claim reduces another player to
  -- exactly 1 candidate, verify that last candidate is not a dead-end.
  -- A dead-end candidate has no unclaimed orthogonal neighbour (other than
  -- the tile being claimed here). If the player takes that one remaining
  -- parcel they would be at zero candidates with no further escape.
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

    -- Dead-end check: if only one candidate remains, make sure it leads somewhere.
    IF v_post_count = 1 THEN
      SELECT ec.chunk_x, ec.chunk_y
      INTO v_last_x, v_last_y
      FROM public.expansion_candidates(v_other.id) ec
      WHERE NOT (ec.chunk_x = p_chunk_x AND ec.chunk_y = p_chunk_y)
      LIMIT 1;

      SELECT COUNT(*) INTO v_escape_count
      FROM (
        SELECT v_last_x + 1 AS nx, v_last_y AS ny
        UNION ALL SELECT v_last_x - 1, v_last_y
        UNION ALL SELECT v_last_x,     v_last_y + 1
        UNION ALL SELECT v_last_x,     v_last_y - 1
      ) neighbors
      WHERE NOT (nx = p_chunk_x AND ny = p_chunk_y)
        AND NOT EXISTS (
          SELECT 1 FROM public.district_chunks dc3
          WHERE dc3.chunk_x = nx AND dc3.chunk_y = ny
        );

      IF v_escape_count = 0 THEN
        RAISE EXCEPTION
          'Claiming (%, %) would leave % with only a dead-end parcel — they would be permanently surrounded',
          p_chunk_x, p_chunk_y, v_other.display_name;
      END IF;
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

-- Add expansion_refund as a valid ledger source for bug-fix refunds.
ALTER TABLE public.cash_transactions
  DROP CONSTRAINT IF EXISTS cash_source_check;

ALTER TABLE public.cash_transactions
  ADD CONSTRAINT cash_source_check CHECK (source = ANY (ARRAY[
    'tax_revenue', 'build_cost', 'expansion_cost', 'expansion_refund',
    'starting_grant', 'demolish_refund', 'upkeep', 'npc_trade',
    'p2p_trade', 'p2p_agreement', 'black_market', 'ledger_adjustment',
    'supply_contract'
  ]));
