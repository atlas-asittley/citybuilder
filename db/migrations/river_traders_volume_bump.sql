-- ─────────────────────────────────────────────────────────────────────
-- river_traders volume bump (2026-05-08).
--
-- Atlas: "we need them to trade about 10 times more of each thing
-- per day, and we need their trade capacity per visit to increase
-- by 50%."
--
-- Effects:
--   - traders.visit_capacity:        20 → 30  (+50%)
--   - trader_prices.daily_buy_cap:   ×10
--   - trader_prices.daily_sell_cap:  ×10
--
-- Caps preserve the earlier raw-resource bump from
-- river_traders_raw_resource_bump.sql (raw materials at 45 → 450,
-- manufactured at 30 → 300). Visit interval (10 min) unchanged —
-- frequency stays the same; each visit just moves more.
-- ─────────────────────────────────────────────────────────────────────

UPDATE public.traders
   SET visit_capacity = 30
 WHERE key = 'river_traders';

UPDATE public.trader_prices
   SET daily_buy_cap  = daily_buy_cap  * 10,
       daily_sell_cap = daily_sell_cap * 10
 WHERE trader_key = 'river_traders'
   AND city_id IS NULL;
