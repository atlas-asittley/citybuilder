-- trader_name_pool_rls.sql
--
-- Closes the one finding behind Supabase's recurring weekly
-- "Action required: security vulnerabilities detected" email
-- (advisor rule rls_disabled_in_public).
--
-- public.trader_name_pool was created by procedural_traders.sql without
-- RLS, leaving anon with full SELECT/INSERT/UPDATE/DELETE on the 100-row
-- flavour-name pool. Nothing reads it from the client: the only consumer
-- is _pick_trader_name(), called from _spawn_random_trader(), which is
-- SECURITY DEFINER and owned by postgres. postgres owns the table, so it
-- bypasses RLS -- enabling RLS with zero policies locks out anon without
-- touching trader spawning.
--
-- Same shape as changelog_entries: RLS on, no policies, reached only
-- through SECURITY DEFINER RPCs.

ALTER TABLE public.trader_name_pool ENABLE ROW LEVEL SECURITY;

-- Defence in depth, and matches the grant model Supabase makes the
-- default for new tables on 2026-10-30.
REVOKE ALL ON public.trader_name_pool FROM anon, authenticated;
