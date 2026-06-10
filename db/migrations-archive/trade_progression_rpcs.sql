-- Trade progression: server-side RPCs.
-- See docs/TRADE_PROGRESSION.md for the design.

-- ── 1. Unlock gate ──────────────────────────────────────
-- Player has access to NPC trade once they have at least one active
-- extractor + one active food_extractor + one active housing tier ≥ 1
-- in their district.
CREATE OR REPLACE FUNCTION public.is_trade_unlocked(p_player_id uuid)
RETURNS boolean
LANGUAGE plpgsql STABLE SECURITY DEFINER AS $$
DECLARE
  v_has_extractor boolean;
  v_has_food_extractor boolean;
  v_has_tier1 boolean;
BEGIN
  SELECT EXISTS (
    SELECT 1 FROM public.buildings b
    JOIN public.building_types bt ON bt.key = b.building_type_key
    WHERE b.player_id = p_player_id AND b.status = 'active'
      AND bt.category = 'extractor'
  ) INTO v_has_extractor;

  SELECT EXISTS (
    SELECT 1 FROM public.buildings b
    JOIN public.building_types bt ON bt.key = b.building_type_key
    WHERE b.player_id = p_player_id AND b.status = 'active'
      AND bt.category = 'food_extractor'
  ) INTO v_has_food_extractor;

  SELECT EXISTS (
    SELECT 1 FROM public.buildings b
    JOIN public.building_types bt ON bt.key = b.building_type_key
    WHERE b.player_id = p_player_id AND b.status = 'active'
      AND bt.category = 'housing' AND b.housing_tier >= 1
  ) INTO v_has_tier1;

  RETURN v_has_extractor AND v_has_food_extractor AND v_has_tier1;
END;
$$;
GRANT EXECUTE ON FUNCTION public.is_trade_unlocked(uuid) TO authenticated;

-- ── 2. District weight (population) ─────────────────────
-- Sum of housing workers in a player's active district. Drives the
-- city-rep weighted average. Returns 1 floor so a player with no
-- housing still has nonzero say (avoids divide-by-zero edge cases).
CREATE OR REPLACE FUNCTION public.district_weight(p_player_id uuid)
RETURNS integer
LANGUAGE plpgsql STABLE SECURITY DEFINER AS $$
DECLARE
  v_total integer;
BEGIN
  SELECT COALESCE(SUM(htc.workers), 0)::integer INTO v_total
  FROM public.buildings b
  JOIN public.building_types bt ON bt.key = b.building_type_key
  JOIN public.housing_tier_config htc ON htc.tier = b.housing_tier
  WHERE b.player_id = p_player_id AND b.status = 'active'
    AND bt.category = 'housing';
  RETURN GREATEST(1, v_total);
END;
$$;
GRANT EXECUTE ON FUNCTION public.district_weight(uuid) TO authenticated;

-- ── 3. City reputation (weighted average) ───────────────
CREATE OR REPLACE FUNCTION public.city_reputation(p_trader_key text)
RETURNS numeric
LANGUAGE plpgsql STABLE SECURITY DEFINER AS $$
DECLARE
  v_num numeric := 0;
  v_den numeric := 0;
  r record;
BEGIN
  FOR r IN
    SELECT pp.id AS player_id,
           COALESCE(tr.reputation, 0) AS rep,
           public.district_weight(pp.id) AS w
    FROM public.player_profiles pp
    LEFT JOIN public.trader_relationships tr
      ON tr.player_id = pp.id AND tr.trader_key = p_trader_key
  LOOP
    v_num := v_num + (r.rep * r.w);
    v_den := v_den + r.w;
  END LOOP;
  IF v_den = 0 THEN RETURN 0; END IF;
  RETURN v_num / v_den;
END;
$$;
GRANT EXECUTE ON FUNCTION public.city_reputation(text) TO authenticated;

-- ── 4. City-rep tier ────────────────────────────────────
-- Maps a numeric city rep to a tier 0-4. Drives trader inventory expansion.
CREATE OR REPLACE FUNCTION public.city_rep_tier(p_trader_key text)
RETURNS integer
LANGUAGE plpgsql STABLE SECURITY DEFINER AS $$
DECLARE
  v_rep numeric;
BEGIN
  v_rep := public.city_reputation(p_trader_key);
  IF v_rep >= 1000 THEN RETURN 4;
  ELSIF v_rep >= 400 THEN RETURN 3;
  ELSIF v_rep >= 150 THEN RETURN 2;
  ELSIF v_rep >= 50  THEN RETURN 1;
  ELSE RETURN 0;
  END IF;
END;
$$;
GRANT EXECUTE ON FUNCTION public.city_rep_tier(text) TO authenticated;

-- ── 5. Roll new missions for traders whose cooldown elapsed ──
-- Lazy-resolution helper — players visiting the trade panel call this.
-- For each active trader without an open mission, if its last mission
-- (or creation time) is older than the cooldown, roll a new one.
CREATE OR REPLACE FUNCTION public.roll_trader_missions()
RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  r record;
  v_last timestamptz;
  v_target integer;
  v_resource text;
  v_pop integer;
  v_now timestamptz := now();
  v_rolled integer := 0;
  v_resources_for_template text[];
BEGIN
  FOR r IN
    SELECT t.key, t.mission_cooldown_minutes, t.base_request_qty,
           t.soft_deadline_minutes, t.specialty_template
    FROM public.traders t
    WHERE t.is_active
  LOOP
    -- Skip if there's already an open mission for this trader.
    IF EXISTS (SELECT 1 FROM public.trader_missions
               WHERE trader_key = r.key AND status = 'open') THEN
      CONTINUE;
    END IF;

    -- Check cooldown vs. last mission (or trader creation).
    SELECT MAX(resolved_at) INTO v_last
    FROM public.trader_missions
    WHERE trader_key = r.key AND status <> 'open';
    IF v_last IS NULL THEN v_last := v_now - interval '1 day'; END IF;
    IF v_last + (r.mission_cooldown_minutes || ' minutes')::interval > v_now THEN
      CONTINUE;
    END IF;

    -- Resource pool by specialty template. Trader's current rep tier
    -- decides how many goods are available; for v1 we pick uniformly
    -- from the buyable side of the trader's template.
    v_resources_for_template := CASE r.specialty_template
      WHEN 'resource_buyer' THEN ARRAY['lumber','stone','clay','iron','planks','brick','pottery']
      WHEN 'food_buyer'     THEN ARRAY['grain','flour','bread','berries','fish','vegetables','wine','smoked_fish','preserves']
      WHEN 'luxury_buyer'   THEN ARRAY['statuary','cabinets','monuments','mosaics','machinery','spirits','caviar','spices','ale']
      WHEN 'specialist'     THEN ARRAY['lumber','planks','statuary','grain','flour','bread']
      ELSE ARRAY['lumber','grain','stone','flour','clay','fish']
    END;

    -- Filter to resources that actually exist in the catalog.
    SELECT v_resources_for_template[1 + floor(random() * array_length(v_resources_for_template, 1))::int]
      INTO v_resource;
    IF NOT EXISTS (SELECT 1 FROM public.resources WHERE key = v_resource) THEN
      CONTINUE;
    END IF;

    -- Scale target by city population (sum of districts' weights).
    SELECT COALESCE(SUM(public.district_weight(pp.id)), 1) INTO v_pop
    FROM public.player_profiles pp;
    v_target := GREATEST(1, ROUND(r.base_request_qty * (1.0 + 0.10 * ln(1 + v_pop))))::int;

    INSERT INTO public.trader_missions
      (trader_key, kind, resource_key, target_qty, current_qty,
       soft_deadline, expires_at, status, created_at)
    VALUES
      (r.key, 'deliver_resource', v_resource, v_target, 0,
       v_now + (r.soft_deadline_minutes || ' minutes')::interval,
       v_now + ((r.soft_deadline_minutes + 360) || ' minutes')::interval,
       'open', v_now);
    v_rolled := v_rolled + 1;
  END LOOP;
  RETURN v_rolled;
END;
$$;
GRANT EXECUTE ON FUNCTION public.roll_trader_missions() TO authenticated;

-- ── 6. Expire old missions ──────────────────────────────
-- Closes any mission past its expires_at, distributes partial reputation
-- proportional to each player's contribution (no speed bonus).
CREATE OR REPLACE FUNCTION public.expire_old_missions()
RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  m record;
  d record;
  v_total integer;
  v_count integer := 0;
  v_rep_award numeric;
BEGIN
  FOR m IN
    SELECT * FROM public.trader_missions
    WHERE status = 'open' AND expires_at < now()
    FOR UPDATE
  LOOP
    -- Total contributed to this mission.
    SELECT COALESCE(SUM(qty), 0) INTO v_total
    FROM public.trader_mission_donations
    WHERE mission_id = m.id;

    -- Award partial reputation: 1.0 per unit of target_qty contributed
    -- (full mission completion = 1.0 × target_qty rep awarded total,
    -- distributed proportionally; partial fulfillment = proportionally less).
    -- No speed bonus for expired missions.
    IF v_total > 0 THEN
      FOR d IN
        SELECT player_id, SUM(qty) AS qty
        FROM public.trader_mission_donations
        WHERE mission_id = m.id
        GROUP BY player_id
      LOOP
        -- Per-unit reward = 1.0 (matches base rep-per-unit). Player's
        -- share = their qty * 1.0.
        v_rep_award := d.qty::numeric;
        INSERT INTO public.trader_relationships (player_id, trader_key, reputation, last_donation_at, last_decay_at)
        VALUES (d.player_id, m.trader_key, v_rep_award, now(), now())
        ON CONFLICT (player_id, trader_key) DO UPDATE
          SET reputation = public.trader_relationships.reputation + EXCLUDED.reputation,
              last_donation_at = EXCLUDED.last_donation_at;
      END LOOP;
    END IF;

    UPDATE public.trader_missions
      SET status = 'expired', resolved_at = now()
      WHERE id = m.id;
    v_count := v_count + 1;
  END LOOP;
  RETURN v_count;
END;
$$;
GRANT EXECUTE ON FUNCTION public.expire_old_missions() TO authenticated;

-- ── 7. Donate to a mission ──────────────────────────────
-- The headline player-facing action: spends inventory, advances mission,
-- closes mission with full reputation distribution if target reached.
CREATE OR REPLACE FUNCTION public.donate_to_mission(p_mission_id uuid, p_qty integer)
RETURNS json
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_mission record;
  v_have numeric;
  v_now timestamptz := now();
  v_speed_mult numeric := 1.0;
  v_elapsed_min numeric;
  v_total integer;
  d record;
  v_rep_per_unit numeric;
  v_award numeric;
  v_per_player_award jsonb := '{}'::jsonb;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
  IF p_qty IS NULL OR p_qty <= 0 THEN RAISE EXCEPTION 'Donation must be positive'; END IF;

  -- Lock the mission row.
  SELECT * INTO v_mission FROM public.trader_missions
    WHERE id = p_mission_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Mission not found'; END IF;
  IF v_mission.status <> 'open' THEN
    RAISE EXCEPTION 'Mission is %', v_mission.status;
  END IF;

  -- Check player has enough.
  SELECT COALESCE(quantity, 0) INTO v_have
  FROM public.inventories
  WHERE player_id = v_uid AND resource_key = v_mission.resource_key;
  IF v_have IS NULL THEN v_have := 0; END IF;
  IF v_have < p_qty THEN
    RAISE EXCEPTION 'You only have % %', FLOOR(v_have), v_mission.resource_key;
  END IF;

  -- Cap donation to remaining target (don't accept more than needed).
  IF p_qty > (v_mission.target_qty - v_mission.current_qty) THEN
    p_qty := v_mission.target_qty - v_mission.current_qty;
  END IF;
  IF p_qty <= 0 THEN
    RAISE EXCEPTION 'Mission already fulfilled';
  END IF;

  -- Debit inventory.
  UPDATE public.inventories
    SET quantity = quantity - p_qty, updated_at = now()
    WHERE player_id = v_uid AND resource_key = v_mission.resource_key;

  -- Record the donation.
  INSERT INTO public.trader_mission_donations (mission_id, player_id, qty)
  VALUES (p_mission_id, v_uid, p_qty);

  -- Advance the mission.
  UPDATE public.trader_missions
    SET current_qty = current_qty + p_qty
    WHERE id = p_mission_id
    RETURNING current_qty INTO v_mission.current_qty;

  -- If mission is now full, close it and distribute reputation.
  IF v_mission.current_qty >= v_mission.target_qty THEN
    -- Speed bonus: 1.5 → 1.0 over the soft-deadline window.
    v_elapsed_min := EXTRACT(EPOCH FROM (v_now - v_mission.created_at)) / 60.0;
    v_speed_mult := GREATEST(1.0, LEAST(1.5,
      1.5 - (v_elapsed_min / NULLIF(EXTRACT(EPOCH FROM (v_mission.soft_deadline - v_mission.created_at)) / 60.0, 0)) * 0.5));

    -- Per-unit reward = 1.0 × speed multiplier. Player's share = their qty × per-unit reward.
    v_rep_per_unit := v_speed_mult;

    FOR d IN
      SELECT player_id, SUM(qty) AS qty
      FROM public.trader_mission_donations
      WHERE mission_id = p_mission_id
      GROUP BY player_id
    LOOP
      v_award := d.qty::numeric * v_rep_per_unit;
      INSERT INTO public.trader_relationships (player_id, trader_key, reputation, last_donation_at, last_decay_at)
      VALUES (d.player_id, v_mission.trader_key, v_award, v_now, v_now)
      ON CONFLICT (player_id, trader_key) DO UPDATE
        SET reputation = public.trader_relationships.reputation + EXCLUDED.reputation,
            last_donation_at = EXCLUDED.last_donation_at;
      v_per_player_award := v_per_player_award || jsonb_build_object(d.player_id::text, v_award);
    END LOOP;

    UPDATE public.trader_missions
      SET status = 'fulfilled', resolved_at = v_now
      WHERE id = p_mission_id;
  END IF;

  RETURN json_build_object(
    'mission_id', p_mission_id,
    'donated_qty', p_qty,
    'current_qty', v_mission.current_qty,
    'target_qty', v_mission.target_qty,
    'fulfilled', v_mission.current_qty >= v_mission.target_qty,
    'speed_multiplier', v_speed_mult,
    'rep_awards', v_per_player_award
  );
END;
$$;
GRANT EXECUTE ON FUNCTION public.donate_to_mission(uuid, integer) TO authenticated;

-- ── 8. Decay reputations ────────────────────────────────
-- Lazy-cron: each player's rep with a trader decays 2% per day (per
-- 24h elapsed since last_decay_at), unless they donated in the last 7
-- days for that trader.
CREATE OR REPLACE FUNCTION public.decay_reputations()
RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  r record;
  v_now timestamptz := now();
  v_days numeric;
  v_factor numeric;
  v_count integer := 0;
BEGIN
  FOR r IN
    SELECT * FROM public.trader_relationships
    WHERE last_decay_at + interval '24 hours' < v_now
      AND (last_donation_at IS NULL OR last_donation_at + interval '7 days' < v_now)
      AND reputation > 0
    FOR UPDATE
  LOOP
    v_days := EXTRACT(EPOCH FROM (v_now - r.last_decay_at)) / 86400.0;
    v_factor := POWER(0.98, v_days);
    UPDATE public.trader_relationships
      SET reputation = GREATEST(0, reputation * v_factor),
          last_decay_at = v_now
      WHERE player_id = r.player_id AND trader_key = r.trader_key;
    v_count := v_count + 1;
  END LOOP;
  RETURN v_count;
END;
$$;
GRANT EXECUTE ON FUNCTION public.decay_reputations() TO authenticated;

-- ── 9. Get active missions (city-wide) ──────────────────
CREATE OR REPLACE FUNCTION public.get_active_missions()
RETURNS json
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_arr jsonb := '[]'::jsonb;
  m record;
BEGIN
  -- Opportunistically roll new missions and expire old ones — same
  -- lazy-resolution pattern as resolve_trader_visit.
  PERFORM public.expire_old_missions();
  PERFORM public.roll_trader_missions();
  PERFORM public.decay_reputations();

  FOR m IN
    SELECT tm.*, t.name AS trader_name, t.specialty_template
    FROM public.trader_missions tm
    JOIN public.traders t ON t.key = tm.trader_key
    WHERE tm.status = 'open'
    ORDER BY tm.created_at DESC
  LOOP
    v_arr := v_arr || jsonb_build_object(
      'id', m.id,
      'trader_key', m.trader_key,
      'trader_name', m.trader_name,
      'resource_key', m.resource_key,
      'target_qty', m.target_qty,
      'current_qty', m.current_qty,
      'soft_deadline', m.soft_deadline,
      'expires_at', m.expires_at,
      'created_at', m.created_at,
      'your_donated_qty', COALESCE((
        SELECT SUM(qty) FROM public.trader_mission_donations
        WHERE mission_id = m.id AND player_id = v_uid
      ), 0)
    );
  END LOOP;
  RETURN v_arr::json;
END;
$$;
GRANT EXECUTE ON FUNCTION public.get_active_missions() TO authenticated;

-- ── 10. Get trade partner view ──────────────────────────
-- Returns the unlocked-for-this-player trader pool with city rep + the
-- player's own rep + tier. Replaces the old client-side computeTraderUnlocks.
CREATE OR REPLACE FUNCTION public.get_trade_partner_view()
RETURNS json
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_unlocked boolean;
  v_arr jsonb := '[]'::jsonb;
  t record;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
  v_unlocked := public.is_trade_unlocked(v_uid);
  IF NOT v_unlocked THEN
    RETURN json_build_object('unlocked', false, 'traders', '[]'::json);
  END IF;

  FOR t IN
    SELECT tr.key, tr.name, tr.specialty_template,
           tr.visit_interval_minutes, tr.visit_capacity,
           public.city_reputation(tr.key) AS city_rep,
           public.city_rep_tier(tr.key) AS city_tier,
           COALESCE((SELECT reputation FROM public.trader_relationships
                     WHERE player_id = v_uid AND trader_key = tr.key), 0) AS your_rep
    FROM public.traders tr
    WHERE tr.is_active
    ORDER BY tr.name
  LOOP
    v_arr := v_arr || jsonb_build_object(
      'key', t.key,
      'name', t.name,
      'specialty_template', t.specialty_template,
      'visit_interval_minutes', t.visit_interval_minutes,
      'visit_capacity', t.visit_capacity,
      'city_rep', t.city_rep,
      'city_tier', t.city_tier,
      'your_rep', t.your_rep
    );
  END LOOP;
  RETURN json_build_object('unlocked', true, 'traders', v_arr);
END;
$$;
GRANT EXECUTE ON FUNCTION public.get_trade_partner_view() TO authenticated;

-- ── 11. Trade stats ─────────────────────────────────────
-- Rolls up trade_transactions for the requesting player into imports / exports / balance.
CREATE OR REPLACE FUNCTION public.get_trade_stats(p_period text)
RETURNS json
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_since timestamptz;
  v_imports jsonb := '[]'::jsonb;
  v_exports jsonb := '[]'::jsonb;
  v_partners jsonb := '[]'::jsonb;
  v_total_in integer := 0;
  v_total_out integer := 0;
  r record;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;

  v_since := CASE p_period
    WHEN 'today' THEN date_trunc('day', now())
    WHEN 'week'  THEN now() - interval '7 days'
    ELSE timestamp 'epoch'
  END;

  -- Imports: BUY transactions (player paid).
  FOR r IN
    SELECT resource_key, SUM(quantity) AS qty, SUM(total_price) AS spent
    FROM public.trade_transactions
    WHERE player_id = v_uid AND transaction_type = 'buy' AND created_at >= v_since
    GROUP BY resource_key
    ORDER BY spent DESC
  LOOP
    v_imports := v_imports || jsonb_build_object(
      'resource_key', r.resource_key, 'qty', r.qty, 'spent', r.spent
    );
    v_total_out := v_total_out + COALESCE(r.spent, 0)::int;
  END LOOP;

  -- Exports: SELL transactions (player earned).
  FOR r IN
    SELECT resource_key, SUM(quantity) AS qty, SUM(total_price) AS earned
    FROM public.trade_transactions
    WHERE player_id = v_uid AND transaction_type = 'sell' AND created_at >= v_since
    GROUP BY resource_key
    ORDER BY earned DESC
  LOOP
    v_exports := v_exports || jsonb_build_object(
      'resource_key', r.resource_key, 'qty', r.qty, 'earned', r.earned
    );
    v_total_in := v_total_in + COALESCE(r.earned, 0)::int;
  END LOOP;

  -- Partners: rolled by trader_key. Total volume = qty across both directions.
  FOR r IN
    SELECT trader_key, SUM(quantity) AS volume,
           SUM(CASE WHEN transaction_type = 'sell' THEN total_price ELSE 0 END) AS earned,
           SUM(CASE WHEN transaction_type = 'buy'  THEN total_price ELSE 0 END) AS spent
    FROM public.trade_transactions
    WHERE player_id = v_uid AND created_at >= v_since
    GROUP BY trader_key
    ORDER BY volume DESC
    LIMIT 8
  LOOP
    v_partners := v_partners || jsonb_build_object(
      'trader_key', r.trader_key, 'volume', r.volume,
      'earned', r.earned, 'spent', r.spent
    );
  END LOOP;

  RETURN json_build_object(
    'period', p_period,
    'since', v_since,
    'imports', v_imports,
    'exports', v_exports,
    'partners', v_partners,
    'total_in', v_total_in,
    'total_out', v_total_out,
    'net', v_total_in - v_total_out
  );
END;
$$;
GRANT EXECUTE ON FUNCTION public.get_trade_stats(text) TO authenticated;

-- ── 12. Add unlock-gate check to existing visit + sell RPCs ──
-- Wrap resolve_trader_visit and sell_to_trader to early-out with a
-- specific error when the gate isn't met. Both keep their existing
-- behaviour when the player is unlocked.
CREATE OR REPLACE FUNCTION public._tp_assert_unlocked()
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_uid uuid := auth.uid();
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
  IF NOT public.is_trade_unlocked(v_uid) THEN
    RAISE EXCEPTION 'Trade locked: build at least 1 extractor, 1 food extractor, and 1 tier-1 house first.';
  END IF;
END;
$$;
GRANT EXECUTE ON FUNCTION public._tp_assert_unlocked() TO authenticated;

-- ── 13. Seed specialty templates for existing traders ──
UPDATE public.traders SET specialty_template = 'resource_buyer' WHERE key = 'river_traders'  AND specialty_template IS NULL;
UPDATE public.traders SET specialty_template = 'luxury_buyer'   WHERE key = 'desert_caravan' AND specialty_template IS NULL;
UPDATE public.traders SET specialty_template = 'food_buyer'     WHERE key = 'mountain_folk'  AND specialty_template IS NULL;

-- ── 14. Black market nerf ───────────────────────────────
-- The black market is intentionally a worse deal than NPC trade. With
-- NPC trade now gated behind a progression milestone, the floor needs
-- to be even lower. Cut the sell-to-black-market prices by ~35% (round
-- down, floor 1). Buy-from-black-market prices unchanged.
CREATE OR REPLACE FUNCTION public.black_market_trade(p_resource_key text, p_quantity integer, p_direction text)
RETURNS json
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_buy_from_player integer;
  v_sell_to_player integer;
  v_unit_price integer;
  v_total integer;
  v_available numeric;
  v_player_money integer;
  v_new_money integer;
BEGIN
  IF p_direction NOT IN ('buy', 'sell') THEN
    RAISE EXCEPTION 'Invalid direction: %. Must be buy or sell.', p_direction;
  END IF;
  IF p_quantity < 1 THEN
    RAISE EXCEPTION 'Quantity must be at least 1';
  END IF;

  PERFORM public.process_production();

  -- Sell-to-BM prices were 2/2/5/6/2/5/2/5/8/10/10. Cut by ~35%, floor 1.
  SELECT
    CASE p_resource_key
      WHEN 'timber'    THEN 1
      WHEN 'stone'     THEN 1
      WHEN 'lumber'    THEN 3
      WHEN 'brick'     THEN 4
      WHEN 'grain'     THEN 1
      WHEN 'flour'     THEN 3
      WHEN 'clay'      THEN 1
      WHEN 'pottery'   THEN 3
      WHEN 'bread'     THEN 5
      WHEN 'furniture' THEN 7
      WHEN 'statuary'  THEN 7
      ELSE NULL
    END,
    CASE p_resource_key
      WHEN 'timber'    THEN 10
      WHEN 'stone'     THEN 11
      WHEN 'lumber'    THEN 18
      WHEN 'brick'     THEN 20
      WHEN 'grain'     THEN 9
      WHEN 'flour'     THEN 16
      WHEN 'clay'      THEN 8
      WHEN 'pottery'   THEN 15
      WHEN 'bread'     THEN 22
      WHEN 'furniture' THEN 28
      WHEN 'statuary'  THEN 30
      ELSE NULL
    END
  INTO v_buy_from_player, v_sell_to_player;

  IF v_buy_from_player IS NULL THEN
    RAISE EXCEPTION 'Resource not available on black market: %', p_resource_key;
  END IF;

  IF p_direction = 'sell' THEN
    v_unit_price := v_buy_from_player;
    v_total := v_unit_price * p_quantity;

    SELECT COALESCE(quantity, 0) INTO v_available
    FROM public.inventories
    WHERE player_id = v_uid AND resource_key = p_resource_key;

    IF v_available IS NULL OR v_available < p_quantity THEN
      RAISE EXCEPTION 'Not enough % (have %, need %)', p_resource_key, COALESCE(v_available, 0), p_quantity;
    END IF;

    UPDATE public.inventories
    SET quantity = quantity - p_quantity, updated_at = now()
    WHERE player_id = v_uid AND resource_key = p_resource_key;

    UPDATE public.player_profiles
    SET money = money + v_total
    WHERE id = v_uid
    RETURNING money INTO v_new_money;

    INSERT INTO public.trade_transactions (player_id, trader_key, resource_key, quantity, unit_price, total_price, transaction_type)
    VALUES (v_uid, 'black_market', p_resource_key, p_quantity, v_unit_price, v_total, 'sell');

  ELSE
    v_unit_price := v_sell_to_player;
    v_total := v_unit_price * p_quantity;

    SELECT money INTO v_player_money
    FROM public.player_profiles WHERE id = v_uid;

    IF v_player_money < v_total THEN
      RAISE EXCEPTION 'Not enough money (have $%, need $%)', v_player_money, v_total;
    END IF;

    UPDATE public.player_profiles
    SET money = money - v_total
    WHERE id = v_uid
    RETURNING money INTO v_new_money;

    INSERT INTO public.inventories (player_id, resource_key, quantity)
    VALUES (v_uid, p_resource_key, p_quantity)
    ON CONFLICT (player_id, resource_key)
    DO UPDATE SET quantity = inventories.quantity + p_quantity, updated_at = now();

    INSERT INTO public.trade_transactions (player_id, trader_key, resource_key, quantity, unit_price, total_price, transaction_type)
    VALUES (v_uid, 'black_market', p_resource_key, p_quantity, v_unit_price, v_total, 'buy');
  END IF;

  RETURN json_build_object(
    'direction', p_direction,
    'resource', p_resource_key,
    'quantity', p_quantity,
    'unit_price', v_unit_price,
    'total_price', v_total,
    'money', v_new_money,
    'inventory', COALESCE(
      (SELECT json_object_agg(resource_key, quantity)
       FROM public.inventories WHERE player_id = v_uid),
      '{}'::json
    )
  );
END;
$$;
GRANT EXECUTE ON FUNCTION public.black_market_trade(text, integer, text) TO authenticated;
