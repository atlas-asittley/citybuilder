-- ── Bump starting money: 500 → 1000 ──
-- Two places hold the starting cash value for new players:
--   (1) player_profiles.money column default
--   (2) the explicit INSERT in choose_industry()
-- Both are updated here so onboarding lands a fresh player with $1,000.
-- The choose_industry body below is the verbatim current live source
-- (captured via pg_get_functiondef) with only the literal `500` swapped
-- for `1000` in the INSERT VALUES tuple.

ALTER TABLE public.player_profiles ALTER COLUMN money SET DEFAULT 1000;

CREATE OR REPLACE FUNCTION public.choose_industry(p_display_name text, p_industry_key text, p_district_name text DEFAULT NULL::text, p_city_name text DEFAULT NULL::text)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
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
    v_uid, trim(p_display_name), p_industry_key, 1000, 5, 0, 0,
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
$function$;
