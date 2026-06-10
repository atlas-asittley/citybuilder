-- ─────────────────────────────────────────────────────────────────────
-- Double the starting money for new players (2026-05-10).
--
-- Atlas: "double the starting money that players start with."
--
-- Was: $1000 (bumped from $500 on 2026-05-06).
-- Now: $2000.
--
-- Existing players are NOT retroactively credited. Only the
-- player_profiles INSERT default and the matching starting_grant
-- cash_transactions ledger row change. Two literals; rest of
-- choose_industry is unchanged from the live definition.
-- ─────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.choose_industry(p_display_name text, p_industry_key text, p_district_name text DEFAULT NULL::text, p_city_name text DEFAULT NULL::text)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_profile public.player_profiles;
  v_existing_profile public.player_profiles;
  v_city_id uuid;
  v_city_name text;
  v_row integer;
  v_district text;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'auth required'; END IF;
  IF p_industry_key NOT IN ('timber','stone','iron','clay') THEN
    RAISE EXCEPTION 'Invalid industry. Choose timber, stone, iron, or clay.';
  END IF;
  IF length(trim(p_display_name)) < 2 THEN
    RAISE EXCEPTION 'Display name must be at least 2 characters.';
  END IF;

  SELECT city_id INTO v_city_id FROM public.player_profiles WHERE id = v_uid;
  IF v_city_id IS NULL THEN
    SELECT id INTO v_city_id FROM public.cities ORDER BY created_at LIMIT 1;
    IF v_city_id IS NULL THEN
      v_city_name := COALESCE(NULLIF(trim(p_city_name), ''), 'New City');
      INSERT INTO public.cities (name, created_by)
      VALUES (v_city_name, v_uid)
      RETURNING id INTO v_city_id;
    END IF;
  END IF;

  v_district := COALESCE(NULLIF(trim(p_district_name), ''), trim(p_display_name));

  SELECT * INTO v_existing_profile FROM public.player_profiles WHERE id = v_uid;

  INSERT INTO public.player_profiles (
    id, display_name, industry_key, money, worker_capacity, workers_used,
    chunks_owned, city_id, district_name
  ) VALUES (
    v_uid, trim(p_display_name), p_industry_key, 2000, 5, 0, 0,
    v_city_id, v_district
  )
  ON CONFLICT (id) DO UPDATE SET
    display_name = trim(EXCLUDED.display_name),
    industry_key = EXCLUDED.industry_key,
    city_id = COALESCE(public.player_profiles.city_id, EXCLUDED.city_id),
    district_name = EXCLUDED.district_name
  RETURNING * INTO v_profile;

  IF v_existing_profile.id IS NULL THEN
    INSERT INTO public.cash_transactions (player_id, source, amount, context)
    VALUES (v_uid, 'starting_grant', 2000,
            jsonb_build_object('industry', p_industry_key));
  END IF;

  INSERT INTO public.inventories (player_id, resource_key, quantity) VALUES
    (v_uid, 'timber', 0),      (v_uid, 'lumber', 0),
    (v_uid, 'stone', 0),       (v_uid, 'brick', 0),
    (v_uid, 'clay', 0),        (v_uid, 'pottery', 0),
    (v_uid, 'iron', 0),        (v_uid, 'iron_ingot', 0),
    (v_uid, 'grain', 0),       (v_uid, 'flour', 0)
  ON CONFLICT (player_id, resource_key) DO NOTHING;

  IF v_existing_profile.id IS NULL THEN
    SELECT public.next_starter_row() INTO v_row;
    UPDATE public.player_profiles SET reserved_row = v_row WHERE id = v_uid;
    PERFORM public.allocate_district_chunk(v_uid, 0, v_row);
  END IF;

  RETURN json_build_object(
    'id', v_profile.id,
    'display_name', v_profile.display_name,
    'industry_key', v_profile.industry_key,
    'money', v_profile.money,
    'worker_capacity', v_profile.worker_capacity,
    'workers_used', v_profile.workers_used,
    'chunks_owned', v_profile.chunks_owned,
    'city_id', v_profile.city_id,
    'district_name', v_profile.district_name
  );
END;
$function$;


-- Changelog entry — visible bump for new players.
INSERT INTO public.changelog_entries (slug, title, body)
VALUES (
  '2026-05-10-double-starting-money',
  'Starting money doubled to $2,000',
  E'New players now start with $2,000 instead of $1,000. Easier ramp into the early roads + first food extractor without budget anxiety.\n\nExisting players are not retroactively credited.'
)
ON CONFLICT (slug) DO NOTHING;
