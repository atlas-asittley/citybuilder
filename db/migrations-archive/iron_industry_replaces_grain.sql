-- Replace grain industry with iron. Grain stays as a food (resources.is_food
-- = true), just no longer one of the choosable industries. Iron is a new
-- industry whose primary extractor is iron_mine and whose paired food
-- extractor is the (now flat-rate, food-locked-to-iron) grain_farm.
--
-- The four industries become: timber, stone, iron, clay.
--
-- Why this is safe:
-- - Zero existing players have industry_key = 'grain' (verified before
--   writing this migration).
-- - Atlas (stone) has one grain_farm building. After this migration it
--   becomes a food_extractor (flat-rate grain production, no tile claim);
--   the existing tile claim is released. He keeps the building but can't
--   build new grain_farms (it's locked to industry='iron').
--
-- Apply: psql "$DB_URL" -f iron_industry_replaces_grain.sql

-- ── 1. New iron resource (raw, industry='iron', not a food) ──
INSERT INTO public.resources (key, name, kind, industry_key, is_active, is_food)
VALUES ('iron', 'Iron', 'raw', 'iron', true, false)
ON CONFLICT (key) DO UPDATE SET
  name = EXCLUDED.name, kind = EXCLUDED.kind,
  industry_key = EXCLUDED.industry_key,
  is_active = EXCLUDED.is_active, is_food = EXCLUDED.is_food;

-- ── 2. iron_mine extractor (mirrors timber_camp / stone_quarry) ──
INSERT INTO public.building_types
  (key, name, tier, industry_key, category, build_cost, worker_cost,
   input_resource_key, input_rate, output_resource_key, output_rate,
   is_active, workers_provided)
VALUES
  ('iron_mine', 'Iron Mine', 1, 'iron', 'extractor', 100, 10,
   NULL, '0', 'iron', '1', true, 0)
ON CONFLICT (key) DO UPDATE SET
  name = EXCLUDED.name, tier = EXCLUDED.tier,
  industry_key = EXCLUDED.industry_key, category = EXCLUDED.category,
  build_cost = EXCLUDED.build_cost, worker_cost = EXCLUDED.worker_cost,
  output_resource_key = EXCLUDED.output_resource_key,
  output_rate = EXCLUDED.output_rate,
  is_active = EXCLUDED.is_active;

-- ── 3. grain_farm becomes a food_extractor for the iron industry ──
-- Was: extractor, industry_key='common', tile-based with path_length math
-- Now: food_extractor, industry_key='iron', flat 2 grain/min, no tile
UPDATE public.building_types
SET category = 'food_extractor',
    industry_key = 'iron',
    output_rate = 2
WHERE key = 'grain_farm';

-- Release any existing grain_farm tile claims (food extractors don't
-- claim tiles). Without this, the tile would still show as claimed by
-- the now-flat-rate grain_farm forever.
UPDATE public.map_tiles
SET claimed_by_building_id = NULL
WHERE claimed_by_building_id IN (
  SELECT id FROM public.buildings WHERE building_type_key = 'grain_farm'
);
UPDATE public.buildings
SET target_x = NULL, target_y = NULL, path_length = NULL
WHERE building_type_key = 'grain_farm';

-- ── 4. choose_industry validator: drop 'grain', add 'iron' ──
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
    (v_uid, 'timber', 0),     (v_uid, 'lumber', 0),
    (v_uid, 'stone', 0),      (v_uid, 'brick', 0),
    (v_uid, 'iron', 0),
    (v_uid, 'grain', 0),      (v_uid, 'flour', 0),
    (v_uid, 'clay', 0),       (v_uid, 'pottery', 0),
    (v_uid, 'bread', 0),      (v_uid, 'furniture', 0),
    (v_uid, 'statuary', 0),
    (v_uid, 'berries', 0),    (v_uid, 'fish', 0),
    (v_uid, 'vegetables', 0)
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

-- ── 5. Backfill iron inventory rows for existing players ──
INSERT INTO public.inventories (player_id, resource_key, quantity)
SELECT pp.id, 'iron', 0
FROM public.player_profiles pp
ON CONFLICT (player_id, resource_key) DO NOTHING;
