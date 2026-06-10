-- ─────────────────────────────────────────────────────────────────────
-- river_traders second 10x volume bump (2026-05-08).
--
-- Context: now that daily caps are actually enforced (per-player —
-- per_player_trade_quotas.sql earlier today), the previously-decorative
-- caps are real ceilings. Atlas wants the always-on starter to keep
-- being a workhorse rather than tap out by mid-day.
--
-- Before: 300/300 manufactured, 450/450 raw (after the prior 10x +
-- 50% raw bumps).
-- After:  3000/3000 manufactured, 4500/4500 raw.
-- ─────────────────────────────────────────────────────────────────────

UPDATE public.trader_prices
   SET daily_buy_cap  = daily_buy_cap  * 10,
       daily_sell_cap = daily_sell_cap * 10
 WHERE trader_key = 'river_traders'
   AND city_id IS NULL;
