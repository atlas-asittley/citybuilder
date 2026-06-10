-- ─────────────────────────────────────────────────────────────────────
-- Bump river_traders (Neighboring City) daily caps by 50% on raw
-- resources only — the 8 "most basic" goods (kind='raw'):
--   timber, stone, clay, iron, grain, vegetables, berries, fish.
--
-- Atlas's intent (2026-05-08): "increase the amount of trade that the
-- initial trading partner is willing to trade [...] only for the most
-- basic resources, not anything manufactured from those. just the most
-- basic resources. and food."
--
-- All raw resources include both raw materials (timber/stone/clay/iron)
-- and raw foods (grain/vegetables/berries/fish), so kind='raw' covers
-- the intent in one filter without dragging in manufactured items
-- like bread/flour/preserves/wine.
--
-- 30/30 → 45/45 daily caps. Manufactured + lifestyle goods stay at 30
-- as set by randomize_trader_catalogs.sql.
-- ─────────────────────────────────────────────────────────────────────

UPDATE public.trader_prices
   SET daily_buy_cap = ROUND(daily_buy_cap * 1.5)::integer,
       daily_sell_cap = ROUND(daily_sell_cap * 1.5)::integer
 WHERE trader_key = 'river_traders'
   AND city_id IS NULL
   AND resource_key IN (
     SELECT key FROM public.resources WHERE is_active AND kind = 'raw'
   );
