-- Industry tree buildout: lock the food/industry chains to their
-- industries and fill in tree-shape gaps so all four industries have the
-- same depth.
--
-- Architecture (Atlas's framing): two categories of buildings —
--   1. Industry/food buildings: per-industry development trees, locked
--      via building_types.industry_key
--   2. General buildings: shared by everyone (housing, road, services,
--      tax). industry_key = 'common'.
--
-- Tree shape after this migration:
--   T1 industry extractor → T2 processor → T3 advanced processor
--   T1 food extractor     → T2 food processor (→ T3 for grain only via bakery)
--
-- Locks applied here (industry_key common → industry-specific):
--   clay_pit       → clay
--   pottery_kiln   → clay
--   mill           → iron (grain → flour, part of iron's food chain)
--   bakery         → iron (flour → bread)
--
-- New resources (6):
--   iron_ingot, tools     (iron, not food)
--   tiles                 (clay, not food)
--   wine, smoked_fish, preserves  (foods, is_food=true)
--
-- New buildings (6):
--   smelter      iron T2: iron → iron_ingot
--   toolmaker    iron T3: iron_ingot → tools
--   tile_maker   clay T3: pottery → tiles
--   winery       timber food T2: berries → wine
--   smokehouse   stone food T2: fish → smoked_fish
--   cannery      clay food T2: vegetables → preserves
--
-- Apply: psql "$DB_URL" -f industry_tree_buildout.sql

-- ── 1. Lock existing buildings to industries ──
UPDATE public.building_types SET industry_key = 'clay' WHERE key IN ('clay_pit', 'pottery_kiln');
UPDATE public.building_types SET industry_key = 'iron' WHERE key IN ('mill', 'bakery');

-- ── 2. New industry resources ──
INSERT INTO public.resources (key, name, kind, industry_key, is_active, is_food) VALUES
  ('iron_ingot',  'Iron Ingot',  'processed', 'iron',   true, false),
  ('tools',       'Tools',       'processed', 'iron',   true, false),
  ('tiles',       'Tiles',       'processed', 'clay',   true, false),
  ('wine',        'Wine',        'processed', 'timber', true, true),
  ('smoked_fish', 'Smoked Fish', 'processed', 'stone',  true, true),
  ('preserves',   'Preserves',   'processed', 'clay',   true, true)
ON CONFLICT (key) DO UPDATE SET
  name = EXCLUDED.name, kind = EXCLUDED.kind,
  industry_key = EXCLUDED.industry_key,
  is_active = EXCLUDED.is_active, is_food = EXCLUDED.is_food;

-- ── 3. New industry processors ──
-- Costs / rates mirror existing T2 processors (sawmill / mason_workshop /
-- pottery_kiln) and T3 processors (woodcarver / sculptor / bakery) —
-- $300/$450, 10w, 1→0.5 (T2) and 0.5→0.25 (T3) ratios — for symmetry.
INSERT INTO public.building_types
  (key, name, tier, industry_key, category, build_cost, worker_cost,
   input_resource_key, input_rate, output_resource_key, output_rate,
   is_active, workers_provided)
VALUES
  -- Industry T2/T3 fills
  ('smelter',     'Smelter',     2, 'iron',   'processor', 300, 10,
   'iron',        '1',   'iron_ingot',  '0.5',  true, 0),
  ('toolmaker',   'Toolmaker',   3, 'iron',   'processor', 450, 10,
   'iron_ingot',  '0.5', 'tools',       '0.25', true, 0),
  ('tile_maker',  'Tile Maker',  3, 'clay',   'processor', 450, 10,
   'pottery',     '0.5', 'tiles',       '0.25', true, 0),
  -- Food T2 fills (mirroring mill: 2 raw → 1 processed)
  ('winery',      'Winery',      2, 'timber', 'processor', 300, 10,
   'berries',     '2',   'wine',        '1',    true, 0),
  ('smokehouse',  'Smokehouse',  2, 'stone',  'processor', 300, 10,
   'fish',        '2',   'smoked_fish', '1',    true, 0),
  ('cannery',     'Cannery',     2, 'clay',   'processor', 300, 10,
   'vegetables',  '2',   'preserves',   '1',    true, 0)
ON CONFLICT (key) DO UPDATE SET
  name = EXCLUDED.name, tier = EXCLUDED.tier,
  industry_key = EXCLUDED.industry_key, category = EXCLUDED.category,
  build_cost = EXCLUDED.build_cost, worker_cost = EXCLUDED.worker_cost,
  input_resource_key = EXCLUDED.input_resource_key,
  input_rate = EXCLUDED.input_rate,
  output_resource_key = EXCLUDED.output_resource_key,
  output_rate = EXCLUDED.output_rate,
  is_active = EXCLUDED.is_active;

-- ── 4. choose_industry seeds new inventory rows for new players ──
CREATE OR REPLACE FUNCTION public.choose_industry(p_display_name text, p_industry_key text)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_profile record;
  v_chunks_owned integer;
  v_row integer;
BEGIN
  IF p_industry_key NOT IN ('timber', 'stone', 'iron', 'clay') THEN
    RAISE EXCEPTION 'Invalid industry. Choose timber, stone, iron, or clay.';
  END IF;
  IF length(trim(p_display_name)) < 2 THEN
    RAISE EXCEPTION 'Display name must be at least 2 characters.';
  END IF;

  INSERT INTO public.player_profiles (
    id, display_name, industry_key, money, worker_capacity, workers_used, chunks_owned
  ) VALUES (
    v_uid, trim(p_display_name), p_industry_key, 500, 5, 0, 0
  )
  ON CONFLICT (id) DO UPDATE SET
    display_name = trim(EXCLUDED.display_name),
    industry_key = EXCLUDED.industry_key,
    updated_at = now();

  -- Seed inventory rows for every known resource (zero quantity).
  INSERT INTO public.inventories (player_id, resource_key, quantity) VALUES
    (v_uid, 'timber', 0),      (v_uid, 'lumber', 0),
    (v_uid, 'stone', 0),       (v_uid, 'brick', 0),
    (v_uid, 'iron', 0),        (v_uid, 'iron_ingot', 0),
    (v_uid, 'tools', 0),
    (v_uid, 'grain', 0),       (v_uid, 'flour', 0),
    (v_uid, 'clay', 0),        (v_uid, 'pottery', 0),
    (v_uid, 'tiles', 0),
    (v_uid, 'bread', 0),       (v_uid, 'furniture', 0),
    (v_uid, 'statuary', 0),
    (v_uid, 'berries', 0),     (v_uid, 'wine', 0),
    (v_uid, 'fish', 0),        (v_uid, 'smoked_fish', 0),
    (v_uid, 'vegetables', 0),  (v_uid, 'preserves', 0)
  ON CONFLICT (player_id, resource_key) DO NOTHING;

  -- Allocate first chunk on a fresh reserved row.
  SELECT chunks_owned INTO v_chunks_owned
  FROM public.player_profiles WHERE id = v_uid;

  IF v_chunks_owned = 0 THEN
    v_row := public.next_starter_row();
    UPDATE public.player_profiles SET reserved_row = v_row WHERE id = v_uid;
    PERFORM public.allocate_district_chunk(v_uid, 0, v_row);
  END IF;

  SELECT * INTO v_profile FROM public.player_profiles WHERE id = v_uid;

  RETURN json_build_object(
    'id', v_profile.id,
    'display_name', v_profile.display_name,
    'industry_key', v_profile.industry_key,
    'money', v_profile.money,
    'worker_capacity', v_profile.worker_capacity,
    'workers_used', v_profile.workers_used,
    'chunks_owned', v_profile.chunks_owned,
    'home_x', v_profile.home_x,
    'home_y', v_profile.home_y,
    'reserved_row', v_profile.reserved_row
  );
END;
$function$;

-- ── 5. Backfill inventories for existing players ──
INSERT INTO public.inventories (player_id, resource_key, quantity)
SELECT pp.id, r.key, 0
FROM public.player_profiles pp
CROSS JOIN (VALUES
  ('iron_ingot'), ('tools'), ('tiles'),
  ('wine'), ('smoked_fish'), ('preserves')
) AS r(key)
ON CONFLICT (player_id, resource_key) DO NOTHING;
