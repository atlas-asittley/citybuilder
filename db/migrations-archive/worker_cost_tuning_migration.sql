-- ============================================================
-- City Builder — Worker-cost tuning
-- ============================================================
-- Standardizes the workers required per production building so
-- there's a real reason to build more housing past the first few
-- shanties. Idempotent — safe to re-run.
--
--   Tier 1 extractors: 2 workers (timber_camp, stone_quarry)
--                      3 workers (clay_pit)
--                      4 workers (grain_farm — already 4)
--   Tier 2 processors: 3 workers (sawmill, mason_workshop, pottery_kiln, mill)
--   Tier 3 artisans:   4 workers (bakery, sculptor, woodcarver)
-- ============================================================

UPDATE public.building_types SET worker_cost = 2
WHERE category = 'extractor' AND tier = 1 AND key IN ('timber_camp','stone_quarry');

UPDATE public.building_types SET worker_cost = 3
WHERE category = 'extractor' AND key = 'clay_pit';

UPDATE public.building_types SET worker_cost = 4
WHERE category = 'extractor' AND key = 'grain_farm';

UPDATE public.building_types SET worker_cost = 3
WHERE category = 'processor' AND tier = 2
  AND key IN ('sawmill','mason_workshop','pottery_kiln','mill');

UPDATE public.building_types SET worker_cost = 4
WHERE category = 'processor' AND tier = 3
  AND key IN ('bakery','sculptor','woodcarver');
