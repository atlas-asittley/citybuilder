-- ── Transport Network: schema + 4 buildings + 6 traders (2026-05-08) ──
-- Spec: docs/transport_network_spec.md
-- Hub buildings (airport/seaport/train_depot) unlock per-mode traders
-- when built. Truck depot grants city-wide access to other players'
-- hubs. Expansion adds another trader to the pool.

-- ── 1) Schema additions ──

-- transport_mode: which transport network this trader belongs to.
-- tier: 1-indexed slot within that mode's trader pool.
ALTER TABLE public.traders
  ADD COLUMN IF NOT EXISTS transport_mode text,
  ADD COLUMN IF NOT EXISTS tier integer;

-- expansion_level: how many tiers a transport hub has been expanded to.
-- 0 = base (1 trader from this hub). 1 = expanded once (+1 trader). Etc.
ALTER TABLE public.buildings
  ADD COLUMN IF NOT EXISTS expansion_level integer NOT NULL DEFAULT 0;

-- Expand the category CHECK constraint to include the two new
-- transport categories. Without this, INSERTs below fail.
ALTER TABLE public.building_types DROP CONSTRAINT IF EXISTS building_types_category_check;
ALTER TABLE public.building_types ADD CONSTRAINT building_types_category_check CHECK (
  category = ANY (ARRAY[
    'extractor', 'food_extractor', 'processor', 'road', 'housing',
    'service', 'tax', 'booster', 'police', 'park',
    'transport_hub', 'transport_connector'
  ])
);

-- ── 2) Building types ──

-- tier=4 puts these at the top of the build menu (after housing tier 4
-- gating), matching their high build cost. Transport infrastructure
-- isn't really housing-tier-gated, but the tier column is NOT NULL so
-- we pick a sensible value.
INSERT INTO public.building_types (
  key, name, category, industry_key,
  build_cost, worker_cost, footprint_w, footprint_h,
  is_active, tier, unlocks_at_housing_tier,
  input_rate, output_rate
) VALUES
  ('airport',     'Airport',     'transport_hub',   'common', 50000, 10, 3, 3, TRUE, 4, NULL, 0, 0),
  ('seaport',     'Seaport',     'transport_hub',   'common', 40000, 10, 3, 2, TRUE, 4, NULL, 0, 0),
  ('train_depot', 'Train Depot', 'transport_hub',   'common', 30000,  8, 3, 2, TRUE, 3, NULL, 0, 0),
  ('truck_depot', 'Truck Depot', 'transport_connector', 'common', 8000, 5, 2, 2, TRUE, 2, NULL, 0, 0)
ON CONFLICT (key) DO UPDATE SET
  name = EXCLUDED.name,
  category = EXCLUDED.category,
  build_cost = EXCLUDED.build_cost,
  worker_cost = EXCLUDED.worker_cost,
  footprint_w = EXCLUDED.footprint_w,
  footprint_h = EXCLUDED.footprint_h,
  tier = EXCLUDED.tier,
  is_active = EXCLUDED.is_active;

-- ── 3) Traders ──
-- 6 new traders (2 per hub mode). Each gets a transport_mode + tier
-- so the unlock logic can find them.

INSERT INTO public.traders
  (key, name, description, is_active, visit_capacity, visit_interval_minutes,
   display_order, base_request_qty,
   soft_deadline_minutes, transport_mode, tier)
VALUES
  -- Airport: fast premium, lifestyle-focused.
  ('sky_caravans',   'Sky Caravans',   'Premium air freight. Small loads, frequent stops.',         TRUE, 10,  8, 100, 5, 60,  'airport', 1),
  ('cloud_couriers', 'Cloud Couriers', 'High-altitude luxury food specialists.',                    TRUE, 12, 12, 110, 5, 60,  'airport', 2),
  -- Seaport: bulk exotic.
  ('coastal_merchants', 'Coastal Merchants', 'Bulk raw-material shippers from coastal harbors.',   TRUE, 40, 18, 120, 5, 60,  'seaport', 1),
  ('distant_isles',     'Distant Isles',     'Exotic goods from beyond the main shipping lanes.', TRUE, 30, 22, 130, 5, 60,  'seaport', 2),
  -- Train Depot: continental staples.
  ('inland_caravans', 'Inland Caravans', 'Continental grain and food staples in volume.',          TRUE, 60, 25, 140, 5, 60,  'train',   1),
  ('mountain_express', 'Mountain Express', 'Processed metals and bulk industrials by rail.',       TRUE, 50, 30, 150, 5, 60,  'train',   2)
ON CONFLICT (key) DO UPDATE SET
  name = EXCLUDED.name,
  description = EXCLUDED.description,
  is_active = EXCLUDED.is_active,
  visit_capacity = EXCLUDED.visit_capacity,
  visit_interval_minutes = EXCLUDED.visit_interval_minutes,
  transport_mode = EXCLUDED.transport_mode,
  tier = EXCLUDED.tier;

-- ── 4) Trader prices ──
-- Each trader's catalog. Price gradient: airport > seaport > train
-- (premium → bulk → cheapest). Daily caps scale inversely.

-- Sky Caravans (air, tier 1) — lifestyle goods at premium
INSERT INTO public.trader_prices (trader_key, resource_key, buy_price, sell_price, daily_buy_cap, daily_sell_cap, is_active) VALUES
  ('sky_caravans', 'pottery',   16, 24, 80, 60, TRUE),
  ('sky_caravans', 'bread',     14, 22, 80, 60, TRUE),
  ('sky_caravans', 'furniture', 18, 28, 60, 50, TRUE),
  ('sky_caravans', 'statuary',  18, 28, 60, 50, TRUE)
ON CONFLICT (trader_key, resource_key) DO UPDATE SET
  buy_price = EXCLUDED.buy_price, sell_price = EXCLUDED.sell_price,
  daily_buy_cap = EXCLUDED.daily_buy_cap, daily_sell_cap = EXCLUDED.daily_sell_cap;

-- Cloud Couriers (air, tier 2) — luxury foods
INSERT INTO public.trader_prices (trader_key, resource_key, buy_price, sell_price, daily_buy_cap, daily_sell_cap, is_active) VALUES
  ('cloud_couriers', 'caviar',  35, 50, 40, 30, TRUE),
  ('cloud_couriers', 'spirits', 28, 42, 50, 40, TRUE),
  ('cloud_couriers', 'spices',  30, 45, 40, 30, TRUE),
  ('cloud_couriers', 'ale',     22, 34, 60, 50, TRUE)
ON CONFLICT (trader_key, resource_key) DO UPDATE SET
  buy_price = EXCLUDED.buy_price, sell_price = EXCLUDED.sell_price,
  daily_buy_cap = EXCLUDED.daily_buy_cap, daily_sell_cap = EXCLUDED.daily_sell_cap;

-- Coastal Merchants (sea, tier 1) — bulk raw materials
INSERT INTO public.trader_prices (trader_key, resource_key, buy_price, sell_price, daily_buy_cap, daily_sell_cap, is_active) VALUES
  ('coastal_merchants', 'clay',   3,  6, 500, 400, TRUE),
  ('coastal_merchants', 'stone',  5,  9, 500, 400, TRUE),
  ('coastal_merchants', 'timber', 4,  8, 500, 400, TRUE),
  ('coastal_merchants', 'iron',   8, 14, 400, 300, TRUE),
  ('coastal_merchants', 'grain',  3,  7, 500, 400, TRUE)
ON CONFLICT (trader_key, resource_key) DO UPDATE SET
  buy_price = EXCLUDED.buy_price, sell_price = EXCLUDED.sell_price,
  daily_buy_cap = EXCLUDED.daily_buy_cap, daily_sell_cap = EXCLUDED.daily_sell_cap;

-- Distant Isles (sea, tier 2) — finished cross-industry goods
INSERT INTO public.trader_prices (trader_key, resource_key, buy_price, sell_price, daily_buy_cap, daily_sell_cap, is_active) VALUES
  ('distant_isles', 'pottery',   12, 18, 300, 250, TRUE),
  ('distant_isles', 'statuary',  16, 24, 250, 200, TRUE),
  ('distant_isles', 'furniture', 16, 24, 250, 200, TRUE),
  ('distant_isles', 'glass',     20, 30, 200, 150, TRUE)
ON CONFLICT (trader_key, resource_key) DO UPDATE SET
  buy_price = EXCLUDED.buy_price, sell_price = EXCLUDED.sell_price,
  daily_buy_cap = EXCLUDED.daily_buy_cap, daily_sell_cap = EXCLUDED.daily_sell_cap;

-- Inland Caravans (train, tier 1) — continental grain/food
INSERT INTO public.trader_prices (trader_key, resource_key, buy_price, sell_price, daily_buy_cap, daily_sell_cap, is_active) VALUES
  ('inland_caravans', 'grain',      2,  5, 800, 700, TRUE),
  ('inland_caravans', 'flour',      6, 10, 600, 500, TRUE),
  ('inland_caravans', 'bread',      9, 15, 500, 400, TRUE),
  ('inland_caravans', 'vegetables', 3,  6, 700, 600, TRUE)
ON CONFLICT (trader_key, resource_key) DO UPDATE SET
  buy_price = EXCLUDED.buy_price, sell_price = EXCLUDED.sell_price,
  daily_buy_cap = EXCLUDED.daily_buy_cap, daily_sell_cap = EXCLUDED.daily_sell_cap;

-- Mountain Express (train, tier 2) — processed industrials
INSERT INTO public.trader_prices (trader_key, resource_key, buy_price, sell_price, daily_buy_cap, daily_sell_cap, is_active) VALUES
  ('mountain_express', 'lumber',     5,  9, 600, 500, TRUE),
  ('mountain_express', 'brick',      6, 10, 600, 500, TRUE),
  ('mountain_express', 'iron_ingot', 12, 18, 400, 300, TRUE),
  ('mountain_express', 'nails',      8, 14, 500, 400, TRUE)
ON CONFLICT (trader_key, resource_key) DO UPDATE SET
  buy_price = EXCLUDED.buy_price, sell_price = EXCLUDED.sell_price,
  daily_buy_cap = EXCLUDED.daily_buy_cap, daily_sell_cap = EXCLUDED.daily_sell_cap;

-- ── 5) Sprite-color hooks ──
-- Sprites get added in a follow-up; for now the build panel shows the
-- text card and the map renders a colored block (no SVG sprite yet).
-- Existing sprite system reads from sprites.js; new entries will land
-- there in the next commit.
