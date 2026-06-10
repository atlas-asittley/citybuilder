-- Cash ledger: a per-player ledger of every money-changing event so the
-- Treasury panel can show tax revenue + build costs + expansion costs
-- alongside the existing trade flow data.
--
-- Today the Treasury panel only sees what's in trade_transactions
-- (NPC + black market) and player_trade_offers (peer trade). Tax,
-- build cost, and expansion cost just modify player_profiles.money
-- directly with no audit trail.
--
-- Sources tracked here:
--   tax_revenue       (positive — _pp_run_tax)
--   build_cost        (negative — place_building)
--   expansion_cost    (negative — expand_district)
-- More sources can be added later (starting_grant, demolish_refund, etc.).

-- ── 1. Schema ───────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.cash_transactions (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  player_id   uuid NOT NULL REFERENCES public.player_profiles(id) ON DELETE CASCADE,
  source      text NOT NULL,
  amount      integer NOT NULL,
  context     jsonb,
  created_at  timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT cash_source_check CHECK (source IN (
    'tax_revenue', 'build_cost', 'expansion_cost', 'starting_grant', 'demolish_refund'
  ))
);

CREATE INDEX IF NOT EXISTS idx_cash_transactions_player_time
  ON public.cash_transactions (player_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_cash_transactions_player_source_time
  ON public.cash_transactions (player_id, source, created_at DESC);

ALTER TABLE public.cash_transactions ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS cash_transactions_select ON public.cash_transactions;
CREATE POLICY cash_transactions_select ON public.cash_transactions
  FOR SELECT USING (auth.uid() = player_id);

-- ── 2. _pp_run_tax: log each tax-collection cycle ────────
-- Logged AFTER the player_profiles update so all current-tick tax is
-- aggregated into one row per tick (less ledger noise than per-building).
CREATE OR REPLACE FUNCTION public._pp_run_tax(p_uid uuid, p_staffed_ids uuid[])
RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_now timestamptz := now();
  v_total integer := 0;
  v_b record;
  v_elapsed numeric;
  v_amt numeric;
BEGIN
  FOR v_b IN
    SELECT b.id, b.last_processed_at, bt.output_rate
    FROM public.buildings b
    JOIN public.building_types bt ON bt.key = b.building_type_key
    WHERE b.player_id = p_uid AND b.status = 'active' AND bt.category = 'tax'
      AND b.id = ANY(p_staffed_ids)
    FOR UPDATE OF b
  LOOP
    v_elapsed := EXTRACT(EPOCH FROM (v_now - v_b.last_processed_at));
    v_amt := FLOOR((v_elapsed / 60.0) * v_b.output_rate);
    IF v_amt > 0 THEN
      UPDATE public.player_profiles SET money = money + v_amt::integer WHERE id = p_uid;
      v_total := v_total + v_amt::integer;
    END IF;
    UPDATE public.buildings SET last_processed_at = v_now WHERE id = v_b.id;
  END LOOP;

  IF v_total > 0 THEN
    INSERT INTO public.cash_transactions (player_id, source, amount, context)
    VALUES (p_uid, 'tax_revenue', v_total, NULL);
  END IF;

  RETURN v_total;
END;
$$;
GRANT EXECUTE ON FUNCTION public._pp_run_tax(uuid, uuid[]) TO authenticated;

-- ── 3. place_building: log build cost ────────────────────
-- Wedged in alongside the existing `UPDATE money = money - build_cost`.
-- We rebuild the function around the new ledger insert.
CREATE OR REPLACE FUNCTION public.place_building(p_tile_id uuid, p_building_type_key text)
RETURNS json
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_bt record;
  v_tile record;
  v_player record;
  v_building_id uuid;
  v_worker_supply integer;
  v_workers_needed integer;
  v_road_connected boolean;
  v_path record;
  v_w int;
  v_h int;
  v_dx int;
  v_dy int;
  v_check_tile record;
  v_footprint_tile_ids uuid[] := ARRAY[]::uuid[];
BEGIN
  SELECT NULL::integer AS target_x, NULL::integer AS target_y, NULL::integer AS path_length
  INTO v_path;
  SELECT * INTO v_bt FROM public.building_types WHERE key = p_building_type_key AND is_active;
  IF NOT FOUND THEN RAISE EXCEPTION 'Unknown building type'; END IF;
  SELECT * INTO v_player FROM public.player_profiles WHERE id = v_uid;
  IF NOT FOUND THEN RAISE EXCEPTION 'Player not found'; END IF;
  IF v_bt.industry_key <> 'common' AND v_bt.industry_key <> v_player.industry_key THEN
    RAISE EXCEPTION 'You can only place buildings for your chosen industry';
  END IF;
  IF v_bt.unlocks_at_housing_tier IS NOT NULL
     AND v_player.highest_housing_tier_ever < v_bt.unlocks_at_housing_tier THEN
    RAISE EXCEPTION 'Locked: %', v_bt.name
      USING HINT = 'Reach housing tier ' || v_bt.unlocks_at_housing_tier || ' first';
  END IF;
  IF v_player.money < v_bt.build_cost THEN
    RAISE EXCEPTION 'Not enough money (need %, have %)', v_bt.build_cost, v_player.money;
  END IF;
  SELECT * INTO v_tile FROM public.map_tiles WHERE id = p_tile_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Tile not found'; END IF;

  v_w := COALESCE(v_bt.footprint_w, 1);
  v_h := COALESCE(v_bt.footprint_h, 1);

  FOR v_dx IN 0..(v_w - 1) LOOP
    FOR v_dy IN 0..(v_h - 1) LOOP
      SELECT * INTO v_check_tile FROM public.map_tiles
        WHERE x = v_tile.x + v_dx AND y = v_tile.y + v_dy
        FOR UPDATE;
      IF NOT FOUND THEN
        RAISE EXCEPTION 'Footprint extends off the map at (%, %)', v_tile.x + v_dx, v_tile.y + v_dy;
      END IF;
      IF v_check_tile.owner_player_id IS NULL THEN
        RAISE EXCEPTION 'Cannot build on wilderness — expand your district first';
      END IF;
      IF v_check_tile.owner_player_id <> v_uid THEN
        RAISE EXCEPTION 'Cannot build on another player''s district';
      END IF;
      IF NOT v_check_tile.buildable THEN
        RAISE EXCEPTION 'Tile (%, %) is not buildable', v_check_tile.x, v_check_tile.y;
      END IF;
      IF v_check_tile.occupied_building_id IS NOT NULL THEN
        RAISE EXCEPTION 'Tile (%, %) is already occupied', v_check_tile.x, v_check_tile.y;
      END IF;
      v_footprint_tile_ids := v_footprint_tile_ids || v_check_tile.id;
    END LOOP;
  END LOOP;

  IF v_bt.category = 'road' THEN
    SELECT EXISTS (
      SELECT 1 FROM public.buildings b2
      JOIN public.building_types bt2 ON bt2.key = b2.building_type_key
      WHERE bt2.category = 'road' AND b2.status = 'active' AND b2.player_id = v_uid
        AND ((b2.x = v_tile.x - 1 AND b2.y = v_tile.y)
             OR (b2.x = v_tile.x + 1 AND b2.y = v_tile.y)
             OR (b2.x = v_tile.x AND b2.y = v_tile.y - 1)
             OR (b2.x = v_tile.x AND b2.y = v_tile.y + 1))
    ) INTO v_road_connected;
    IF NOT v_road_connected THEN
      RAISE EXCEPTION 'Roads must connect to another of your roads';
    END IF;
  END IF;

  IF v_bt.category = 'housing' THEN
    INSERT INTO public.buildings (player_id, building_type_key, tile_id, x, y, housing_tier)
    VALUES (v_uid, p_building_type_key, p_tile_id, v_tile.x, v_tile.y, 0)
    RETURNING id INTO v_building_id;
  ELSE
    INSERT INTO public.buildings (player_id, building_type_key, tile_id, x, y)
    VALUES (v_uid, p_building_type_key, p_tile_id, v_tile.x, v_tile.y)
    RETURNING id INTO v_building_id;
  END IF;

  UPDATE public.map_tiles SET occupied_building_id = v_building_id
    WHERE id = ANY(v_footprint_tile_ids);

  IF v_bt.category = 'extractor' THEN
    SELECT * INTO v_path FROM public.find_nearest_unclaimed_resource(v_uid, v_tile.x, v_tile.y);
    IF v_path.path_length IS NOT NULL THEN
      UPDATE public.buildings
        SET target_x = v_path.target_x, target_y = v_path.target_y, path_length = v_path.path_length
      WHERE id = v_building_id;
      UPDATE public.map_tiles SET claimed_by_building_id = v_building_id
        WHERE x = v_path.target_x AND y = v_path.target_y;
    END IF;
  END IF;

  IF v_bt.category = 'road' THEN
    PERFORM public.recompute_extractor_paths(v_uid);
  END IF;

  v_worker_supply := 5 + public._pp_housing_supply(v_uid);
  v_workers_needed := public._pp_workers_needed(v_uid);

  UPDATE public.player_profiles
  SET money = money - v_bt.build_cost,
      worker_capacity = v_worker_supply,
      workers_used = LEAST(v_worker_supply, v_workers_needed)
  WHERE id = v_uid RETURNING * INTO v_player;

  -- Log the spend.
  IF v_bt.build_cost > 0 THEN
    INSERT INTO public.cash_transactions (player_id, source, amount, context)
    VALUES (v_uid, 'build_cost', -v_bt.build_cost,
            jsonb_build_object('building_type_key', p_building_type_key, 'building_id', v_building_id));
  END IF;

  RETURN json_build_object(
    'building_id', v_building_id,
    'money', v_player.money,
    'workers_used', v_player.workers_used,
    'worker_capacity', v_player.worker_capacity,
    'workers_needed', v_workers_needed,
    'labor_shortage', v_workers_needed > v_worker_supply,
    'extractor_target', CASE WHEN v_path.path_length IS NOT NULL
      THEN json_build_object('x', v_path.target_x, 'y', v_path.target_y, 'path_length', v_path.path_length)
      ELSE NULL END
  );
END;
$$;
GRANT EXECUTE ON FUNCTION public.place_building(uuid, text) TO authenticated;

-- ── 4. expand_district: log expansion cost ──────────────
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
$$;
GRANT EXECUTE ON FUNCTION public.expand_district(integer, integer) TO authenticated;
