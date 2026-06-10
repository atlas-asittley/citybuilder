-- Drop two unused tables that were RLS-enabled with no policies:
--   counter        — single-row counter, never read or written by JS/RPCs.
--   trade_offers   — predecessor of player_trade_offers, fully replaced.
-- Confirmed no FKs, RPCs, or JS callers reference either.

DROP TABLE IF EXISTS public.counter;
DROP TABLE IF EXISTS public.trade_offers;
