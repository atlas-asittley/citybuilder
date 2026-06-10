-- ─────────────────────────────────────────────────────────────────────
-- Bug: choose_industry credited $1000 starting money on the
-- player_profiles row but did NOT insert a matching cash_transactions
-- row, violating the cash ledger invariant
-- (feedback_cash_ledger_invariant.md). Treasury chart's running
-- balance starts $1000 short of reality from day 1, masking the
-- player's real cumulative position.
--
-- Fix:
--   1. Patch choose_industry to insert a starting_grant ledger row at
--      the same moment money is credited.
--   2. Backfill: every existing player_profile without a starting_grant
--      row gets one dated their profile's created_at, amount = 1000.
--      (All current accounts started with $1000 — confirmed against
--      the live INSERT default in choose_industry.)
-- ─────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.choose_industry(
  p_display_name text,
  p_industry_key text,
  p_district_name text DEFAULT NULL,
  p_city_name text DEFAULT NULL
) RETURNS json
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

  -- Resolve / create the city.
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
    v_uid, trim(p_display_name), p_industry_key, 1000, 5, 0, 0,
    v_city_id, v_district
  )
  ON CONFLICT (id) DO UPDATE SET
    display_name = trim(EXCLUDED.display_name),
    industry_key = EXCLUDED.industry_key,
    -- Keep current money on profile updates; starting grant only
    -- applies to fresh profiles handled by the cash_transactions
    -- insert below.
    city_id = COALESCE(public.player_profiles.city_id, EXCLUDED.city_id),
    district_name = EXCLUDED.district_name
  RETURNING * INTO v_profile;

  -- Cash ledger invariant: a fresh profile means a fresh starting
  -- grant. Skip if this player already had one (e.g. they reset and
  -- chose industry again — we don't want to double-credit the
  -- ledger).
  IF v_existing_profile.id IS NULL THEN
    INSERT INTO public.cash_transactions (player_id, source, amount, context)
    VALUES (v_uid, 'starting_grant', 1000,
            jsonb_build_object('industry', p_industry_key));
  END IF;

  -- Seed empty inventory rows so trade UIs don't 404 on missing
  -- (player, resource) pairs. Same set choose_industry has carried
  -- since the early build.
  INSERT INTO public.inventories (player_id, resource_key, quantity) VALUES
    (v_uid, 'timber', 0),      (v_uid, 'lumber', 0),
    (v_uid, 'stone', 0),       (v_uid, 'brick', 0),
    (v_uid, 'clay', 0),        (v_uid, 'pottery', 0),
    (v_uid, 'iron', 0),        (v_uid, 'iron_ingot', 0),
    (v_uid, 'grain', 0),       (v_uid, 'flour', 0)
  ON CONFLICT (player_id, resource_key) DO NOTHING;

  -- Allocate the player's starting district chunk based on their
  -- reserved row.
  IF v_existing_profile.id IS NULL THEN
    SELECT public.next_starter_row() INTO v_row;
    UPDATE public.player_profiles SET reserved_row = v_row WHERE id = v_uid;
    PERFORM public.allocate_district_chunk(v_uid, 0, v_row);
  END IF;

  -- Original choose_industry didn't seed a trader_visits row;
  -- _pp_resolve_trader_visits handles the "no visit yet" case
  -- by treating profile.created_at as the implicit last visit.
  -- A seed here at now() would block tests that backdate a
  -- visit + expect catch-up to fire.

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


-- Backfill existing players who started before this fix.
INSERT INTO public.cash_transactions (player_id, source, amount, context, created_at)
SELECT pp.id, 'starting_grant', 1000,
       jsonb_build_object('industry', pp.industry_key, 'backfill', true),
       pp.created_at
FROM public.player_profiles pp
WHERE NOT EXISTS (
  SELECT 1 FROM public.cash_transactions ct
  WHERE ct.player_id = pp.id AND ct.source = 'starting_grant'
);
