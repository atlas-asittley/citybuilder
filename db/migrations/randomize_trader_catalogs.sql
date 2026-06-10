-- ─────────────────────────────────────────────────────────────────────
-- Per-city randomized trader catalogs.
--
-- Atlas's design (2026-05-08): except for the always-on river_traders
-- starter, every trader's catalog is rolled at hub-build time so a
-- player doesn't know which goods their next hub will open up. Same
-- roll for everyone in the city (city-shared), fixed prices keyed off
-- resource base_price (so randomness is in coverage, not value).
--
-- Schema:
--   trader_prices.city_id (nullable)
--     - NULL  = global default (river_traders only)
--     - !NULL = rolled for that specific city
--   PK becomes (city_id, trader_key, resource_key)
--
-- Read path: _rtv_sell_phase / _rtv_buy_phase need to query the rows
-- for the player's city_id, falling back to NULL when no city-specific
-- row exists (i.e. river_traders + any unrolled trader).
-- ─────────────────────────────────────────────────────────────────────

-- (1) Schema change
ALTER TABLE public.trader_prices
  ADD COLUMN IF NOT EXISTS city_id uuid REFERENCES public.cities(id) ON DELETE CASCADE;

-- Replace the (trader_key, resource_key) unique constraint with one that
-- includes city_id. Two indexes — one for the global rows and one for
-- per-city rows — because PG's UNIQUE doesn't dedup NULLs the way we
-- want (we want at most one global row per (trader, resource) AND at
-- most one per (city, trader, resource)).
ALTER TABLE public.trader_prices
  DROP CONSTRAINT IF EXISTS trader_prices_trader_key_resource_key_key;
CREATE UNIQUE INDEX IF NOT EXISTS trader_prices_global_unique
  ON public.trader_prices (trader_key, resource_key) WHERE city_id IS NULL;
CREATE UNIQUE INDEX IF NOT EXISTS trader_prices_city_unique
  ON public.trader_prices (city_id, trader_key, resource_key) WHERE city_id IS NOT NULL;


-- (2) Helper: read the catalog for (city, trader). Per-city rows win
-- if any exist; else fall back to global rows.
CREATE OR REPLACE FUNCTION public._trader_catalog(p_city_id uuid, p_trader_key text)
RETURNS TABLE(resource_key text, buy_price integer, sell_price integer,
              daily_buy_cap integer, daily_sell_cap integer)
LANGUAGE sql
STABLE
AS $function$
  WITH city_rows AS (
    SELECT tp.resource_key, tp.buy_price, tp.sell_price, tp.daily_buy_cap, tp.daily_sell_cap
    FROM public.trader_prices tp
    WHERE tp.trader_key = p_trader_key AND tp.city_id = p_city_id AND tp.is_active
  ), global_rows AS (
    SELECT tp.resource_key, tp.buy_price, tp.sell_price, tp.daily_buy_cap, tp.daily_sell_cap
    FROM public.trader_prices tp
    WHERE tp.trader_key = p_trader_key AND tp.city_id IS NULL AND tp.is_active
  )
  SELECT * FROM city_rows
  UNION ALL
  SELECT * FROM global_rows
  WHERE NOT EXISTS (SELECT 1 FROM city_rows);  -- only if no city rows
$function$;


-- (3) Roll a random catalog for (city, trader). Idempotent: deletes
-- existing per-city rows for this (city, trader) before inserting.
-- Picks 3-6 random resources, prices fixed off base_price (buy = 70%,
-- sell = 130%), daily caps by trader specialty.
CREATE OR REPLACE FUNCTION public._roll_city_trader_catalog(p_city_id uuid, p_trader_key text)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
DECLARE
  v_mode text;
  v_count integer;
  v_buy_cap integer;
  v_sell_cap integer;
  v_inserted integer := 0;
  r record;
BEGIN
  -- Skip the starter — river_traders keeps its global catalog (modest
  -- cap on every resource, same for every city).
  IF p_trader_key = 'river_traders' THEN RETURN 0; END IF;

  SELECT transport_mode INTO v_mode FROM public.traders WHERE key = p_trader_key;
  IF v_mode IS NULL THEN RETURN 0; END IF;

  -- Cap profile by mode. Same prices for everyone (off base_price);
  -- only the scale of trade differs.
  IF v_mode = 'airport' THEN
    v_buy_cap := 60; v_sell_cap := 40;        -- premium, small batches
  ELSIF v_mode = 'seaport' THEN
    v_buy_cap := 350; v_sell_cap := 280;      -- bulk shipper
  ELSIF v_mode = 'train' THEN
    v_buy_cap := 320; v_sell_cap := 260;      -- continental staples
  ELSIF v_mode = 'truck' THEN
    v_buy_cap := 180; v_sell_cap := 130;      -- regional moderate
  ELSE
    v_buy_cap := 150; v_sell_cap := 120;
  END IF;

  -- Wipe existing per-city rows for this (city, trader).
  DELETE FROM public.trader_prices
  WHERE city_id = p_city_id AND trader_key = p_trader_key;

  -- Random subset size 3-6.
  v_count := 3 + floor(random() * 4)::integer;

  FOR r IN
    SELECT key, base_price
    FROM public.resources
    WHERE is_active AND base_price IS NOT NULL
    ORDER BY random()
    LIMIT v_count
  LOOP
    INSERT INTO public.trader_prices
      (trader_key, resource_key, buy_price, sell_price,
       daily_buy_cap, daily_sell_cap, is_active, city_id)
    VALUES (
      p_trader_key,
      r.key,
      GREATEST(1, ROUND(r.base_price * 0.7)::integer),
      ROUND(r.base_price * 1.3)::integer,
      v_buy_cap,
      v_sell_cap,
      TRUE,
      p_city_id
    );
    v_inserted := v_inserted + 1;
  END LOOP;

  RETURN v_inserted;
END;
$function$;


-- (4) Phase helpers — read trader_prices via _trader_catalog so
-- per-city rolled rows take precedence over the global default.

-- Fixup: my randomize_trader_catalogs.sql rewrite of _rtv_sell_phase
-- and _rtv_buy_phase used the wrong table (player_trade_policies vs
-- the real trade_policies) and the wrong column names. Restore the
-- original logic; only swap the trader_prices lookup to go through
-- the city-aware _trader_catalog helper.

CREATE OR REPLACE FUNCTION public._rtv_sell_phase(
  p_uid uuid,
  p_trader_key text,
  p_capacity integer
)
RETURNS TABLE(capacity_used integer, earned integer, summary jsonb)
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_city_id uuid;
  v_remaining integer := p_capacity;
  v_earned integer := 0;
  v_summary jsonb := '[]'::jsonb;
  v_policy record;
  v_buy_price integer;
  v_inventory numeric;
  v_surplus integer;
  v_sell_amt integer;
BEGIN
  SELECT city_id INTO v_city_id FROM public.player_profiles WHERE id = p_uid;

  FOR v_policy IN
    SELECT tp.resource_key, tp.reserve_target
    FROM public.trade_policies tp
    WHERE tp.player_id = p_uid AND tp.mode = 'sell_surplus'
  LOOP
    IF v_remaining <= 0 THEN EXIT; END IF;

    SELECT cat.buy_price INTO v_buy_price
    FROM public._trader_catalog(v_city_id, p_trader_key) cat
    WHERE cat.resource_key = v_policy.resource_key;
    IF NOT FOUND OR v_buy_price IS NULL THEN CONTINUE; END IF;

    SELECT COALESCE(quantity, 0) INTO v_inventory
    FROM public.inventories
    WHERE player_id = p_uid AND resource_key = v_policy.resource_key;
    IF v_inventory IS NULL THEN v_inventory := 0; END IF;

    v_surplus := GREATEST(0, FLOOR(v_inventory) - v_policy.reserve_target);
    IF v_surplus <= 0 THEN CONTINUE; END IF;
    v_sell_amt := LEAST(v_surplus, v_remaining);
    IF v_sell_amt <= 0 THEN CONTINUE; END IF;

    UPDATE public.inventories
      SET quantity = quantity - v_sell_amt, updated_at = now()
      WHERE player_id = p_uid AND resource_key = v_policy.resource_key;

    v_earned := v_earned + (v_sell_amt * v_buy_price);
    v_remaining := v_remaining - v_sell_amt;
    v_summary := v_summary || jsonb_build_object(
      'type', 'sell',
      'resource', v_policy.resource_key,
      'quantity', v_sell_amt,
      'unit_price', v_buy_price,
      'total', v_sell_amt * v_buy_price
    );
    INSERT INTO public.trade_transactions
      (player_id, trader_key, resource_key, quantity, unit_price, total_price, transaction_type)
    VALUES
      (p_uid, p_trader_key, v_policy.resource_key, v_sell_amt, v_buy_price,
       v_sell_amt * v_buy_price, 'sell');
  END LOOP;

  capacity_used := p_capacity - v_remaining;
  earned := v_earned;
  summary := v_summary;
  RETURN NEXT;
END;
$$;

CREATE OR REPLACE FUNCTION public._rtv_buy_phase(
  p_uid uuid,
  p_trader_key text,
  p_capacity integer,
  p_money_in integer
)
RETURNS TABLE(capacity_used integer, spent integer, summary jsonb, money_out integer)
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_city_id uuid;
  v_remaining integer := p_capacity;
  v_money integer := p_money_in;
  v_spent integer := 0;
  v_summary jsonb := '[]'::jsonb;
  v_policy record;
  v_sell_price integer;
  v_inventory numeric;
  v_needed integer;
  v_buy_amt integer;
BEGIN
  SELECT city_id INTO v_city_id FROM public.player_profiles WHERE id = p_uid;

  FOR v_policy IN
    SELECT tp.resource_key, tp.reserve_target
    FROM public.trade_policies tp
    WHERE tp.player_id = p_uid AND tp.mode = 'buy_to_reserve'
  LOOP
    IF v_remaining <= 0 THEN EXIT; END IF;

    SELECT cat.sell_price INTO v_sell_price
    FROM public._trader_catalog(v_city_id, p_trader_key) cat
    WHERE cat.resource_key = v_policy.resource_key;
    IF NOT FOUND OR v_sell_price IS NULL THEN CONTINUE; END IF;

    SELECT COALESCE(quantity, 0) INTO v_inventory
    FROM public.inventories
    WHERE player_id = p_uid AND resource_key = v_policy.resource_key;
    IF v_inventory IS NULL THEN v_inventory := 0; END IF;

    v_needed := GREATEST(0, v_policy.reserve_target - FLOOR(v_inventory));
    IF v_needed <= 0 THEN CONTINUE; END IF;
    v_buy_amt := LEAST(v_needed, v_remaining);
    IF v_sell_price > 0 THEN
      v_buy_amt := LEAST(v_buy_amt, FLOOR(v_money / v_sell_price));
    END IF;
    IF v_buy_amt <= 0 THEN CONTINUE; END IF;

    INSERT INTO public.inventories (player_id, resource_key, quantity)
    VALUES (p_uid, v_policy.resource_key, v_buy_amt)
    ON CONFLICT (player_id, resource_key)
    DO UPDATE SET quantity = public.inventories.quantity + v_buy_amt, updated_at = now();

    v_spent := v_spent + (v_buy_amt * v_sell_price);
    v_money := v_money - (v_buy_amt * v_sell_price);
    v_remaining := v_remaining - v_buy_amt;
    v_summary := v_summary || jsonb_build_object(
      'type', 'buy',
      'resource', v_policy.resource_key,
      'quantity', v_buy_amt,
      'unit_price', v_sell_price,
      'total', v_buy_amt * v_sell_price
    );
    INSERT INTO public.trade_transactions
      (player_id, trader_key, resource_key, quantity, unit_price, total_price, transaction_type)
    VALUES
      (p_uid, p_trader_key, v_policy.resource_key, v_buy_amt, v_sell_price,
       v_buy_amt * v_sell_price, 'buy');
  END LOOP;

  capacity_used := p_capacity - v_remaining;
  spent := v_spent;
  summary := v_summary;
  money_out := v_money;
  RETURN NEXT;
END;
$$;


-- (5) river_traders: complete the global catalog so it covers EVERY
-- active resource at modest caps. Atlas: "The first should buy a
-- little bit of everything for sure. although not huge amounts."
-- Caps 30/30, prices = base_price * 0.7 / 1.3.
INSERT INTO public.trader_prices
  (trader_key, resource_key, buy_price, sell_price, daily_buy_cap, daily_sell_cap, is_active, city_id)
SELECT 'river_traders', r.key,
       GREATEST(1, ROUND(r.base_price * 0.7)::integer),
       ROUND(r.base_price * 1.3)::integer,
       30, 30, TRUE, NULL
FROM public.resources r WHERE r.is_active
ON CONFLICT (trader_key, resource_key) WHERE city_id IS NULL
DO UPDATE SET
  buy_price = EXCLUDED.buy_price,
  sell_price = EXCLUDED.sell_price,
  daily_buy_cap = EXCLUDED.daily_buy_cap,
  daily_sell_cap = EXCLUDED.daily_sell_cap,
  is_active = TRUE;


-- (6) Roll catalogs for the existing city (Atlas + Jill = "Lyrandel"
-- per the older notes). Every active non-starter trader gets a fresh
-- random subset right now, so the gameplay change shows up immediately
-- instead of waiting for the next hub-place.
DO $$
DECLARE
  c record;
  t record;
BEGIN
  FOR c IN SELECT id FROM public.cities LOOP
    FOR t IN SELECT key FROM public.traders WHERE is_active AND key <> 'river_traders' LOOP
      PERFORM public._roll_city_trader_catalog(c.id, t.key);
    END LOOP;
  END LOOP;
END $$;


-- (7) Hook into hub-built event via an AFTER INSERT trigger on
-- buildings — cleaner than patching the long place_building body.
-- Idempotent — skips river_traders, only rolls when the city has no
-- existing per-city rows for that trader.
CREATE OR REPLACE FUNCTION public._roll_traders_for_new_hub(p_uid uuid, p_building_type_key text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
DECLARE
  v_city_id uuid;
  v_mode text;
  v_existing_count integer;
  t record;
BEGIN
  SELECT city_id INTO v_city_id FROM public.player_profiles WHERE id = p_uid;
  IF v_city_id IS NULL THEN RETURN; END IF;

  v_mode := CASE p_building_type_key
    WHEN 'airport'     THEN 'airport'
    WHEN 'seaport'     THEN 'seaport'
    WHEN 'train_depot' THEN 'train'
    WHEN 'truck_depot' THEN 'truck'
    ELSE NULL
  END;
  IF v_mode IS NULL THEN RETURN; END IF;

  -- Only roll for traders that don't already have city-specific rows
  -- in this city (so a second airport doesn't re-randomize).
  FOR t IN SELECT key FROM public.traders WHERE is_active AND transport_mode = v_mode LOOP
    SELECT count(*) INTO v_existing_count
    FROM public.trader_prices
    WHERE city_id = v_city_id AND trader_key = t.key;
    IF v_existing_count = 0 THEN
      PERFORM public._roll_city_trader_catalog(v_city_id, t.key);
    END IF;
  END LOOP;
END;
$function$;


-- (8) Trigger: on every new building, if it's a transport_hub or
-- transport_connector, roll its mode's traders for the player's city.
-- AFTER INSERT so the building row exists; defensive against future
-- code paths that bypass place_building.
CREATE OR REPLACE FUNCTION public._on_hub_built_roll_traders()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
DECLARE
  v_cat text;
BEGIN
  SELECT category INTO v_cat FROM public.building_types WHERE key = NEW.building_type_key;
  IF v_cat IN ('transport_hub', 'transport_connector') THEN
    PERFORM public._roll_traders_for_new_hub(NEW.player_id, NEW.building_type_key);
  END IF;
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_roll_traders_on_hub_built ON public.buildings;
CREATE TRIGGER trg_roll_traders_on_hub_built
  AFTER INSERT ON public.buildings
  FOR EACH ROW
  EXECUTE FUNCTION public._on_hub_built_roll_traders();
