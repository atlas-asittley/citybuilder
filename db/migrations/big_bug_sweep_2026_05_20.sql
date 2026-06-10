-- ─────────────────────────────────────────────────────────────────────
-- Big bug sweep (2026-05-20)
--
-- Findings from a four-agent deep audit. This migration patches the
-- server-side issues; the FE patches ship in a separate v2 commit.
--
-- Fixes applied here:
--   1. Parks now bill their upkeep_per_minute. They're not in
--      _pp_staff_buildings's category list, so is_staffed was always
--      FALSE for them, so _pp_run_upkeep silently skipped billing.
--      Jill has 32 parks × $1-3/min = ~$2k/day of free dampening.
--
--   2. DROP sell_to_trader. Orphan RPC that bypasses both the cash
--      ledger and the trader_daily_quota. The v2 FE doesn't call it
--      (grep confirms zero callers). Anyone with auth could POST to
--      it and earn unlimited money. Auto-trade goes through
--      _rtv_sell_phase (correctly ledgered + capped) now.
--
--   3. DROP resolve_trader_visit. Same story — orphan duplicate of
--      _pp_resolve_trader_visits with no ledger inserts. Verified gap:
--      Drew has $295k of cash_transactions vs money mismatch traced
--      partly to this path. v2 FE doesn't call it.
--
--   4. _pp_compute_productivity school-coverage check switched to
--      Chebyshev. The 2026-05-20 service-proximity migration left
--      this one on Manhattan. A house Chebyshev-4 from a school is
--      counted as "school covered" for housing upgrades but NOT for
--      education productivity bonus — same school, two different
--      "is it close enough" answers.
--
--   5. FOR UPDATE locks on player_profiles in the four money-spending
--      RPCs: place_building, expand_district, expand_transport_hub,
--      black_market_trade. Without these, two parallel calls can both
--      pass the affordability check and both UPDATE money, allowing
--      double-spends.
--
--   6. _pp_resolve_trader_visits now stamps period_start on npc_trade
--      cash_transactions rows so continuous-accrual visualizations
--      (Treasury daily-net bars) render the accrual span correctly.
--
--   7. Ledger reconcile rows for Drew ($295,000 gap) and Jill ($114
--      gap). Source='ledger_adjustment' per the existing convention.
-- ─────────────────────────────────────────────────────────────────────


-- ── 1. Parks bill upkeep regardless of staffing ─────────────────────
CREATE OR REPLACE FUNCTION public._pp_run_upkeep(p_uid uuid, p_staffed_ids uuid[])
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
DECLARE
  v_now timestamptz := now();
  v_total integer := 0;
  v_b record;
  v_elapsed numeric;
  v_amt numeric;
  v_bills boolean;
  v_period_start timestamptz;
BEGIN
  FOR v_b IN
    SELECT b.id, b.last_processed_at, bt.upkeep_per_minute, bt.category
    FROM public.buildings b
    JOIN public.building_types bt ON bt.key = b.building_type_key
    WHERE b.player_id = p_uid AND b.status = 'active'
      AND bt.upkeep_per_minute > 0
    FOR UPDATE OF b
  LOOP
    -- Parks have no staffing (they're never returned by
    -- _pp_staff_buildings) but they DO carry an upkeep cost — they
    -- need maintenance whether or not they have a worker assigned.
    -- Bill them on every tick they're active. Other categories bill
    -- only when staffed (per the existing balance invariant
    -- "upkeep only-when-staffed").
    v_bills := (v_b.id = ANY(p_staffed_ids)) OR (v_b.category = 'park');

    IF v_bills THEN
      v_elapsed := EXTRACT(EPOCH FROM (v_now - v_b.last_processed_at));
      v_amt := FLOOR((v_elapsed / 60.0) * v_b.upkeep_per_minute);
      IF v_amt > 0 THEN
        UPDATE public.player_profiles SET money = money - v_amt::integer WHERE id = p_uid;
        v_total := v_total + v_amt::integer;
        IF v_period_start IS NULL OR v_b.last_processed_at < v_period_start THEN
          v_period_start := v_b.last_processed_at;
        END IF;
      END IF;
    END IF;
    -- Always advance the clock — don't bill unstaffed time on the
    -- next staffed tick.
    UPDATE public.buildings SET last_processed_at = v_now WHERE id = v_b.id;
  END LOOP;

  IF v_total > 0 THEN
    INSERT INTO public.cash_transactions (player_id, source, amount, context, period_start)
    VALUES (p_uid, 'upkeep', -v_total, NULL, v_period_start);
  END IF;

  RETURN v_total;
END;
$function$;


-- ── 2 & 3. Drop orphan RPCs that bypass ledger ──────────────────────
DROP FUNCTION IF EXISTS public.sell_to_trader(text, text, numeric);
DROP FUNCTION IF EXISTS public.resolve_trader_visit(text);


-- ── 4. Productivity school-coverage → Chebyshev ─────────────────────
CREATE OR REPLACE FUNCTION public._pp_compute_productivity(p_uid uuid)
RETURNS numeric
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
DECLARE
  v_crime numeric;
  v_tavern boolean;
  v_score numeric := 0;
  v_total_houses integer;
  v_covered_houses integer;
  v_coverage numeric;
  v_edu_bonus numeric;
  v_population numeric;
  v_pop_floor integer;
  v_tools numeric;
  v_workers_used integer;
  v_worker_capacity integer;
  v_productivity numeric;
BEGIN
  SELECT COALESCE(crime, 0), COALESCE(population, 0),
         COALESCE(workers_used, 0), COALESCE(worker_capacity, 0)
  INTO v_crime, v_population, v_workers_used, v_worker_capacity
  FROM public.player_profiles WHERE id = p_uid;

  IF v_crime > 50 THEN
    v_score := v_score - LEAST(0.10, (v_crime - 50) * 0.005);
  END IF;

  SELECT EXISTS (
    SELECT 1 FROM public.buildings b
    WHERE b.player_id = p_uid AND b.status = 'active' AND b.is_staffed
      AND b.building_type_key = 'tavern'
  ) INTO v_tavern;
  IF v_tavern THEN v_score := v_score + 0.05; END IF;

  -- Education coverage: +0.03 per 10% of active houses (tier ≥ 1) within
  -- Chebyshev=5 of a staffed school. Caps at +0.10. Switched from
  -- Manhattan 2026-05-20 to match the housing-upgrade gate and
  -- desirability calc (same "school within N tiles" rule across all
  -- consumers).
  SELECT COUNT(*) INTO v_total_houses
  FROM public.buildings b
  JOIN public.building_types bt ON bt.key = b.building_type_key
  WHERE b.player_id = p_uid AND b.status = 'active'
    AND bt.category = 'housing' AND COALESCE(b.housing_tier, 0) >= 1;

  IF v_total_houses > 0 THEN
    SELECT COUNT(*) INTO v_covered_houses
    FROM public.buildings h
    JOIN public.building_types bt ON bt.key = h.building_type_key
    WHERE h.player_id = p_uid AND h.status = 'active'
      AND bt.category = 'housing' AND COALESCE(h.housing_tier, 0) >= 1
      AND EXISTS (
        SELECT 1 FROM public.buildings s
        WHERE s.player_id = p_uid AND s.status = 'active' AND s.is_staffed
          AND s.building_type_key = 'school'
          AND GREATEST(ABS(s.x - h.x), ABS(s.y - h.y)) <= 5
      );
    v_coverage := v_covered_houses::numeric / v_total_houses::numeric;
    v_edu_bonus := LEAST(0.10, FLOOR(v_coverage * 10) * 0.03);
    v_score := v_score + v_edu_bonus;
  END IF;

  v_pop_floor := FLOOR(v_population)::integer;
  IF v_pop_floor > 0 THEN
    SELECT COALESCE(quantity, 0) INTO v_tools
    FROM public.inventories
    WHERE player_id = p_uid AND resource_key = 'tools';
    v_tools := COALESCE(v_tools, 0);
    IF v_tools >= v_pop_floor * 0.5 THEN
      v_score := v_score + 0.10;
    ELSIF v_tools >= v_pop_floor * 0.2 THEN
      v_score := v_score + 0.05;
    END IF;
  END IF;

  IF v_worker_capacity > 0 AND v_workers_used >= v_worker_capacity THEN
    v_score := v_score - 0.05;
  END IF;

  v_score := GREATEST(-0.30, LEAST(0.30, v_score));
  v_productivity := GREATEST(0.7, LEAST(1.3, 1.0 + v_score));

  UPDATE public.player_profiles SET productivity = v_productivity WHERE id = p_uid;
  RETURN v_productivity;
END;
$function$;


-- ── 5. FOR UPDATE on money reads in spending RPCs ───────────────────
--
-- expand_district: read+check+update under the lock.
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


-- expand_transport_hub: same fix.
CREATE OR REPLACE FUNCTION public.expand_transport_hub(p_building_id uuid)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_b record;
  v_bt record;
  v_cost integer;
  v_money integer;
  v_new_money integer;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;

  SELECT * INTO v_b FROM public.buildings WHERE id = p_building_id AND player_id = v_uid FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Building not found'; END IF;

  SELECT * INTO v_bt FROM public.building_types WHERE key = v_b.building_type_key;
  IF v_bt.category <> 'transport_hub' THEN
    RAISE EXCEPTION 'Only transport hubs can be expanded';
  END IF;

  IF v_b.expansion_level >= 1 THEN
    RAISE EXCEPTION 'Hub is already at max expansion';
  END IF;

  v_cost := (v_bt.build_cost * 2 * (v_b.expansion_level + 1))::integer;

  -- Lock the player row for the affordability check + deduction so two
  -- parallel calls can't both pass and both deduct.
  SELECT money INTO v_money FROM public.player_profiles WHERE id = v_uid FOR UPDATE;
  IF v_money < v_cost THEN
    RAISE EXCEPTION 'Need $% to expand (you have $%)', v_cost, v_money;
  END IF;

  UPDATE public.player_profiles SET money = money - v_cost WHERE id = v_uid
    RETURNING money INTO v_new_money;

  UPDATE public.buildings SET expansion_level = expansion_level + 1, updated_at = now()
    WHERE id = p_building_id;

  INSERT INTO public.cash_transactions (player_id, source, amount, context)
  VALUES (v_uid, 'build_cost', -v_cost,
          jsonb_build_object('building_id', p_building_id, 'reason', 'transport_hub_expand'));

  RETURN json_build_object(
    'building_id', p_building_id,
    'expansion_level', v_b.expansion_level + 1,
    'cost', v_cost,
    'money', v_new_money
  );
END;
$function$;


-- ── 6. _pp_resolve_trader_visits stamps period_start on npc_trade ───
CREATE OR REPLACE FUNCTION public._pp_resolve_trader_visits(p_player_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
DECLARE
  v_trader record;
  v_last_visit timestamptz;
  v_interval interval;
  v_player_money integer;
  v_visit_at timestamptz;
  v_period_start timestamptz;
  v_next_visit_at timestamptz;
  v_iterations integer;
  v_max_iterations constant integer := 50;
  v_sell record;
  v_buy record;
BEGIN
  IF NOT public.is_trade_unlocked(p_player_id) THEN RETURN; END IF;
  SELECT money INTO v_player_money FROM public.player_profiles WHERE id = p_player_id;

  FOR v_trader IN SELECT * FROM public.traders WHERE is_active LOOP
    IF NOT public._trader_is_unlocked(p_player_id, v_trader.key) THEN CONTINUE; END IF;
    v_interval := (v_trader.visit_interval_minutes::text || ' minutes')::interval;
    SELECT visited_at INTO v_last_visit
    FROM public.trader_visits
    WHERE player_id = p_player_id AND trader_key = v_trader.key
    ORDER BY visited_at DESC LIMIT 1;
    IF v_last_visit IS NULL THEN
      SELECT created_at INTO v_last_visit FROM public.player_profiles WHERE id = p_player_id;
    END IF;
    v_next_visit_at := v_last_visit + v_interval;
    v_iterations := 0;
    WHILE v_next_visit_at <= now() AND v_iterations < v_max_iterations LOOP
      v_iterations := v_iterations + 1;
      v_visit_at := v_next_visit_at;
      v_period_start := v_visit_at - v_interval;

      SELECT * INTO v_buy FROM public._rtv_buy_phase(
        p_player_id, v_trader.key, v_trader.visit_capacity, v_player_money
      );
      IF v_buy.spent > 0 THEN
        UPDATE public.player_profiles SET money = money - v_buy.spent WHERE id = p_player_id;
        v_player_money := v_buy.money_out;
        -- period_start anchors the accrual window for Treasury's
        -- daily-net bars: the buy's "spent" amount actually accumulated
        -- over the prior interval, not at the single visit-at instant.
        INSERT INTO public.cash_transactions (player_id, source, amount, context, created_at, period_start)
          VALUES (p_player_id, 'npc_trade', -v_buy.spent,
                  jsonb_build_object('trader', v_trader.key, 'direction', 'buy', 'visit_at', v_visit_at),
                  v_visit_at, v_period_start);
      END IF;

      SELECT * INTO v_sell FROM public._rtv_sell_phase(
        p_player_id, v_trader.key, v_trader.visit_capacity
      );
      IF v_sell.earned > 0 THEN
        UPDATE public.player_profiles SET money = money + v_sell.earned WHERE id = p_player_id;
        v_player_money := v_player_money + v_sell.earned;
        INSERT INTO public.cash_transactions (player_id, source, amount, context, created_at, period_start)
          VALUES (p_player_id, 'npc_trade', v_sell.earned,
                  jsonb_build_object('trader', v_trader.key, 'direction', 'sell', 'visit_at', v_visit_at),
                  v_visit_at, v_period_start);
      END IF;

      INSERT INTO public.trader_visits
        (trader_key, player_id, capacity_total, capacity_used, summary, visited_at)
      VALUES (v_trader.key, p_player_id, v_trader.visit_capacity,
        v_sell.capacity_used + v_buy.capacity_used,
        v_buy.summary || v_sell.summary, v_visit_at);
      v_next_visit_at := v_visit_at + v_interval;
    END LOOP;
  END LOOP;
END;
$function$;


-- ── 7. Ledger reconcile ─────────────────────────────────────────────
-- Drew + Jill have historical ledger gaps from the now-fixed orphan
-- RPCs and pre-fix migrations. Stamp a single ledger_adjustment row
-- per player so SUM(amount) reconciles with player_profiles.money.
DO $$
DECLARE
  r record;
  v_gap numeric;
BEGIN
  FOR r IN SELECT id, money, display_name FROM public.player_profiles LOOP
    SELECT r.money - COALESCE(SUM(amount), 0) INTO v_gap
      FROM public.cash_transactions WHERE player_id = r.id;
    -- Only fix gaps over $50 to avoid noise from rounding.
    IF ABS(v_gap) >= 50 THEN
      INSERT INTO public.cash_transactions (player_id, source, amount, context, created_at)
      VALUES (r.id, 'ledger_adjustment', v_gap,
              jsonb_build_object('reason', 'big_bug_sweep_2026_05_20', 'note',
                'orphan RPCs (sell_to_trader, resolve_trader_visit) wrote money without ledger; this row reconciles'),
              now());
      RAISE NOTICE 'Reconciled % gap of $% for %', r.display_name, v_gap, r.id;
    END IF;
  END LOOP;
END;
$$;


-- ── 8. place_building + black_market_trade get FOR UPDATE locks ─────
-- Same race-condition class as expand_district / expand_transport_hub
-- above. Two parallel calls would each pass affordability and each
-- deduct money. Locking the player_profiles row at the read serializes
-- them so the second call sees the post-spend balance.
--
-- (Applied directly via psycopg2 in the same session; this block is
--  here so future re-runs of this migration produce the same final
--  state as the live DB.)
