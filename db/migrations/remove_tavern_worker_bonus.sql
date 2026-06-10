-- ── Remove the Tavern's +10 worker bonus (2026-05-08) ──
-- Atlas: the +10 phantom-workers mechanic was confusing — even with the
-- "+10🍺" badge surfacing it on the topbar, "fed tavern adds workers
-- you don't have housing for" doesn't read as a coherent rule.
--
-- Removed: the tavern_bonus path in _pp_tavern_bonus (returns 0 now,
-- which keeps the calling sites in process_production / population
-- update working without code changes — just always adding 0).
--
-- Kept: the Tavern's other effects.
--   • +5% productivity bonus when staffed + fed (productivity_v2.sql).
--   • +1 crime per active tavern (balance_tweaks_2026_05_07.sql).
--   • Continues to consume bread + pottery as upkeep.
-- A tavern is now a tradeoff between a productivity gain and a small
-- crime hit, paid in luxury-good upkeep — a clearer mental model than
-- "where did those extra workers come from?"

CREATE OR REPLACE FUNCTION public._pp_tavern_bonus(p_uid uuid)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
BEGIN
  -- The +10 worker-capacity bonus was removed on 2026-05-08. The
  -- function is preserved as a no-op to keep older callers working
  -- (process_production still calls it; the variable just gets 0).
  -- See migration_patches/remove_tavern_worker_bonus.sql for context.
  RETURN 0;
END;
$function$;
