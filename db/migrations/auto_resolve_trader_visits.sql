-- ── Auto-resolve trader visits during production tick ──
-- Trade should be a passive stream driven by per-resource policies, not a
-- "click Check All" chore. This patch folds visit resolution into the
-- 30-second production tick, so policies do all the work and the player
-- never has to think about clicking.
--
-- Three pieces:
--   1. _trader_is_unlocked(uid, trader_key) — server-side mirror of the
--      client's computeTraderUnlocks (river always, desert needs processor,
--      mountain needs 3+ buildings).
--   2. _pp_resolve_trader_visits(uid) — iterates unlocked traders and runs
--      the same WHILE loop as resolve_trader_visit. Uses the existing
--      _rtv_sell_phase / _rtv_buy_phase helpers.
--   3. process_production() — adds one PERFORM call to invoke the helper
--      before RETURN. Body is verbatim live source plus that one line.
--
-- The manual `resolve_trader_visit` RPC stays in place as a no-op fallback
-- (it'll find no due visits because process_production already drained
-- them), so existing client buttons don't break.

CREATE OR REPLACE FUNCTION public._trader_is_unlocked(
  p_player_id uuid, p_trader_key text
) RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
AS $$
DECLARE
  v_total_buildings integer;
BEGIN
  IF p_trader_key = 'river_traders' THEN
    RETURN true;
  ELSIF p_trader_key = 'desert_caravan' THEN
    RETURN EXISTS (
      SELECT 1 FROM public.buildings b
      JOIN public.building_types bt ON bt.key = b.building_type_key
      WHERE b.player_id = p_player_id
        AND b.status = 'active'
        AND bt.category = 'processor'
    );
  ELSIF p_trader_key = 'mountain_folk' THEN
    SELECT COUNT(*) INTO v_total_buildings
    FROM public.buildings
    WHERE player_id = p_player_id;
    RETURN v_total_buildings >= 3;
  END IF;
  RETURN false;
END;
$$;

CREATE OR REPLACE FUNCTION public._pp_resolve_trader_visits(p_player_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_trader record;
  v_last_visit timestamptz;
  v_interval interval;
  v_player_money integer;
  v_visit_at timestamptz;
  v_next_visit_at timestamptz;
  v_iterations integer;
  v_max_iterations constant integer := 50;
  v_sell record;
  v_buy record;
BEGIN
  -- Skip players who haven't unlocked the trade gate yet — they shouldn't
  -- be receiving trade visits at all.
  IF NOT public.is_trade_unlocked(p_player_id) THEN
    RETURN;
  END IF;

  SELECT money INTO v_player_money FROM public.player_profiles WHERE id = p_player_id;

  FOR v_trader IN
    SELECT * FROM public.traders WHERE is_active
  LOOP
    IF NOT public._trader_is_unlocked(p_player_id, v_trader.key) THEN
      CONTINUE;
    END IF;

    v_interval := (v_trader.visit_interval_minutes::text || ' minutes')::interval;

    SELECT visited_at INTO v_last_visit
    FROM public.trader_visits
    WHERE player_id = p_player_id AND trader_key = v_trader.key
    ORDER BY visited_at DESC
    LIMIT 1;

    IF v_last_visit IS NULL THEN
      SELECT created_at INTO v_last_visit FROM public.player_profiles WHERE id = p_player_id;
    END IF;

    v_next_visit_at := v_last_visit + v_interval;
    v_iterations := 0;

    WHILE v_next_visit_at <= now() AND v_iterations < v_max_iterations LOOP
      v_iterations := v_iterations + 1;
      v_visit_at := v_next_visit_at;

      SELECT * INTO v_sell
        FROM public._rtv_sell_phase(p_player_id, v_trader.key, v_trader.visit_capacity);
      IF v_sell.earned > 0 THEN
        UPDATE public.player_profiles SET money = money + v_sell.earned WHERE id = p_player_id;
        v_player_money := v_player_money + v_sell.earned;
      END IF;

      SELECT * INTO v_buy
        FROM public._rtv_buy_phase(
          p_player_id,
          v_trader.key,
          v_trader.visit_capacity - v_sell.capacity_used,
          v_player_money
        );
      IF v_buy.spent > 0 THEN
        UPDATE public.player_profiles SET money = money - v_buy.spent WHERE id = p_player_id;
        v_player_money := v_buy.money_out;
      END IF;

      INSERT INTO public.trader_visits
        (trader_key, player_id, capacity_total, capacity_used, summary, visited_at)
      VALUES
        (v_trader.key, p_player_id, v_trader.visit_capacity,
         v_sell.capacity_used + v_buy.capacity_used,
         v_sell.summary || v_buy.summary,
         v_visit_at);

      v_next_visit_at := v_visit_at + v_interval;
    END LOOP;
  END LOOP;
END;
$$;

-- Replace process_production with one new PERFORM call near the end.
-- Body is the verbatim live source; the only addition is the
-- "PERFORM public._pp_resolve_trader_visits(v_uid);" line right before
-- the RETURN.
CREATE OR REPLACE FUNCTION public.process_production()
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_base constant integer := 5;
  v_tavern_bonus integer;
  v_supply integer;
  v_staffing record;
  v_total_produced numeric := 0;
  v_total_money integer := 0;
  v_total_upkeep integer := 0;
  v_food_drained numeric := 0;
  v_evolution_events json[];
  v_operating_services uuid[];
  v_partial numeric;
  v_population numeric;
  v_crime numeric;
  v_productivity numeric;
BEGIN
  v_tavern_bonus := public._pp_tavern_bonus(v_uid);
  v_population := public._pp_update_population(v_uid);
  v_supply := FLOOR(v_population)::integer + v_tavern_bonus;

  SELECT staffed_ids, workers_needed, unstaffed_count
    INTO v_staffing
    FROM public._pp_staff_buildings(v_uid, v_supply);

  PERFORM public._pp_update_pollution(v_uid);

  v_productivity := public._pp_compute_productivity(v_uid);

  v_partial := public._pp_run_extractors(v_uid, v_staffing.staffed_ids);
  v_total_produced := v_total_produced + v_partial;
  v_partial := public._pp_run_food_extractors(v_uid, v_staffing.staffed_ids);
  v_total_produced := v_total_produced + v_partial;
  PERFORM public._pp_bump_boosters(v_uid, v_staffing.staffed_ids);
  v_partial := public._pp_run_processors(v_uid, v_staffing.staffed_ids);
  v_total_produced := v_total_produced + v_partial;

  PERFORM public._pp_run_agreements(v_uid);

  v_operating_services := public._pp_run_services(v_uid, v_staffing.staffed_ids);
  v_total_money := public._pp_run_tax(v_uid, v_staffing.staffed_ids);
  v_total_upkeep := public._pp_run_upkeep(v_uid, v_staffing.staffed_ids);

  v_food_drained := public._pp_drain_housing_food(v_uid);

  v_crime := public._pp_update_crime(v_uid);
  PERFORM public._pp_update_desirability(v_uid);
  v_evolution_events := public._pp_evolve_housing(v_uid, v_operating_services);

  v_supply := FLOOR(v_population)::integer + v_tavern_bonus;
  UPDATE public.player_profiles
  SET worker_capacity = v_supply,
      workers_used = LEAST(v_supply, v_staffing.workers_needed)
  WHERE id = v_uid;

  -- Auto-resolve trader visits for any unlocked trader whose cooldown has
  -- elapsed. Policies set in City → Resources do the actual selling/buying.
  PERFORM public._pp_resolve_trader_visits(v_uid);

  RETURN json_build_object(
    'total_produced', v_total_produced,
    'total_money_collected', v_total_money,
    'total_upkeep_paid', v_total_upkeep,
    'food_drained', v_food_drained,
    'evolution_events', array_to_json(v_evolution_events),
    'worker_supply', v_supply,
    'workers_needed', v_staffing.workers_needed,
    'unstaffed_count', v_staffing.unstaffed_count,
    'population', v_population,
    'happiness', (SELECT happiness FROM public.player_profiles WHERE id = v_uid),
    'crime', v_crime,
    'migration_rate', (SELECT migration_rate FROM public.player_profiles WHERE id = v_uid),
    'productivity', v_productivity
  );
END;
$function$;
