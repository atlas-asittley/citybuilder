-- Raise worker requirements on extractors and processors to 10 each.
-- The all-or-nothing staffing gate already exists in process_production
-- (a building only joins v_staffed_ids if worker_supply >= its worker_cost,
-- and only staffed buildings produce). Bumping the costs makes that gate
-- bite — today's 2-4 worker reqs are low enough that the gate almost
-- never triggers, which the user experienced as "partial staffing
-- produces." With reqs at 10, the early-game economy is the thing the
-- user wants tightened.
--
-- Apply: psql "$DB_URL" -f raise_worker_costs.sql
-- Tunable; revisit once early-game flow is observed.

UPDATE public.building_types
SET worker_cost = 10
WHERE category IN ('extractor', 'processor');
