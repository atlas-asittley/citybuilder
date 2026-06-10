-- ─────────────────────────────────────────────────────────────────────
-- Transport network buildings emit pollution (2026-05-11).
--
-- Atlas: "the transport network buildings should make pollution."
--
-- Calibrated against the existing emit / radius scale:
--   heavy industry (smelters, kilns, glassworks): 10 / r4
--   medium processors (sawmill, pottery_kiln, mill, etc.):  5 / r3
--   extractors (mines, timber camps):               2 / r2
--   parks (negative — dampen):                  -4/-8 / r3-4
--
-- New transport tier mirrors that ordering — air > sea > train > truck,
-- scaled roughly with footprint size and real-world fuel intensity:
--
--   airport      (3x3): emit 15, radius 5  (jet exhaust + 24/7 ops)
--   seaport      (3x2): emit 12, radius 5  (heavy diesel shipping)
--   train_depot  (3x2): emit 10, radius 4  (diesel locos, same tier
--                                           as heavy industrial)
--   truck_depot  (2x2): emit  6, radius 3  (small fleet, idle exhaust,
--                                           same tier as medium proc)
--
-- _pp_update_pollution already sums emit × radius coverage from every
-- active building, so no compute-side change needed — flipping the
-- columns is enough.
--
-- Players with existing hubs will see desirability drop on adjacent
-- tiles starting from the next tick. Build a Park or Tree Grove to
-- offset. Heads-up text in the changelog.
-- ─────────────────────────────────────────────────────────────────────

UPDATE public.building_types SET pollution_emit = 15, pollution_radius = 5 WHERE key = 'airport';
UPDATE public.building_types SET pollution_emit = 12, pollution_radius = 5 WHERE key = 'seaport';
UPDATE public.building_types SET pollution_emit = 10, pollution_radius = 4 WHERE key = 'train_depot';
UPDATE public.building_types SET pollution_emit = 6,  pollution_radius = 3 WHERE key = 'truck_depot';


INSERT INTO public.changelog_entries (slug, title, body)
VALUES (
  '2026-05-11-transport-pollution',
  'Transport hubs now produce pollution',
  E'Airports, seaports, train depots, and truck depots now emit pollution like the heavy industries do — the bigger the hub, the broader the smog.\n\n• Airport: 15 emit, radius 5\n• Seaport: 12 emit, radius 5\n• Train Depot: 10 emit, radius 4\n• Truck Depot: 6 emit, radius 3\n\nPollution pushes tile desirability down, which means housing near a transport hub may stop qualifying for higher tiers. Use Parks (−8 emit, radius 3) or Tree Groves (−4, radius 4) nearby to offset.'
)
ON CONFLICT (slug) DO NOTHING;
