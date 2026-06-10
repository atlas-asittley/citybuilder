-- Phase C2: Advanced cross-recipe T4 buildings.
--
-- Each industry gets a top-tier processor that consumes its own T3
-- output PLUS another industry's cross-good (from Phase C). This forms
-- a round-robin trade dependency:
--
--   timber (Cabinetmaker)         needs lime     (from stone)
--   stone  (Architect)            needs glass    (from clay)
--   clay   (Mosaic Workshop)      needs nails    (from iron)
--   iron   (Engineer's Workshop)  needs charcoal (from timber)
--
-- Cycle: timber→stone→clay→iron→timber. Each industry consumes the
-- previous industry's cross-good and produces one for the next.
--
-- Uses the multi-input processor logic already shipped in Phase C —
-- no process_production change needed. Each row just sets both
-- input_resource_key and input_resource_key_2.
--
-- Outputs are non-food luxury industrial goods (cabinets, monuments,
-- mosaics, machinery). Tradeable trade staples; future high-tier
-- housing could require them as prereqs.
--
-- Apply: psql "$DB_URL" -f cross_recipe_t4.sql

-- ── 0. Widen tier constraint to include tier 4 ──
-- The legacy CHECK only allowed tier ∈ {1,2,3}. Lift to {1,2,3,4} so
-- these new top-tier processors fit.
ALTER TABLE public.building_types
  DROP CONSTRAINT IF EXISTS building_types_tier_check;
ALTER TABLE public.building_types
  ADD CONSTRAINT building_types_tier_check
  CHECK (tier = ANY (ARRAY[1, 2, 3, 4]));

-- ── 1. New T4 luxury industrial resources ──
INSERT INTO public.resources (key, name, kind, industry_key, is_active, is_food) VALUES
  ('cabinets',  'Cabinets',  'processed', 'timber', true, false),
  ('monuments', 'Monuments', 'processed', 'stone',  true, false),
  ('mosaics',   'Mosaics',   'processed', 'clay',   true, false),
  ('machinery', 'Machinery', 'processed', 'iron',   true, false)
ON CONFLICT (key) DO UPDATE SET
  name = EXCLUDED.name, kind = EXCLUDED.kind,
  industry_key = EXCLUDED.industry_key,
  is_active = EXCLUDED.is_active, is_food = EXCLUDED.is_food;

-- ── 2. T4 cross-recipe building_types ──
-- Cost/rates: $700 build, 10 workers, 0.5 + 0.5 inputs → 0.25 output.
-- Same I/O ratio as T3 but stepping up cost as the recipe is more
-- demanding (needs the cross-good too).
INSERT INTO public.building_types
  (key, name, tier, industry_key, category, build_cost, worker_cost,
   input_resource_key, input_rate, input_resource_key_2, input_rate_2,
   output_resource_key, output_rate, is_active, workers_provided)
VALUES
  ('cabinetmaker',     'Cabinetmaker',       4, 'timber', 'processor', 700, 10,
   'furniture', '0.5', 'lime',     '0.5', 'cabinets',  '0.25', true, 0),
  ('architect',        'Architect',          4, 'stone',  'processor', 700, 10,
   'statuary',  '0.5', 'glass',    '0.5', 'monuments', '0.25', true, 0),
  ('mosaic_workshop',  'Mosaic Workshop',    4, 'clay',   'processor', 700, 10,
   'tiles',     '0.5', 'nails',    '0.5', 'mosaics',   '0.25', true, 0),
  ('engineer_workshop','Engineer''s Workshop', 4, 'iron',   'processor', 700, 10,
   'tools',     '0.5', 'charcoal', '0.5', 'machinery', '0.25', true, 0)
ON CONFLICT (key) DO UPDATE SET
  name = EXCLUDED.name, tier = EXCLUDED.tier,
  industry_key = EXCLUDED.industry_key, category = EXCLUDED.category,
  build_cost = EXCLUDED.build_cost, worker_cost = EXCLUDED.worker_cost,
  input_resource_key = EXCLUDED.input_resource_key,
  input_rate = EXCLUDED.input_rate,
  input_resource_key_2 = EXCLUDED.input_resource_key_2,
  input_rate_2 = EXCLUDED.input_rate_2,
  output_resource_key = EXCLUDED.output_resource_key,
  output_rate = EXCLUDED.output_rate,
  is_active = EXCLUDED.is_active;

-- ── 3. Backfill inventory rows for existing players ──
INSERT INTO public.inventories (player_id, resource_key, quantity)
SELECT pp.id, r.key, 0
FROM public.player_profiles pp
CROSS JOIN (VALUES ('cabinets'), ('monuments'), ('mosaics'), ('machinery')) AS r(key)
ON CONFLICT (player_id, resource_key) DO NOTHING;

-- ── 4. choose_industry seed list updated ──
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
    (v_uid, 'vegetables', 0),  (v_uid, 'preserves', 0),
    (v_uid, 'spirits', 0),     (v_uid, 'caviar', 0),
    (v_uid, 'spices', 0),      (v_uid, 'ale', 0),
    (v_uid, 'charcoal', 0),    (v_uid, 'lime', 0),
    (v_uid, 'glass', 0),       (v_uid, 'nails', 0),
    (v_uid, 'cabinets', 0),    (v_uid, 'monuments', 0),
    (v_uid, 'mosaics', 0),     (v_uid, 'machinery', 0)
  ON CONFLICT (player_id, resource_key) DO NOTHING;

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
