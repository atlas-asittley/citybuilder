-- ============================================================================
-- civic_metrics_cleanup.sql — small data-hygiene fixes from the 2026-05-29
-- integrity audit. Additive/corrective; safe to re-run.
-- ----------------------------------------------------------------------------
-- The fancier_roads migration added building_types.road_tier with DEFAULT 1,
-- which backfilled EVERY non-road building to road_tier=1 (houses, processors,
-- services, …). Harmless today (the only reader gates on category='road'), but
-- a latent trap: any future generic read of road_tier would treat every
-- building as a tier-1 road. Reset non-roads to 0 and make 0 the default.
-- ============================================================================

BEGIN;

ALTER TABLE public.building_types ALTER COLUMN road_tier SET DEFAULT 0;
UPDATE public.building_types SET road_tier = 0 WHERE category <> 'road' AND road_tier <> 0;

COMMIT;
