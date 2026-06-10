-- ─────────────────────────────────────────────────────────────────────
-- Three new buildings + retroactive citizen-draw on civic amenities
-- (2026-05-22).
--
-- Atlas's design principle: every new building solves a problem AND
-- creates a small problem. The Tavern is the existing model (+5%
-- productivity, +1 crime per office). These three follow the pattern:
--
-- Marketplace (civic, 1x1, 8 workers, $20k, $3/min upkeep):
--   Solves: +5% trader sell price per staffed marketplace (cap +25%)
--   Costs: +2 crime per staffed marketplace
--
-- Hospital (service, 2x2, 12 workers, $30k, drains lumber + ale):
--   Solves: -5 crime city-wide per staffed hospital
--   Costs: consumes lumber + ale (a luxury food) — competes with
--          high-tier housing for the same scarce resource.
--   Unlocks at housing tier 4 (Villa).
--
-- Industrial Zone (booster, 1x1, 4 workers, $15k):
--   Solves: +20% to every extractor within Manhattan 3 (uses the
--           existing booster system, so MAX-of-overlapping
--           multipliers per the booster invariant)
--   Costs: emits 6 pollution radius 4 (tile desirability sinks)
--   Unlocks at housing tier 3 (Townhouse).
--
-- Retroactive update to civic amenities to attach a small problem:
--   Public Garden: +0.1 citizens/min migration draw while staffed
--   Monument: +0.3 citizens/min migration draw while staffed
--   So they each create the "more workers who need more housing"
--   pressure that pairs with the desirability lift they grant.
--
-- New schema columns on building_types:
--   crime_emit integer DEFAULT 0          -- per-building crime added
--   crime_reduction integer DEFAULT 0     -- per-building crime subtracted
--   trade_sell_bonus_pct integer DEFAULT 0-- per-marketplace % bonus
--   migration_bonus numeric DEFAULT 0     -- citizens/min added to rate
-- ─────────────────────────────────────────────────────────────────────


ALTER TABLE public.building_types
  ADD COLUMN IF NOT EXISTS crime_emit integer NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS crime_reduction integer NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS trade_sell_bonus_pct integer NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS migration_bonus numeric NOT NULL DEFAULT 0;


INSERT INTO public.building_types (
  key, name, tier, category, industry_key, is_active,
  footprint_w, footprint_h, worker_cost, build_cost, upkeep_per_minute,
  output_rate, input_rate, input_rate_2, input_resource_key, input_resource_key_2,
  workers_provided, boost_multiplier, boost_range, boost_target,
  coverage_radius, pollution_emit, pollution_radius,
  desirability_bonus, desirability_radius,
  crime_emit, crime_reduction, trade_sell_bonus_pct, migration_bonus,
  unlocks_at_housing_tier
) VALUES
  ('marketplace', 'Marketplace', 2, 'civic', 'common', true,
   1, 1, 8, 20000, 3,
   0, 0, 0, NULL, NULL,
   0, 1.0, 0, NULL,
   0, 0, 0,
   0, 0,
   2, 0, 5, 0,
   NULL),
  ('hospital', 'Hospital', 3, 'service', 'common', true,
   2, 2, 12, 30000, 0,
   0, 0.5, 0.25, 'lumber', 'ale',
   0, 1.0, 0, NULL,
   0, 0, 0,
   0, 0,
   0, 5, 0, 0,
   4),
  ('industrial_zone', 'Industrial Zone', 3, 'booster', 'common', true,
   1, 1, 4, 15000, 0,
   0, 0, 0, NULL, NULL,
   0, 1.20, 3, 'extractor',
   0, 6, 4,
   0, 0,
   0, 0, 0, 0,
   3)
ON CONFLICT (key) DO UPDATE SET
  category = EXCLUDED.category,
  industry_key = EXCLUDED.industry_key,
  is_active = EXCLUDED.is_active,
  footprint_w = EXCLUDED.footprint_w,
  footprint_h = EXCLUDED.footprint_h,
  worker_cost = EXCLUDED.worker_cost,
  build_cost = EXCLUDED.build_cost,
  upkeep_per_minute = EXCLUDED.upkeep_per_minute,
  output_rate = EXCLUDED.output_rate,
  input_rate = EXCLUDED.input_rate,
  input_rate_2 = EXCLUDED.input_rate_2,
  input_resource_key = EXCLUDED.input_resource_key,
  input_resource_key_2 = EXCLUDED.input_resource_key_2,
  boost_multiplier = EXCLUDED.boost_multiplier,
  boost_range = EXCLUDED.boost_range,
  boost_target = EXCLUDED.boost_target,
  pollution_emit = EXCLUDED.pollution_emit,
  pollution_radius = EXCLUDED.pollution_radius,
  crime_emit = EXCLUDED.crime_emit,
  crime_reduction = EXCLUDED.crime_reduction,
  trade_sell_bonus_pct = EXCLUDED.trade_sell_bonus_pct,
  migration_bonus = EXCLUDED.migration_bonus,
  unlocks_at_housing_tier = EXCLUDED.unlocks_at_housing_tier;


-- Retro-add citizen-draw to the two civic amenities from earlier today.
UPDATE public.building_types
SET migration_bonus = 0.1
WHERE key = 'public_garden';
UPDATE public.building_types
SET migration_bonus = 0.3
WHERE key = 'monument';


-- ── compute_crime: factor in staffed buildings' emit + reduction ──
CREATE OR REPLACE FUNCTION public.compute_crime(p_uid uuid)
RETURNS numeric
LANGUAGE plpgsql
STABLE SECURITY DEFINER
AS $function$
DECLARE
  v_population numeric;
  v_uncovered integer;
  v_taverns integer;
  v_emit integer;
  v_reduce integer;
  v_score numeric;
BEGIN
  SELECT population INTO v_population FROM public.player_profiles WHERE id = p_uid;
  IF v_population IS NULL THEN v_population := 5; END IF;

  SELECT COUNT(*) INTO v_uncovered
  FROM public.buildings h
  JOIN public.building_types bt ON bt.key = h.building_type_key
  WHERE h.player_id = p_uid AND h.status = 'active' AND bt.category = 'housing'
    AND NOT EXISTS (
      SELECT 1 FROM public.buildings p
      JOIN public.building_types pt ON pt.key = p.building_type_key
      WHERE p.player_id = p_uid AND p.status = 'active' AND pt.category = 'police'
        AND p.is_staffed
        AND ABS(p.x - h.x) + ABS(p.y - h.y) <= pt.coverage_radius
    );

  SELECT COUNT(*) INTO v_taverns
  FROM public.buildings b
  WHERE b.player_id = p_uid AND b.status = 'active' AND b.building_type_key = 'tavern';

  -- Aggregate crime_emit + crime_reduction over staffed buildings.
  -- Marketplace emits +2 each; Hospital reduces -5 each. Future
  -- buildings can opt in by setting the columns.
  SELECT COALESCE(SUM(bt.crime_emit), 0), COALESCE(SUM(bt.crime_reduction), 0)
    INTO v_emit, v_reduce
  FROM public.buildings b
  JOIN public.building_types bt ON bt.key = b.building_type_key
  WHERE b.player_id = p_uid AND b.status = 'active' AND b.is_staffed
    AND (bt.crime_emit > 0 OR bt.crime_reduction > 0);

  v_score := 5
    + 4 * v_uncovered
    + LEAST(20, FLOOR(v_population / 10))
    + 1 * v_taverns
    + v_emit
    - v_reduce;

  RETURN LEAST(100, GREATEST(0, v_score));
END;
$function$;


-- ── _pp_update_population: include migration_bonus from staffed buildings ──
CREATE OR REPLACE FUNCTION public._pp_update_population(p_uid uuid)
RETURNS numeric
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
DECLARE
  v_target numeric;
  v_pop numeric;
  v_happiness numeric;
  v_last timestamptz;
  v_minutes numeric;
  v_max_rate constant numeric := 4.0;
  v_floor numeric;
  v_rate numeric;
  v_step integer;
  v_migration_bonus numeric;
BEGIN
  SELECT tutorial_step INTO v_step FROM public.player_profiles WHERE id = p_uid;
  v_floor := CASE WHEN COALESCE(v_step, 4) < 4 THEN 0 ELSE 15 END;
  v_target := v_floor + public._pp_housing_supply(p_uid);

  SELECT population, last_population_tick_at INTO v_pop, v_last
  FROM public.player_profiles WHERE id = p_uid;
  IF v_pop IS NULL THEN v_pop := v_floor; END IF;
  IF v_last IS NULL THEN v_last := now() - interval '1 minute'; END IF;

  v_minutes := GREATEST(0, EXTRACT(EPOCH FROM (now() - v_last)) / 60.0);
  IF v_minutes > 60 THEN v_minutes := 60; END IF;

  v_happiness := (public.compute_happiness(p_uid)->>'happiness')::numeric;

  -- Civic amenities + monuments draw additional citizens proportional
  -- to their migration_bonus, only while staffed. This creates the
  -- "more population to manage" pressure that pairs with the
  -- desirability lift they grant.
  SELECT COALESCE(SUM(bt.migration_bonus), 0) INTO v_migration_bonus
  FROM public.buildings b
  JOIN public.building_types bt ON bt.key = b.building_type_key
  WHERE b.player_id = p_uid AND b.status = 'active' AND b.is_staffed
    AND bt.migration_bonus > 0;

  IF v_pop > v_target THEN
    v_rate := 0;
    v_pop := v_target;
  ELSIF v_pop < v_floor THEN
    v_rate := v_max_rate;
    v_pop := LEAST(v_floor, v_pop + v_rate * v_minutes);
  ELSIF v_pop < v_target AND v_happiness >= 50 THEN
    v_rate := ((v_happiness - 50) / 50.0) * v_max_rate + v_migration_bonus;
    v_pop := LEAST(v_target, v_pop + v_rate * v_minutes);
  ELSIF v_happiness < 50 AND v_pop > v_floor THEN
    -- Below-50 happiness: net loss, but migration_bonus from amenities
    -- still draws SOME citizens, partially offsetting.
    v_rate := -((50 - v_happiness) / 50.0) * v_max_rate + v_migration_bonus;
    v_pop := GREATEST(v_floor, v_pop + v_rate * v_minutes);
  ELSE
    -- happiness exactly 50 and at target — amenity draw still applies
    -- if there's headroom.
    v_rate := CASE WHEN v_pop < v_target THEN v_migration_bonus ELSE 0 END;
    IF v_rate > 0 THEN
      v_pop := LEAST(v_target, v_pop + v_rate * v_minutes);
    END IF;
  END IF;

  UPDATE public.player_profiles
  SET population = ROUND(v_pop, 6),
      happiness = ROUND(v_happiness, 2),
      migration_rate = ROUND(v_rate, 4),
      last_population_tick_at = now()
  WHERE id = p_uid;

  RETURN v_pop;
END;
$function$;


-- ── _rtv_sell_phase: apply marketplace trade bonus ────────────────
CREATE OR REPLACE FUNCTION public._rtv_sell_phase(p_uid uuid, p_trader_key text, p_per_resource_capacity integer)
RETURNS TABLE(capacity_used integer, earned integer, summary jsonb)
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
DECLARE
  v_city_id uuid;
  v_total_used integer := 0;
  v_earned integer := 0;
  v_summary jsonb := '[]'::jsonb;
  v_policy record;
  v_buy_price integer;
  v_buy_cap integer;
  v_inventory numeric;
  v_quota_used integer;
  v_quota_remaining integer;
  v_surplus integer;
  v_sell_amt integer;
  v_unit_earned integer;
  v_market_bonus_pct integer;
  v_today date := CURRENT_DATE;
BEGIN
  SELECT city_id INTO v_city_id FROM public.player_profiles WHERE id = p_uid;

  -- Sum trade_sell_bonus_pct across staffed marketplaces, capped at
  -- 25% so a max stack of 5 marketplaces gives +25%, no further
  -- benefit from spamming.
  SELECT LEAST(25, COALESCE(SUM(bt.trade_sell_bonus_pct), 0))
    INTO v_market_bonus_pct
  FROM public.buildings b
  JOIN public.building_types bt ON bt.key = b.building_type_key
  WHERE b.player_id = p_uid AND b.status = 'active' AND b.is_staffed
    AND bt.trade_sell_bonus_pct > 0;

  FOR v_policy IN
    SELECT tp.resource_key, tp.reserve_target, tp.min_sell_price
    FROM public.trade_policies tp
    WHERE tp.player_id = p_uid AND tp.mode = 'sell_surplus'
  LOOP
    SELECT cat.buy_price, cat.daily_buy_cap INTO v_buy_price, v_buy_cap
    FROM public._trader_catalog(v_city_id, p_trader_key) cat
    WHERE cat.resource_key = v_policy.resource_key;
    IF NOT FOUND OR v_buy_price IS NULL THEN CONTINUE; END IF;

    IF v_policy.min_sell_price IS NOT NULL
       AND v_buy_price < v_policy.min_sell_price THEN
      CONTINUE;
    END IF;

    SELECT COALESCE(qty_bought, 0) INTO v_quota_used
    FROM public.trader_daily_quota
    WHERE player_id = p_uid AND trader_key = p_trader_key
      AND resource_key = v_policy.resource_key AND day_bucket = v_today;
    v_quota_remaining := GREATEST(0, COALESCE(v_buy_cap, 0) - COALESCE(v_quota_used, 0));
    IF v_quota_remaining <= 0 THEN CONTINUE; END IF;

    SELECT COALESCE(quantity, 0) INTO v_inventory
    FROM public.inventories
    WHERE player_id = p_uid AND resource_key = v_policy.resource_key;
    IF v_inventory IS NULL THEN v_inventory := 0; END IF;

    v_surplus := GREATEST(0, FLOOR(v_inventory) - v_policy.reserve_target);
    IF v_surplus <= 0 THEN CONTINUE; END IF;

    v_sell_amt := LEAST(v_surplus, p_per_resource_capacity, v_quota_remaining);
    IF v_sell_amt <= 0 THEN CONTINUE; END IF;

    UPDATE public.inventories
      SET quantity = quantity - v_sell_amt, updated_at = now()
      WHERE player_id = p_uid AND resource_key = v_policy.resource_key;

    INSERT INTO public.trader_daily_quota
      (player_id, trader_key, resource_key, day_bucket, qty_bought, qty_sold)
    VALUES (p_uid, p_trader_key, v_policy.resource_key, v_today, v_sell_amt, 0)
    ON CONFLICT (player_id, trader_key, resource_key, day_bucket)
    DO UPDATE SET qty_bought = public.trader_daily_quota.qty_bought + v_sell_amt;

    -- Apply marketplace bonus to per-unit price.
    v_unit_earned := FLOOR(v_buy_price * (100 + v_market_bonus_pct) / 100.0);
    v_earned := v_earned + v_unit_earned * v_sell_amt;
    v_total_used := v_total_used + v_sell_amt;
    v_summary := v_summary || jsonb_build_object(
      'resource', v_policy.resource_key,
      'sold', v_sell_amt,
      'price', v_unit_earned
    );
  END LOOP;

  RETURN QUERY SELECT v_total_used, v_earned, v_summary;
END;
$function$;
