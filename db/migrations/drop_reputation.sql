-- ─────────────────────────────────────────────────────────────────────
-- Drop the reputation system. Dead code since missions removed today.
--
-- Was: missions awarded reputation per-player; city_reputation aggregated
-- across districts; city_rep_tier mapped that into a 0-3 tier;
-- get_trade_partner_view exposed it to the JS. None of the JS reads it
-- and missions are gone, so:
--   - decay_reputations would never run (only get_active_missions called
--     it, and that's deleted)
--   - trader_relationships.reputation just freezes at current values
--   - get_trade_partner_view has no callers (was the missions panel's
--     other RPC) and exists only to compute reputation
--
-- Cascade order: drop fns first (they reference the table), then table.
-- ─────────────────────────────────────────────────────────────────────

DROP FUNCTION IF EXISTS public.get_trade_partner_view();
DROP FUNCTION IF EXISTS public.city_rep_tier(text);
DROP FUNCTION IF EXISTS public.city_reputation(text);
DROP FUNCTION IF EXISTS public.decay_reputations();

DROP TABLE IF EXISTS public.trader_relationships;
