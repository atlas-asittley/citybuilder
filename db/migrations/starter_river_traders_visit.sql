-- ── Starter River Traders visit ──
-- When a beginner finishes onboarding, river_traders is the always-unlocked
-- "starter" partner. But the cooldown is 10 minutes, anchored on
-- profile.created_at, so even after the player has built the prereqs to
-- unlock the trade panel (1 extractor + 1 food_extractor + tier-1 hut)
-- they may still face an additional 10-minute wait before the first trade.
-- That delay defeats the purpose of having a starter trader.
--
-- This patch makes choose_industry seed a trader_visits row dated
-- 10 minutes in the past, so river_traders reads as "Due!" the moment the
-- trade gate first opens (regardless of how long the prereqs took to build).
-- The seed row has capacity_used=0 / summary='[]' — it's purely a
-- date anchor for the cooldown calculation; it doesn't grant any actual
-- goods. The first real visit creates a normal trader_visits row.
--
-- Backfill the same seed for existing profiles that don't have a
-- river_traders visit yet.
--
-- Body below is the verbatim current live source with one new block
-- added between the chunk-allocation block and the final SELECT/RETURN.

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
  v_river_capacity integer;
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

  -- Starter River Traders visit: seed a trader_visits row dated one full
  -- visit-interval in the past, so river_traders reads as "Due!" from the
  -- moment the player finishes onboarding. Without this, the cooldown is
  -- anchored on profile.created_at and a fast player could finish the
  -- trade-gate prereqs in under 10 minutes and STILL face a wait before
  -- their first trade. Seed only if no visit row exists yet (idempotent
  -- across re-runs of choose_industry).
  IF NOT EXISTS (
    SELECT 1 FROM public.trader_visits
    WHERE player_id = v_uid AND trader_key = 'river_traders'
  ) THEN
    SELECT visit_capacity INTO v_river_capacity
    FROM public.traders WHERE key = 'river_traders';
    IF v_river_capacity IS NOT NULL THEN
      INSERT INTO public.trader_visits
        (trader_key, player_id, capacity_total, capacity_used, summary, visited_at)
      VALUES
        ('river_traders', v_uid, v_river_capacity, 0, '[]'::jsonb,
         now() - ((SELECT visit_interval_minutes FROM public.traders
                    WHERE key = 'river_traders') || ' minutes')::interval);
    END IF;
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

-- Backfill: any existing profile without a river_traders visit gets the
-- same seed as if they'd just onboarded under the new logic.
INSERT INTO public.trader_visits
  (trader_key, player_id, capacity_total, capacity_used, summary, visited_at)
SELECT
  'river_traders',
  pp.id,
  (SELECT visit_capacity FROM public.traders WHERE key = 'river_traders'),
  0,
  '[]'::jsonb,
  now() - ((SELECT visit_interval_minutes FROM public.traders
             WHERE key = 'river_traders') || ' minutes')::interval
FROM public.player_profiles pp
WHERE NOT EXISTS (
  SELECT 1 FROM public.trader_visits tv
  WHERE tv.player_id = pp.id AND tv.trader_key = 'river_traders'
);
