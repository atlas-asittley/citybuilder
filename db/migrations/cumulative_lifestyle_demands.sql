-- ── Cumulative + scaled lifestyle demands (2026-05-07) ──
-- Atlas: "the people living there got used to that thing — they don't
-- forget about pottery just because they moved into a Manor." Lifestyle
-- goods now stack: every good earned at a lower tier is still required
-- at every higher tier, and the per-house consumption rate scales up
-- with the tier (more residents = more upkeep).
--
-- Old model:
--   T2 Cottage   → pottery 0.10/min
--   T3 Townhouse → bread   0.10/min   (pottery no longer asked for)
--   T4 Villa     → furniture
--   T5 Manor     → statuary
--
-- New model (per-house per-minute, cumulative across tiers):
--                pottery  bread   furniture  statuary
--   T2 Cottage    0.10
--   T3 Townhouse  0.15    0.10
--   T4 Villa      0.20    0.15    0.10
--   T5 Manor      0.25    0.20    0.15      0.10
--   T6 Mansion    0.30    0.25    0.20      0.15
--   T7 Estate     0.35    0.30    0.25      0.20
--   T8 Palace     0.40    0.35    0.30      0.25
--
-- A Palace runs 1.30/min total lifestyle drain across four goods, on top
-- of its 3.60/min food drain — high-tier housing is now an active
-- production-chain commitment, not a trophy. The introducing-tier rate
-- stays at 0.10 (current behavior). Each subsequent tier adds +0.05 to
-- that good's per-house rate, modeling the larger population.
--
-- Devolve cap: _pp_evolve_housing already moves at most one tier per
-- call (single ELSIF branch on devolve). With cumulative demand a single
-- missing good will keep failing the maintain-tier check on every tick,
-- so a house WILL chain-devolve over time — but at a rate of one tier
-- per process_production call (≈ once per minute), not multiple in a
-- single tick. That's the gradual decay we want, not a cliff.

-- ── 1) Replace the lifestyle-demand rows with the cumulative table ──
DELETE FROM public.housing_lifestyle_demands;

INSERT INTO public.housing_lifestyle_demands (tier, resource_key, qty_per_minute) VALUES
  -- T2 Cottage
  (2, 'pottery',   0.10),
  -- T3 Townhouse
  (3, 'pottery',   0.15),
  (3, 'bread',     0.10),
  -- T4 Villa
  (4, 'pottery',   0.20),
  (4, 'bread',     0.15),
  (4, 'furniture', 0.10),
  -- T5 Manor
  (5, 'pottery',   0.25),
  (5, 'bread',     0.20),
  (5, 'furniture', 0.15),
  (5, 'statuary',  0.10),
  -- T6 Mansion
  (6, 'pottery',   0.30),
  (6, 'bread',     0.25),
  (6, 'furniture', 0.20),
  (6, 'statuary',  0.15),
  -- T7 Estate
  (7, 'pottery',   0.35),
  (7, 'bread',     0.30),
  (7, 'furniture', 0.25),
  (7, 'statuary',  0.20),
  -- T8 Palace
  (8, 'pottery',   0.40),
  (8, 'bread',     0.35),
  (8, 'furniture', 0.30),
  (8, 'statuary',  0.25);

-- ── 2) River Traders sells pottery ──
-- The new T2 lifestyle gate is otherwise unreachable for non-clay
-- starters: river_traders is the only NPC every player has from day 1,
-- and it doesn't currently stock pottery. Price is set above
-- desert_caravan ($10) and mountain_folk ($7) so the better partners
-- still feel worth unlocking, but the wall is no longer hard.
INSERT INTO public.trader_prices
  (trader_key, resource_key, buy_price, sell_price, daily_buy_cap, daily_sell_cap)
VALUES
  ('river_traders', 'pottery', 13, NULL, 300, NULL)
ON CONFLICT (trader_key, resource_key) DO UPDATE SET
  buy_price = EXCLUDED.buy_price,
  daily_buy_cap = EXCLUDED.daily_buy_cap;

-- ── 3) One-time pottery grant for existing T3+ cities ──
-- The cumulative model means any house at T3+ instantly starts needing
-- pottery to maintain its tier — but existing players had no reason to
-- stockpile any. Grant 100 pottery (≈ 40 min runway at a 16-Townhouse
-- consumption rate) to anyone whose city is already past Cottage, so
-- their first encounter with the new system isn't watching half their
-- city devolve before they know what changed.
UPDATE public.inventories
   SET quantity = quantity + 100,
       updated_at = now()
 WHERE resource_key = 'pottery'
   AND player_id IN (
     SELECT DISTINCT player_id FROM public.buildings
     WHERE building_type_key = 'house' AND housing_tier >= 3
   );
