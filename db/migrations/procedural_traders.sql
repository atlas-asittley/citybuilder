-- ─────────────────────────────────────────────────────────────────────
-- Procedural trade partners (2026-05-10).
--
-- Atlas: "we want to automatically and somewhat randomly generate
-- these trade partners. we may need to have a list of maybe a hundred
-- different names we can use for the trade partners, but anytime one
-- is added it's just generated some degree at random."
--
-- Replaces the fixed-roster tiered model (Sky Caravans, Cloud Couriers,
-- Coastal Merchants, etc.) with an open procedural model:
--
--   - 100 names in trader_name_pool. Each new partner picks a random
--     unused name, or appends a roman numeral on collision.
--   - Every transport_hub BUILD spawns one new partner. Every EXPAND
--     spawns another. Same for transport_connector (truck depot).
--   - Each new partner picks 3-6 random resources, both buy and sell
--     for each. Prices anchored to base_price (buy 0.6-0.95×, sell
--     1.05-1.5×). Per-resource daily caps 5,000-50,000 (matches the
--     recent hub-volume bump). Visit capacity 500-5,000, interval
--     8-30 min.
--   - Partners are city-wide. Players access them via own hub of the
--     same mode, OR via a truck depot if any city hub of the mode
--     exists (same gate as before, just without the tier ladder).
--
-- One-time migration ALSO:
--   - Wipes the 7 existing named hub-mode traders + their prices.
--     Keeps river_traders (starter) and black_market.
--   - Retroactively spawns procedural traders for every existing hub/
--     truck depot (1 per build + 1 per expansion level) so the live
--     world doesn't lose all its hub partners on rollout.
-- ─────────────────────────────────────────────────────────────────────

-- ── Name pool ───────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.trader_name_pool (
  name text PRIMARY KEY
);

INSERT INTO public.trader_name_pool (name) VALUES
  ('Aldermarch Traders'),    ('Bramblehollow Caravan'),  ('Cresthaven Merchants'),
  ('Dunwick Routes'),         ('Elderfield Sails'),       ('Fairhaven Crews'),
  ('Greenwood Carriers'),     ('Hawksridge Express'),     ('Ironvale Couriers'),
  ('Jadepoint Lines'),        ('Keldon Convoy'),          ('Linnford Traders'),
  ('Marbridge Skies'),        ('Northfield Routes'),      ('Oakport Sails'),
  ('Pinewood Crews'),         ('Quartzhill Express'),     ('Ravenshire Routes'),
  ('Stormridge Caravan'),     ('Thornbury Lines'),        ('Underhill Traders'),
  ('Vermilion Sails'),        ('Westridge Crews'),        ('Yarrowmoor Carriers'),
  ('Zenith Routes'),          ('Silver Coast Traders'),   ('Iron Coast Crews'),
  ('Gold Coast Merchants'),   ('Stone Coast Routes'),     ('Coastal Winds'),
  ('Northern Star Lines'),    ('Southern Sails'),         ('Eastern Reach'),
  ('Western Trail'),          ('Highland Pass'),          ('Lowland Route'),
  ('Valley Express'),         ('Mountain Track'),         ('River Bend Crews'),
  ('Forest Edge Routes'),     ('Plain''s Reach'),         ('Old Capital Sails'),
  ('Distant Ports Lines'),    ('Far Shore Express'),      ('Misty Hollow'),
  ('Bright Harbor'),          ('Stillwater Routes'),      ('Windmark Caravan'),
  ('Sunward Sails'),          ('Moonshade Lines'),        ('Falcon Express'),
  ('Stag Caravan'),           ('Boar''s Run'),            ('Wolf Trail Routes'),
  ('Hawk''s Wing'),           ('Bear Convoy'),            ('Lion Trade Lines'),
  ('Raven Routes'),           ('Otter Couriers'),         ('Stallion Hauliers'),
  ('Heron Lines'),            ('Eagle Skies'),            ('Fox Routes'),
  ('Lynx Express'),           ('Drake''s Run'),           ('Griffon Wings'),
  ('Phoenix Lines'),          ('Kraken Coast'),           ('Siren''s Call'),
  ('The Brokers'),            ('The Cartel'),             ('The Consortium'),
  ('The Exchange'),           ('The Hauliers'),           ('The Wayfarers'),
  ('The Pathfinders'),        ('The Couriers'),           ('Free Traders'),
  ('Honest Folk Merchants'),  ('Sworn Sail'),             ('Open Books Trading'),
  ('Vagabond Merchants'),     ('Master Merchants'),       ('Guild Routes'),
  ('Pilgrim''s Lines'),       ('Cobbler''s Cart'),        ('Mariner''s Reach'),
  ('Goodfellow Trading'),     ('Brassmark Routes'),       ('Sigil Sails'),
  ('Vellum Convoy'),          ('Threadneedle Crews'),     ('Glasswright Trade'),
  ('Tallow Lines'),           ('Saltwind Sails'),         ('Frostward Routes'),
  ('Embergate Caravan'),      ('Verdant Reach'),          ('Tideway Crews'),
  ('Stonefoot Express')
ON CONFLICT (name) DO NOTHING;


-- ── Name picker ─────────────────────────────────────────────────────
-- Picks a random base name; if a trader already exists with that
-- name, appends II / III / IV / etc. until unique.
CREATE OR REPLACE FUNCTION public._pick_trader_name()
RETURNS text
LANGUAGE plpgsql
AS $$
DECLARE
  v_base text;
  v_candidate text;
  v_n int := 2;
  ROMAN constant text[] := ARRAY['','I','II','III','IV','V','VI','VII','VIII','IX','X',
                                 'XI','XII','XIII','XIV','XV','XVI','XVII','XVIII','XIX','XX'];
BEGIN
  SELECT name INTO v_base FROM public.trader_name_pool ORDER BY random() LIMIT 1;
  IF v_base IS NULL THEN
    v_base := 'Unnamed Convoy';
  END IF;
  v_candidate := v_base;
  WHILE EXISTS (SELECT 1 FROM public.traders WHERE name = v_candidate) LOOP
    IF v_n <= 20 THEN
      v_candidate := v_base || ' ' || ROMAN[v_n + 1];  -- ROMAN[3]='II', etc.
    ELSE
      v_candidate := v_base || ' ' || v_n::text;
    END IF;
    v_n := v_n + 1;
  END LOOP;
  RETURN v_candidate;
END;
$$;


-- ── Spawn helper ────────────────────────────────────────────────────
-- Creates a new procedural trader for the given transport_mode.
-- Returns the new trader_key. Caller is responsible for triggering
-- this on the right events (build / expand).
CREATE OR REPLACE FUNCTION public._spawn_random_trader(p_mode text)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_key text;
  v_name text;
  v_capacity int;
  v_interval int;
  v_n_resources int;
  v_resource record;
  v_buy_price int;
  v_sell_price int;
  v_buy_cap int;
  v_sell_cap int;
BEGIN
  IF p_mode NOT IN ('airport', 'seaport', 'train', 'truck') THEN
    RAISE EXCEPTION 'Invalid transport_mode for procedural trader: %', p_mode;
  END IF;

  v_name := public._pick_trader_name();
  v_key := 'proc_' || substr(replace(gen_random_uuid()::text, '-', ''), 1, 12);
  v_capacity := 500 + floor(random() * 4501)::int;   -- 500-5000
  v_interval := 8 + floor(random() * 23)::int;        -- 8-30 min
  v_n_resources := 3 + floor(random() * 4)::int;      -- 3-6

  INSERT INTO public.traders (
    key, name, transport_mode, visit_capacity, visit_interval_minutes,
    is_active, tier, description
  ) VALUES (
    v_key, v_name, p_mode, v_capacity, v_interval, true, 1,
    'Procedural ' || p_mode || ' partner.'
  );

  FOR v_resource IN
    SELECT key, base_price
    FROM public.resources
    WHERE is_active AND base_price > 0
    ORDER BY random()
    LIMIT v_n_resources
  LOOP
    v_buy_price  := GREATEST(1, FLOOR(v_resource.base_price * (0.6 + random() * 0.35))::int);
    v_sell_price := GREATEST(v_buy_price + 1,
                             FLOOR(v_resource.base_price * (1.05 + random() * 0.45))::int);
    v_buy_cap  := 5000 + floor(random() * 45001)::int;
    v_sell_cap := 5000 + floor(random() * 45001)::int;

    INSERT INTO public.trader_prices (
      trader_key, resource_key, buy_price, sell_price,
      daily_buy_cap, daily_sell_cap, is_active
    ) VALUES (
      v_key, v_resource.key, v_buy_price, v_sell_price,
      v_buy_cap, v_sell_cap, true
    );
  END LOOP;

  RETURN v_key;
END;
$$;


-- ── Retire the named hub traders ────────────────────────────────────
-- river_traders (starter) and black_market stay active. Soft-delete
-- everything else with a transport_mode by flipping is_active=false
-- — trade_transactions, trader_visits, trader_daily_quota all FK to
-- traders.key and we want to preserve historical records.
--
-- Also wipe their trader_prices so they don't appear in any catalog
-- query (state.allTraderPrices, _trader_catalog). Prices have no
-- inbound FKs so they delete cleanly.
DELETE FROM public.trader_prices
WHERE trader_key IN (
  'sky_caravans', 'cloud_couriers', 'coastal_merchants', 'distant_isles',
  'inland_caravans', 'mountain_express', 'regional_hauliers'
);

UPDATE public.traders SET is_active = false
WHERE key IN (
  'sky_caravans', 'cloud_couriers', 'coastal_merchants', 'distant_isles',
  'inland_caravans', 'mountain_express', 'regional_hauliers'
);


-- ── Hook procedural spawning into place_building ────────────────────
-- Existing place_building is large; we don't re-create it here. The
-- spawn trigger fires from a row-level AFTER INSERT trigger on the
-- buildings table — cleaner than patching every place-RPC.

CREATE OR REPLACE FUNCTION public._trg_buildings_spawn_trader()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_bt record;
  v_mode text;
BEGIN
  SELECT bt.category, bt.key INTO v_bt
  FROM public.building_types bt WHERE bt.key = NEW.building_type_key;

  IF v_bt.category = 'transport_hub' THEN
    v_mode := CASE v_bt.key
      WHEN 'airport' THEN 'airport'
      WHEN 'seaport' THEN 'seaport'
      WHEN 'train_depot' THEN 'train'
      ELSE NULL
    END;
  ELSIF v_bt.category = 'transport_connector' THEN
    v_mode := 'truck';
  END IF;

  IF v_mode IS NOT NULL THEN
    PERFORM public._spawn_random_trader(v_mode);
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_buildings_spawn_trader ON public.buildings;
CREATE TRIGGER trg_buildings_spawn_trader
  AFTER INSERT ON public.buildings
  FOR EACH ROW EXECUTE FUNCTION public._trg_buildings_spawn_trader();

-- Drop the pre-existing trigger from the tier-based design. It rolled
-- city-specific catalog rows on top of global trader_prices when a
-- hub was built — irrelevant now that each new partner is its own
-- procedurally-generated row. Without this drop, the old trigger
-- adds extra trader_prices to our freshly-spawned procedural trader,
-- ballooning the resource count past 3-6.
DROP TRIGGER IF EXISTS trg_roll_traders_on_hub_built ON public.buildings;


-- ── Hook procedural spawning into expand_transport_hub ──────────────
-- Patch the existing function. Same body as live (verified via
-- pg_get_functiondef), with a single PERFORM line added before RETURN.
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
  v_mode text;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;

  SELECT * INTO v_b FROM public.buildings WHERE id = p_building_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Building not found'; END IF;

  SELECT * INTO v_bt FROM public.building_types WHERE key = v_b.building_type_key;
  IF v_bt.category <> 'transport_hub' THEN
    RAISE EXCEPTION 'Only transport hubs can be expanded';
  END IF;

  IF v_b.expansion_level >= 1 THEN
    RAISE EXCEPTION 'Hub is already at max expansion';
  END IF;

  v_cost := (v_bt.build_cost * 2 * (v_b.expansion_level + 1))::integer;

  SELECT money INTO v_money FROM public.player_profiles WHERE id = v_uid;
  IF v_money < v_cost THEN
    RAISE EXCEPTION 'Need $% to expand (you have $%)', v_cost, v_money;
  END IF;

  UPDATE public.player_profiles SET money = money - v_cost WHERE id = v_uid;
  INSERT INTO public.cash_transactions (player_id, source, amount, context)
  VALUES (v_uid, 'build_cost', -v_cost,
          jsonb_build_object('reason', 'transport_expansion',
                             'building_id', p_building_id,
                             'building_type', v_b.building_type_key,
                             'new_level', v_b.expansion_level + 1));

  UPDATE public.buildings SET expansion_level = expansion_level + 1
    WHERE id = p_building_id;

  -- Procedural trader spawn — each expansion adds a new partner.
  v_mode := CASE v_b.building_type_key
    WHEN 'airport' THEN 'airport'
    WHEN 'seaport' THEN 'seaport'
    WHEN 'train_depot' THEN 'train'
    ELSE NULL
  END;
  IF v_mode IS NOT NULL THEN
    PERFORM public._spawn_random_trader(v_mode);
  END IF;

  RETURN json_build_object(
    'building_id', p_building_id,
    'new_level', v_b.expansion_level + 1,
    'cost', v_cost,
    'money', v_money - v_cost
  );
END;
$function$;


-- ── Retroactive spawn for the existing world ────────────────────────
-- Walk every existing hub / truck depot and spawn (1 + expansion_level)
-- procedural traders for each. After this, the live city has the same
-- mix of partners it had before, just procedurally generated.
DO $$
DECLARE
  v_b record;
  v_mode text;
  v_count int;
  v_i int;
BEGIN
  FOR v_b IN
    SELECT b.id, b.expansion_level, b.building_type_key, bt.category
    FROM public.buildings b
    JOIN public.building_types bt ON bt.key = b.building_type_key
    WHERE bt.category IN ('transport_hub', 'transport_connector')
  LOOP
    v_mode := CASE
      WHEN v_b.category = 'transport_connector' THEN 'truck'
      WHEN v_b.building_type_key = 'airport' THEN 'airport'
      WHEN v_b.building_type_key = 'seaport' THEN 'seaport'
      WHEN v_b.building_type_key = 'train_depot' THEN 'train'
      ELSE NULL
    END;
    IF v_mode IS NULL THEN CONTINUE; END IF;
    v_count := 1 + COALESCE(v_b.expansion_level, 0);
    FOR v_i IN 1..v_count LOOP
      PERFORM public._spawn_random_trader(v_mode);
    END LOOP;
  END LOOP;
END $$;


-- ── Changelog entry ─────────────────────────────────────────────────
INSERT INTO public.changelog_entries (slug, title, body)
VALUES (
  '2026-05-10-procedural-traders',
  'Trade partners are now procedurally generated',
  E'The fixed roster of named hub partners (Sky Caravans, Coastal Merchants, Inland Caravans, etc.) is gone. Every time anyone in the city builds or expands a transport hub — airport, seaport, train depot, or truck depot — a new procedurally-generated trade partner shows up.\n\nEach new partner picks a random name from a pool, picks 3-6 random resources to trade, and rolls its own prices and volumes. Partners stay forever once created. Build more hubs, get more partners.\n\nThe starter Neighboring City trader is unchanged. Existing players had procedural partners retroactively generated to replace the old named roster, so no one lost trade routes.'
)
ON CONFLICT (slug) DO NOTHING;
