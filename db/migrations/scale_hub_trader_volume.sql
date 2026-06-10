-- ─────────────────────────────────────────────────────────────────────
-- 100× the trade volume for hub-unlocked partners (2026-05-10).
--
-- Atlas: "new trade partners currently don't trade enough. they
-- should buy and sell 100 times as much when you get a new trade
-- partner."
--
-- Current state: river_traders (starter, always-on) has daily caps
-- 3000-4500 per resource. Hub-unlocked partners (airport / seaport /
-- train / truck — the ones you have to BUILD a hub to access) have
-- daily caps in the 30-800 range. So unlocking a new partner often
-- felt anticlimactic: you spent $40k on a Seaport and got a partner
-- that trades a tenth of what river_traders already does.
--
-- Fix: multiply BOTH knobs by 100 for hub-unlocked partners only:
--   - traders.visit_capacity  (units traded per visit)
--   - trader_prices.daily_buy_cap / daily_sell_cap (per-day cap)
--
-- Filter: transport_mode IS NOT NULL — picks exactly the four
-- hub-mode traders. Excludes river_traders (mode=NULL, is_active),
-- black_market and the two inactive flavor traders (also mode=NULL).
--
-- Reads stay constant — buy/sell prices unchanged. Player still
-- gates volume via reservation prices + reserve targets.
-- ─────────────────────────────────────────────────────────────────────

UPDATE public.traders
SET visit_capacity = visit_capacity * 100
WHERE transport_mode IS NOT NULL;

UPDATE public.trader_prices
SET daily_buy_cap  = daily_buy_cap  * 100,
    daily_sell_cap = daily_sell_cap * 100
WHERE trader_key IN (
  SELECT key FROM public.traders WHERE transport_mode IS NOT NULL
);


-- Changelog entry — this is a player-visible balance change.
INSERT INTO public.changelog_entries (slug, title, body)
VALUES (
  '2026-05-10-hub-trader-volume',
  'Hub trade partners: 100× more volume',
  E'Trade partners unlocked through transport hubs (airport / seaport / train / truck) now buy and sell roughly 100× more per visit and per day. Building a hub is now a real volume play instead of an anticlimactic unlock.\n\nThe starter trader (Neighboring City) is unchanged. Prices are unchanged — the bump is purely on quantity. Your reservation-price gates and reserve targets still control when and what you trade.'
)
ON CONFLICT (slug) DO NOTHING;
