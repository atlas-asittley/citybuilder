-- ─────────────────────────────────────────────────────────────────────
-- Resource costs for placing buildings (2026-05-08).
--
-- Atlas's design: money is no longer the only build cost. Most
-- buildings now also consume a small set of resources from the
-- player's inventory at placement time.
--
-- Money-only (Atlas's explicit list):
--   - housing                            (house)
--   - basic extractors per industry      (timber_camp, stone_quarry,
--                                         clay_pit, iron_mine)
--   - food extractors / farms            (orchard, fishing_pier,
--                                         garden, grain_farm)
--   - road / well                        (foundational infra)
--   - tree_grove                         (small park, decorative)
--
-- Everything else: money + 1-4 resources. The pattern is:
--   - basic processors: their raw input + one bought-from-trader
--     basic-processed (forces early engagement with river_traders
--     for the cross-industry resource)
--   - tier-3 processors: add `tools` so toolmaker becomes a soft
--     prereq for advanced industry
--   - tier-4 luxury processors: cross-industry finished goods
--     (tiles, glass, machinery)
--   - services: scale by tier — bathhouse needs lime; school needs
--     tools; temple needs lime + tiles
--   - transport: large multi-resource costs since they're 8k-50k
--     money already
--
-- Schema: separate table over a jsonb column — easier to JOIN +
-- query for the UI cost row.
-- ─────────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS public.building_type_resource_costs (
  building_type_key text NOT NULL REFERENCES public.building_types(key) ON DELETE CASCADE,
  resource_key      text NOT NULL REFERENCES public.resources(key),
  quantity          integer NOT NULL CHECK (quantity > 0),
  PRIMARY KEY (building_type_key, resource_key)
);

ALTER TABLE public.building_type_resource_costs ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS btrc_read_all ON public.building_type_resource_costs;
CREATE POLICY btrc_read_all ON public.building_type_resource_costs
  FOR SELECT USING (true);

-- Idempotent: drop existing rows so re-runs apply the latest curve.
DELETE FROM public.building_type_resource_costs;

-- ── Boosters (200g) — small amounts of industry-relevant resources ──
INSERT INTO public.building_type_resource_costs VALUES
  ('foresters_office',  'lumber',     5),
  ('apiary',            'lumber',     5),
  ('mine_office',       'iron',       5),
  ('mine_office',       'lumber',     3),
  ('irrigation_channel','brick',      5),
  ('irrigation_channel','lumber',     3),
  ('foreman_office',    'stone',      5),
  ('foreman_office',    'lumber',     3),
  ('hatchery',          'lumber',     8),
  ('clay_master_hut',   'clay',       5),
  ('clay_master_hut',   'lumber',     3),
  ('compost_heap',      'timber',     5);

-- ── Park (tree_grove stays money-only) ──
INSERT INTO public.building_type_resource_costs VALUES
  ('park',              'lumber',     5),
  ('park',              'stone',      5);

-- ── Tier-2 processors — raw input + one bought basic-processed ──
INSERT INTO public.building_type_resource_costs VALUES
  -- Timber chain
  ('sawmill',           'timber',    10),
  ('sawmill',           'brick',      5),
  ('charcoal_kiln',     'timber',     8),
  ('charcoal_kiln',     'brick',      5),
  ('winery',            'lumber',     8),
  ('winery',            'brick',      5),
  ('winery',            'pottery',    3),
  -- Stone chain
  ('mason_workshop',    'stone',     10),
  ('mason_workshop',    'lumber',     5),
  ('lime_kiln',         'stone',      8),
  ('lime_kiln',         'brick',      5),
  ('smokehouse',        'lumber',     8),
  ('smokehouse',        'brick',      5),
  -- Iron chain
  ('smelter',           'iron',      10),
  ('smelter',           'brick',      8),
  ('smelter',           'lumber',     5),
  ('nail_forge',        'iron',       5),
  ('nail_forge',        'lumber',     5),
  ('mill',              'lumber',     8),
  ('mill',              'brick',      5),
  -- Clay chain
  ('pottery_kiln',      'clay',      10),
  ('pottery_kiln',      'brick',      8),
  ('cannery',           'lumber',     8),
  ('cannery',           'brick',      5),
  ('cannery',           'iron',       3),
  ('glassworks',        'clay',       8),
  ('glassworks',        'brick',      5),
  ('glassworks',        'lumber',     3);

-- ── Tier-3 processors — adds `tools` and finished basics ──
INSERT INTO public.building_type_resource_costs VALUES
  -- Timber chain
  ('woodcarver',        'lumber',    12),
  ('woodcarver',        'tools',      5),
  ('distillery',        'lumber',     8),
  ('distillery',        'brick',      8),
  ('distillery',        'glass',      3),
  -- Stone chain
  ('sculptor',          'stone',     12),
  ('sculptor',          'tools',      5),
  ('curing_house',      'brick',     10),
  ('curing_house',      'lime',       5),
  ('curing_house',      'tools',      3),
  -- Iron chain
  ('toolmaker',         'iron',      10),
  ('toolmaker',         'lumber',     8),
  ('toolmaker',         'nails',      3),
  ('bakery',            'brick',     10),
  ('bakery',            'lumber',     8),
  ('bakery',            'tools',      3),
  ('brewery',           'brick',     12),
  ('brewery',           'iron',       5),
  ('brewery',           'lumber',     5),
  -- Clay chain
  ('tile_maker',        'clay',       8),
  ('tile_maker',        'brick',     10),
  ('tile_maker',        'lime',       5),
  ('spicery',           'brick',     10),
  ('spicery',           'glass',      5),
  ('spicery',           'tools',      3);

-- ── Tier-4 luxury processors — cross-industry finished goods ──
INSERT INTO public.building_type_resource_costs VALUES
  ('mosaic_workshop',   'tiles',     10),
  ('mosaic_workshop',   'stone',      8),
  ('mosaic_workshop',   'tools',      5),
  ('cabinetmaker',      'lumber',    15),
  ('cabinetmaker',      'nails',      8),
  ('cabinetmaker',      'tools',      5),
  ('engineer_workshop', 'iron',      15),
  ('engineer_workshop', 'tools',     10),
  ('engineer_workshop', 'nails',      5),
  ('architect',         'stone',     12),
  ('architect',         'glass',      5),
  ('architect',         'tools',      5);

-- ── Services ──
INSERT INTO public.building_type_resource_costs VALUES
  ('bathhouse',         'brick',      8),
  ('bathhouse',         'lime',       5),
  ('tavern',            'lumber',    10),
  ('tavern',            'brick',      5),
  ('tavern',            'pottery',    3),
  ('school',            'brick',     12),
  ('school',            'lumber',    10),
  ('school',            'tools',      5),
  ('temple',            'stone',     15),
  ('temple',            'lime',       8),
  ('temple',            'tiles',      5);

-- ── Tax + Police ──
INSERT INTO public.building_type_resource_costs VALUES
  ('tax_man',           'lumber',     8),
  ('tax_man',           'brick',      8),
  ('tax_man',           'tools',      3),
  ('watch_house',       'lumber',    10),
  ('watch_house',       'brick',      8),
  ('police_station',    'brick',     12),
  ('police_station',    'iron',       8),
  ('police_station',    'tools',      3),
  ('constabulary',      'stone',     15),
  ('constabulary',      'brick',     10),
  ('constabulary',      'iron',       8),
  ('constabulary',      'tools',      5);

-- ── Transport (chunky multi-resource costs to match $8k-$50k money) ──
INSERT INTO public.building_type_resource_costs VALUES
  ('truck_depot',       'brick',     30),
  ('truck_depot',       'lumber',    20),
  ('truck_depot',       'iron',      15),
  ('truck_depot',       'nails',     10),
  ('train_depot',       'stone',     50),
  ('train_depot',       'iron',      30),
  ('train_depot',       'tools',     20),
  ('train_depot',       'brick',     30),
  ('seaport',           'stone',     60),
  ('seaport',           'lumber',    40),
  ('seaport',           'iron',      25),
  ('seaport',           'tools',     15),
  ('airport',           'stone',     50),
  ('airport',           'iron',      30),
  ('airport',           'tools',     25),
  ('airport',           'glass',     15);
