-- ====================================================================
-- City + district naming
-- ====================================================================
-- Adds a `cities` table (one row per shared world; v1 is single-city)
-- and per-player `district_name`. The single shared map stays as-is —
-- every player_profile now belongs to one city, and that city's name
-- plus each player's district_name show in the topbar.
--
-- Backfill: creates one default city ("Lyrandel"), links every existing
-- player to it, defaults each player's district_name to display_name.
-- Players can rename via the Settings modal later.
--
-- choose_industry gains two optional params:
--   p_district_name   — defaults to display_name when null/blank
--   p_city_name       — only used if no city exists yet (first-player flow)

CREATE TABLE IF NOT EXISTS public.cities (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name text NOT NULL CHECK (length(name) BETWEEN 1 AND 40),
  created_at timestamptz NOT NULL DEFAULT now(),
  created_by uuid
);

ALTER TABLE public.player_profiles
  ADD COLUMN IF NOT EXISTS city_id uuid,
  ADD COLUMN IF NOT EXISTS district_name text;

DO $$ BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'player_profiles_city_id_fkey'
  ) THEN
    ALTER TABLE public.player_profiles
      ADD CONSTRAINT player_profiles_city_id_fkey
      FOREIGN KEY (city_id) REFERENCES public.cities(id) ON DELETE SET NULL;
  END IF;
END $$;

INSERT INTO public.cities (name)
SELECT 'Lyrandel'
WHERE NOT EXISTS (SELECT 1 FROM public.cities);

UPDATE public.player_profiles
SET city_id = (SELECT id FROM public.cities ORDER BY created_at LIMIT 1)
WHERE city_id IS NULL;

UPDATE public.player_profiles
SET district_name = display_name
WHERE district_name IS NULL OR length(trim(district_name)) = 0;

-- ── RLS for cities ──
ALTER TABLE public.cities ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "cities_read_all" ON public.cities;
CREATE POLICY "cities_read_all" ON public.cities
  FOR SELECT TO authenticated USING (true);
GRANT SELECT ON public.cities TO authenticated;


-- ── choose_industry: extended signature ──
-- Drop+recreate so we can change the argument list. Re-grant after.

DROP FUNCTION IF EXISTS public.choose_industry(text, text);
DROP FUNCTION IF EXISTS public.choose_industry(text, text, text, text);

CREATE FUNCTION public.choose_industry(
  p_display_name text,
  p_industry_key text,
  p_district_name text DEFAULT NULL,
  p_city_name text DEFAULT NULL
) RETURNS json
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_profile record;
  v_chunks_owned integer;
  v_row integer;
  v_city_id uuid;
  v_city_name text;
  v_district text;
BEGIN
  IF p_industry_key NOT IN ('timber', 'stone', 'iron', 'clay') THEN
    RAISE EXCEPTION 'Invalid industry. Choose timber, stone, iron, or clay.';
  END IF;
  IF length(trim(p_display_name)) < 2 THEN
    RAISE EXCEPTION 'Display name must be at least 2 characters.';
  END IF;

  -- Resolve the city: use existing one, or create from p_city_name if
  -- no city yet (first-player flow). Falls back to a default name.
  SELECT id INTO v_city_id FROM public.cities ORDER BY created_at LIMIT 1;
  IF v_city_id IS NULL THEN
    v_city_name := COALESCE(NULLIF(trim(p_city_name), ''), 'Lyrandel');
    INSERT INTO public.cities (name, created_by)
    VALUES (v_city_name, v_uid)
    RETURNING id INTO v_city_id;
  END IF;

  v_district := COALESCE(NULLIF(trim(p_district_name), ''), trim(p_display_name));

  INSERT INTO public.player_profiles (
    id, display_name, industry_key, money, worker_capacity, workers_used,
    chunks_owned, city_id, district_name
  ) VALUES (
    v_uid, trim(p_display_name), p_industry_key, 500, 5, 0, 0,
    v_city_id, v_district
  )
  ON CONFLICT (id) DO UPDATE SET
    display_name = trim(EXCLUDED.display_name),
    industry_key = EXCLUDED.industry_key,
    city_id = COALESCE(public.player_profiles.city_id, EXCLUDED.city_id),
    district_name = COALESCE(
      NULLIF(public.player_profiles.district_name, ''),
      EXCLUDED.district_name
    ),
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
    'reserved_row', v_profile.reserved_row,
    'city_id', v_profile.city_id,
    'district_name', v_profile.district_name
  );
END;
$$;
GRANT EXECUTE ON FUNCTION public.choose_industry(text, text, text, text) TO authenticated;


-- ── Rename helpers ──

CREATE OR REPLACE FUNCTION public.rename_district(p_name text)
RETURNS text
LANGUAGE plpgsql SECURITY DEFINER
AS $$
DECLARE
  v_clean text;
BEGIN
  v_clean := trim(COALESCE(p_name, ''));
  IF length(v_clean) < 2 OR length(v_clean) > 40 THEN
    RAISE EXCEPTION 'District name must be 2-40 characters.';
  END IF;
  UPDATE public.player_profiles SET district_name = v_clean WHERE id = auth.uid();
  RETURN v_clean;
END;
$$;
GRANT EXECUTE ON FUNCTION public.rename_district(text) TO authenticated;


CREATE OR REPLACE FUNCTION public.rename_city(p_name text)
RETURNS text
LANGUAGE plpgsql SECURITY DEFINER
AS $$
DECLARE
  v_clean text;
  v_city_id uuid;
BEGIN
  v_clean := trim(COALESCE(p_name, ''));
  IF length(v_clean) < 2 OR length(v_clean) > 40 THEN
    RAISE EXCEPTION 'City name must be 2-40 characters.';
  END IF;
  SELECT city_id INTO v_city_id FROM public.player_profiles WHERE id = auth.uid();
  IF v_city_id IS NULL THEN
    RAISE EXCEPTION 'You are not in a city yet.';
  END IF;
  UPDATE public.cities SET name = v_clean WHERE id = v_city_id;
  RETURN v_clean;
END;
$$;
GRANT EXECUTE ON FUNCTION public.rename_city(text) TO authenticated;
