-- ─────────────────────────────────────────────────────────────────────
-- Server-side ticks via pg_cron (2026-05-11).
--
-- Atlas: "let's go with option 2" — replace the client-poll-driven
-- process_production model (which caused phase-order compression on
-- offline catch-up: school checks inputs in step 3, trader imports
-- arrive in step 7, school sees a stale inventory and stalls) with a
-- server-scheduled tick.
--
-- Architecture:
--   1. _pp_for_uid(p_uid uuid)        — internal helper containing
--      the actual tick logic. NOT granted to authenticated/anon
--      roles so it can't be called by a client to tick another
--      player. process_production wraps it for the client RPC.
--   2. process_production()           — public RPC, calls
--      _pp_for_uid(auth.uid()). Unchanged signature; client code
--      keeps working.
--   3. _pp_tick_all_players()         — cron worker. Iterates every
--      post-tutorial player, swallowing per-player errors so one bad
--      tick doesn't halt the others.
--   4. cron.schedule('tick-all-players', '* * * * *', …)
--      Runs every minute. Granularity matches the per-minute rates
--      used by every game formula.
--
-- Client-side polling stays in place — it just becomes a faster
-- redundancy layer that fires between cron ticks for snappier UX
-- on active players.
-- ─────────────────────────────────────────────────────────────────────

CREATE EXTENSION IF NOT EXISTS pg_cron;

-- ── _pp_for_uid: private helper with the full tick body ─────────────
-- Verbatim from the pre-2026-05-11 process_production() body, except
-- the player_id is a parameter instead of auth.uid().
CREATE OR REPLACE FUNCTION public._pp_for_uid(p_uid uuid)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
DECLARE
  v_base constant integer := 5;
  v_tavern_bonus integer;
  v_supply integer;
  v_staffing record;
  v_total_produced numeric := 0;
  v_total_money integer := 0;
  v_total_upkeep integer := 0;
  v_food_drained numeric := 0;
  v_evolution_events json[];
  v_operating_services uuid[];
  v_partial numeric;
  v_population numeric;
  v_crime numeric;
  v_productivity numeric;
  v_workers_used integer;
BEGIN
  IF p_uid IS NULL THEN RETURN NULL; END IF;
  PERFORM 1 FROM public.player_profiles WHERE id = p_uid FOR UPDATE;
  v_tavern_bonus := public._pp_tavern_bonus(p_uid);
  v_population := public._pp_update_population(p_uid);
  v_supply := FLOOR(v_population)::integer + v_tavern_bonus;

  SELECT staffed_ids, workers_needed, unstaffed_count
    INTO v_staffing
    FROM public._pp_staff_buildings(p_uid, v_supply);

  PERFORM public._pp_update_pollution(p_uid);

  v_productivity := public._pp_compute_productivity(p_uid);

  v_partial := public._pp_run_extractors(p_uid, v_staffing.staffed_ids);
  v_total_produced := v_total_produced + v_partial;
  v_partial := public._pp_run_food_extractors(p_uid, v_staffing.staffed_ids);
  v_total_produced := v_total_produced + v_partial;
  PERFORM public._pp_bump_boosters(p_uid, v_staffing.staffed_ids);
  v_partial := public._pp_run_processors(p_uid, v_staffing.staffed_ids);
  v_total_produced := v_total_produced + v_partial;

  PERFORM public._pp_run_agreements(p_uid);

  v_operating_services := public._pp_run_services(p_uid, v_staffing.staffed_ids);
  v_total_money := public._pp_run_tax(p_uid, v_staffing.staffed_ids);
  v_total_upkeep := public._pp_run_upkeep(p_uid, v_staffing.staffed_ids);

  v_food_drained := public._pp_drain_housing_food(p_uid);

  v_crime := public._pp_update_crime(p_uid);
  PERFORM public._pp_update_desirability(p_uid);
  v_evolution_events := public._pp_evolve_housing(p_uid, v_operating_services);

  v_supply := FLOOR(v_population)::integer + v_tavern_bonus;
  v_workers_used := LEAST(v_supply, v_staffing.workers_needed);
  UPDATE public.player_profiles
  SET worker_capacity = v_supply,
      workers_used = v_workers_used
  WHERE id = p_uid;

  PERFORM public._pp_resolve_trader_visits(p_uid);

  RETURN json_build_object(
    'total_produced', v_total_produced,
    'total_money_collected', v_total_money,
    'total_upkeep_paid', v_total_upkeep,
    'food_drained', v_food_drained,
    'evolution_events', array_to_json(v_evolution_events),
    'worker_supply', v_supply,
    'worker_capacity', v_supply,
    'workers_used', v_workers_used,
    'workers_needed', v_staffing.workers_needed,
    'unstaffed_count', v_staffing.unstaffed_count,
    'labor_shortage', (v_staffing.unstaffed_count > 0),
    'population', v_population,
    'happiness', (SELECT happiness FROM public.player_profiles WHERE id = p_uid),
    'crime', v_crime,
    'migration_rate', (SELECT migration_rate FROM public.player_profiles WHERE id = p_uid),
    'productivity', v_productivity,
    'money', (SELECT money FROM public.player_profiles WHERE id = p_uid),
    'inventory', COALESCE(
      (SELECT json_object_agg(resource_key, quantity)
         FROM public.inventories WHERE player_id = p_uid),
      '{}'::json
    )
  );
END;
$function$;

-- Lock it down: only the function owner (postgres) and SECURITY DEFINER
-- wrappers can call this. Authenticated clients can NEVER pass another
-- player's ID and tick them.
REVOKE EXECUTE ON FUNCTION public._pp_for_uid(uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public._pp_for_uid(uuid) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public._pp_for_uid(uuid) FROM anon;


-- ── process_production: keep the public 0-arg RPC ───────────────────
CREATE OR REPLACE FUNCTION public.process_production()
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
DECLARE
  v_uid uuid := auth.uid();
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'auth required'; END IF;
  RETURN public._pp_for_uid(v_uid);
END;
$function$;


-- ── _pp_tick_all_players: cron worker ───────────────────────────────
-- Iterates every post-tutorial player, calls the per-player tick.
-- Swallows per-player errors so one player's bug can't halt the
-- world (the error is RAISE WARNING'd into pg_cron's job_run_details
-- log table so we can find it post-hoc).
CREATE OR REPLACE FUNCTION public._pp_tick_all_players()
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
DECLARE
  v_player record;
  v_count int := 0;
BEGIN
  FOR v_player IN
    SELECT id FROM public.player_profiles
    WHERE tutorial_step >= 4
    ORDER BY id
  LOOP
    BEGIN
      PERFORM public._pp_for_uid(v_player.id);
      v_count := v_count + 1;
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING 'process_production failed for player %: %', v_player.id, SQLERRM;
    END;
  END LOOP;
  RETURN v_count;
END;
$function$;


-- ── Schedule the cron job ───────────────────────────────────────────
-- Unschedule any prior version (idempotent re-run safe) then schedule.
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'tick-all-players') THEN
    PERFORM cron.unschedule('tick-all-players');
  END IF;
END $$;

SELECT cron.schedule(
  'tick-all-players',
  '* * * * *',
  $cron$ SELECT public._pp_tick_all_players(); $cron$
);


-- ── Changelog entry ─────────────────────────────────────────────────
INSERT INTO public.changelog_entries (slug, title, body)
VALUES (
  '2026-05-11-server-side-ticks',
  'Your city now ticks even when you''re offline',
  E'The game world used to advance only when someone was looking at it — a player offline for 8 hours came back to ONE huge catch-up tick that compressed 8 hours of production, consumption, and trading into a single processing step. The phase order in that compressed tick caused weird side-effects, like schools running out of inputs even though imports would have arrived in time during real-time play.\n\nNow a server-scheduled job ticks every player''s city once per minute, online or offline. Your trader imports actually arrive on schedule. Your tax revenue accrues continuously. Your devolves (if any) reflect what would have happened minute-by-minute, not what 8 hours of squashed-together math produces.\n\nNothing about the in-game cadence changes when you''re playing. The change is invisible during active play — it''s the offline experience that''s now honest.'
)
ON CONFLICT (slug) DO NOTHING;
