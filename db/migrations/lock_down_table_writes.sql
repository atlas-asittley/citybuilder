-- ─────────────────────────────────────────────────────────────────────
-- 🚨 SECURITY: drop direct INSERT/UPDATE/DELETE RLS policies on
-- buildings + player_profiles + similar player-scoped tables.
--
-- Audit found that buildings_update_self / buildings_insert_self /
-- buildings_delete_self existed even though every legitimate JS path
-- goes through SECURITY DEFINER RPCs. With the policies in place, any
-- authenticated player could:
--   - INSERT a building bypassing place_building's footprint /
--     money / resource cost / road validation
--   - UPDATE building_type_key / x / y / housing_tier directly
--     (turn a $60 house into a $50,000 airport for free, jump tiers,
--      teleport buildings, etc)
--   - DELETE without going through demolish_building (dodge the
--     refund + cash ledger)
--
-- Same shape for player_profiles UPDATE — directly UPDATE-able money
-- column was the cheat-from-DevTools attack.
--
-- All real JS paths use RPCs now (place_building, demolish_building,
-- upgrade_house, dev_grant_money, etc). Drop these policies. SELECT
-- policies stay — clients still need to read.
--
-- Internal mutations from RPCs use SECURITY DEFINER which runs as the
-- table-owner role and bypasses RLS, so no internal flow breaks.
-- ─────────────────────────────────────────────────────────────────────

DROP POLICY IF EXISTS buildings_insert_self ON public.buildings;
DROP POLICY IF EXISTS buildings_update_self ON public.buildings;
DROP POLICY IF EXISTS buildings_delete_self ON public.buildings;

DROP POLICY IF EXISTS player_profiles_insert_self ON public.player_profiles;
DROP POLICY IF EXISTS player_profiles_update_self ON public.player_profiles;

-- inventories: writes also go through RPCs (process_production phase
-- helpers + black_market_trade + accept_trade + etc, all SECURITY
-- DEFINER). Drop client-write policies.
DROP POLICY IF EXISTS inventories_insert_self ON public.inventories;
DROP POLICY IF EXISTS inventories_update_self ON public.inventories;

-- trade_policies: save_trade_policy RPC is the only legit writer.
DROP POLICY IF EXISTS trade_policies_insert_self ON public.trade_policies;
DROP POLICY IF EXISTS trade_policies_update_self ON public.trade_policies;

-- trader_visits + trade_transactions: server-only writers (process_production
-- phases, accept_trade, sell_to_trader, black_market_trade).
DROP POLICY IF EXISTS trader_visits_insert_self ON public.trader_visits;
DROP POLICY IF EXISTS trade_transactions_insert_self ON public.trade_transactions;
DROP POLICY IF EXISTS trade_agreements_insert ON public.trade_agreements;
DROP POLICY IF EXISTS trade_agreements_update ON public.trade_agreements;
