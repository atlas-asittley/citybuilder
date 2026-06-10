-- Phase B of the strategic-depth expansion: luxury T4 chain extensions.
-- Each industry's *food* chain gets a final processor that turns the
-- T2 food into a high-value luxury good.
--
--   timber: wine        → spirits        (Distillery)
--   stone:  smoked_fish → caviar         (Curing House)
--   clay:   preserves   → spices         (Spicery)
--   iron:   flour       → ale            (Brewery)
--
-- Iron's existing food chain is grain → flour → bread (T1 → T2 → T3),
-- so Brewery competes with Bakery for flour. That's intentional —
-- player chooses between bread (commodity food) and ale (luxury good).
-- The other industries each gain a brand-new T3 food rung that mirrors
-- this shape (food T2 → luxury T3).
--
-- All four luxuries are flagged is_food=true so they auto-satisfy the
-- housing food gate. Their real value comes from being expensive
-- single-source goods that drive trade — and they'll be the natural
-- prereqs for future high-tier housing.
--
-- Costs/rates: $500, 10w, 0.5 input → 0.25 output (mirrors the T3
-- woodcarver / sculptor / bakery pattern but at a higher price point).
--
-- Apply: psql "$DB_URL" -f luxury_chain_extensions.sql

-- ── 1. New luxury resources (all is_food=true) ──
INSERT INTO public.resources (key, name, kind, industry_key, is_active, is_food) VALUES
  ('spirits', 'Spirits', 'processed', 'timber', true, true),
  ('caviar',  'Caviar',  'processed', 'stone',  true, true),
  ('spices',  'Spices',  'processed', 'clay',   true, true),
  ('ale',     'Ale',     'processed', 'iron',   true, true)
ON CONFLICT (key) DO UPDATE SET
  name = EXCLUDED.name, kind = EXCLUDED.kind,
  industry_key = EXCLUDED.industry_key,
  is_active = EXCLUDED.is_active, is_food = EXCLUDED.is_food;

-- ── 2. New T4 luxury processors ──
-- tier=3 since the food side currently runs T1 (extractor) → T2 (mill /
-- winery / smokehouse / cannery) → T3 (these new ones; bakery already at T3).
-- Marking the new ones tier=3 so they sort with bakery on the food chain.
INSERT INTO public.building_types
  (key, name, tier, industry_key, category, build_cost, worker_cost,
   input_resource_key, input_rate, output_resource_key, output_rate,
   is_active, workers_provided)
VALUES
  ('distillery',   'Distillery',   3, 'timber', 'processor', 500, 10,
   'wine',        '0.5', 'spirits', '0.25', true, 0),
  ('curing_house', 'Curing House', 3, 'stone',  'processor', 500, 10,
   'smoked_fish', '0.5', 'caviar',  '0.25', true, 0),
  ('spicery',      'Spicery',      3, 'clay',   'processor', 500, 10,
   'preserves',   '0.5', 'spices',  '0.25', true, 0),
  ('brewery',      'Brewery',      3, 'iron',   'processor', 500, 10,
   'flour',       '0.5', 'ale',     '0.25', true, 0)
ON CONFLICT (key) DO UPDATE SET
  name = EXCLUDED.name, tier = EXCLUDED.tier,
  industry_key = EXCLUDED.industry_key, category = EXCLUDED.category,
  build_cost = EXCLUDED.build_cost, worker_cost = EXCLUDED.worker_cost,
  input_resource_key = EXCLUDED.input_resource_key,
  input_rate = EXCLUDED.input_rate,
  output_resource_key = EXCLUDED.output_resource_key,
  output_rate = EXCLUDED.output_rate,
  is_active = EXCLUDED.is_active;

-- ── 3. Backfill inventory rows for existing players ──
INSERT INTO public.inventories (player_id, resource_key, quantity)
SELECT pp.id, r.key, 0
FROM public.player_profiles pp
CROSS JOIN (VALUES ('spirits'), ('caviar'), ('spices'), ('ale')) AS r(key)
ON CONFLICT (player_id, resource_key) DO NOTHING;

-- ── 4. choose_industry inventory seed list updated ──
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
    (v_uid, 'vegetables', 0),  (v_uid, 'preserves', 0),
    (v_uid, 'spirits', 0),     (v_uid, 'caviar', 0),
    (v_uid, 'spices', 0),      (v_uid, 'ale', 0)
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
