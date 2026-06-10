-- ─────────────────────────────────────────────────────────────────────
-- Food-spine symmetry (2026-06-10).
--
-- Iron uniquely had a 4th food building (Bakery → bread) that timber/
-- stone/clay lacked, so its column was 11 buildings vs everyone else's
-- 10. This adds a parallel T3 "staple food" building to the other three
-- so all four industry columns are 11-for-11. See public/codex.html.
--
--   timber: Cookhouse      wine        → stew
--   stone:  Galley         smoked_fish → chowder
--   clay:   Pottage House  preserves   → pottage
--   iron:   Bakery (existing) flour    → bread
--
-- Building stats mirror Bakery exactly. The new outputs are basic foods
-- (is_food, NOT luxury). Whether they should ALSO be universal housing
-- lifestyle demands like bread (economy-layer parity) is a separate
-- balance decision and is intentionally NOT done here.
-- Idempotent: safe to re-run.
-- ─────────────────────────────────────────────────────────────────────

-- 1. New basic-food resources (mirror bread; industry-keyed like wine/smoked_fish/preserves)
INSERT INTO public.resources (key, name, kind, industry_key, is_active, is_food, is_luxury_food, is_industrial_luxury, base_price) VALUES
  ('stew',    'Stew',    'processed', 'timber', true, true, false, false, 15),
  ('chowder', 'Chowder', 'processed', 'stone',  true, true, false, false, 15),
  ('pottage', 'Pottage', 'processed', 'clay',   true, true, false, false, 15)
ON CONFLICT (key) DO UPDATE SET
  name=EXCLUDED.name, kind=EXCLUDED.kind, industry_key=EXCLUDED.industry_key,
  is_active=EXCLUDED.is_active, is_food=EXCLUDED.is_food,
  is_luxury_food=EXCLUDED.is_luxury_food, is_industrial_luxury=EXCLUDED.is_industrial_luxury,
  base_price=EXCLUDED.base_price;

-- 2. New buildings (mirror bakery: tier-3 processor, $400/10w, in@1 → out@0.5, pollution 5/3, waste 1, power_load 3, noise 3/2)
INSERT INTO public.building_types
  (key, name, tier, industry_key, category, build_cost, worker_cost,
   input_resource_key, input_rate, output_resource_key, output_rate, is_active,
   boost_multiplier, footprint_w, footprint_h,
   pollution_emit, pollution_radius, waste_emit, power_load, noise_emit, noise_radius)
VALUES
  ('cookhouse',     'Cookhouse',     3, 'timber', 'processor', 400, 10, 'wine',        1, 'stew',    0.5, true, 1.0, 1, 1, 5, 3, 1, 3, 3, 2),
  ('galley',        'Galley',        3, 'stone',  'processor', 400, 10, 'smoked_fish', 1, 'chowder', 0.5, true, 1.0, 1, 1, 5, 3, 1, 3, 3, 2),
  ('pottage_house', 'Pottage House', 3, 'clay',   'processor', 400, 10, 'preserves',   1, 'pottage', 0.5, true, 1.0, 1, 1, 5, 3, 1, 3, 3, 2)
ON CONFLICT (key) DO UPDATE SET
  name=EXCLUDED.name, tier=EXCLUDED.tier, industry_key=EXCLUDED.industry_key, category=EXCLUDED.category,
  build_cost=EXCLUDED.build_cost, worker_cost=EXCLUDED.worker_cost,
  input_resource_key=EXCLUDED.input_resource_key, input_rate=EXCLUDED.input_rate,
  output_resource_key=EXCLUDED.output_resource_key, output_rate=EXCLUDED.output_rate,
  is_active=EXCLUDED.is_active, boost_multiplier=EXCLUDED.boost_multiplier,
  footprint_w=EXCLUDED.footprint_w, footprint_h=EXCLUDED.footprint_h,
  pollution_emit=EXCLUDED.pollution_emit, pollution_radius=EXCLUDED.pollution_radius,
  waste_emit=EXCLUDED.waste_emit, power_load=EXCLUDED.power_load,
  noise_emit=EXCLUDED.noise_emit, noise_radius=EXCLUDED.noise_radius;

-- 3. Build costs (mirror bakery: brick 10, lumber 8, tools 3)
INSERT INTO public.building_type_resource_costs (building_type_key, resource_key, quantity) VALUES
  ('cookhouse','brick',10),('cookhouse','lumber',8),('cookhouse','tools',3),
  ('galley','brick',10),('galley','lumber',8),('galley','tools',3),
  ('pottage_house','brick',10),('pottage_house','lumber',8),('pottage_house','tools',3)
ON CONFLICT (building_type_key, resource_key) DO UPDATE SET quantity=EXCLUDED.quantity;
