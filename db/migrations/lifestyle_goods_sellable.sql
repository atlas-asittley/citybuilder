-- ── NPC traders SELL the four lifestyle goods (2026-05-08) ──
-- The cumulative lifestyle pivot made every player need pottery, bread,
-- furniture, and statuary regardless of industry. Each good is produced
-- by exactly one industry (pottery=clay, bread=iron, furniture=timber,
-- statuary=stone), so non-producing players need to import them.
--
-- The trader catalog had only the BUY side filled (trader purchases
-- from player) for these four goods — `sell_price` was NULL across
-- every (trader × good) cell, so the buy_to_reserve loop in
-- _rtv_buy_phase always skipped and no one could actually import.
--
-- This patch adds sell_price + daily_sell_cap to all 12 cells
-- (4 goods × 3 traders) using the same gradient the existing rows
-- follow: mountain_folk has the most generous prices (cheapest to buy
-- from), desert_caravan in the middle, river_traders the most
-- expensive (since it's the always-on starter trader). Markups over
-- the existing buy_price are 50-75%, matching grain/stone/timber.
--
-- Daily sell cap = 200 across the board, mirroring the raw-resource
-- caps already in place (river_traders grain/stone/timber daily_sell_cap
-- is 200, etc.). 200 lifestyle goods/day per trader is plenty for
-- a starter city.
--
-- After this patch, a non-producing player can keep a single tier of
-- housing alive purely by buying from one trader, and the markup means
-- in-house production (or partner trade) is meaningfully cheaper.

UPDATE public.trader_prices SET sell_price = 18, daily_sell_cap = 200 WHERE trader_key = 'river_traders'  AND resource_key = 'pottery';
UPDATE public.trader_prices SET sell_price = 14, daily_sell_cap = 200 WHERE trader_key = 'desert_caravan' AND resource_key = 'pottery';
UPDATE public.trader_prices SET sell_price = 10, daily_sell_cap = 200 WHERE trader_key = 'mountain_folk'  AND resource_key = 'pottery';

UPDATE public.trader_prices SET sell_price = 18, daily_sell_cap = 200 WHERE trader_key = 'river_traders'  AND resource_key = 'bread';
UPDATE public.trader_prices SET sell_price = 22, daily_sell_cap = 200 WHERE trader_key = 'desert_caravan' AND resource_key = 'bread';
UPDATE public.trader_prices SET sell_price = 14, daily_sell_cap = 200 WHERE trader_key = 'mountain_folk'  AND resource_key = 'bread';

UPDATE public.trader_prices SET sell_price = 22, daily_sell_cap = 200 WHERE trader_key = 'river_traders'  AND resource_key = 'furniture';
UPDATE public.trader_prices SET sell_price = 28, daily_sell_cap = 200 WHERE trader_key = 'desert_caravan' AND resource_key = 'furniture';
UPDATE public.trader_prices SET sell_price = 18, daily_sell_cap = 200 WHERE trader_key = 'mountain_folk'  AND resource_key = 'furniture';

UPDATE public.trader_prices SET sell_price = 22, daily_sell_cap = 200 WHERE trader_key = 'river_traders'  AND resource_key = 'statuary';
UPDATE public.trader_prices SET sell_price = 30, daily_sell_cap = 200 WHERE trader_key = 'desert_caravan' AND resource_key = 'statuary';
UPDATE public.trader_prices SET sell_price = 16, daily_sell_cap = 200 WHERE trader_key = 'mountain_folk'  AND resource_key = 'statuary';
