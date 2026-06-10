-- ─────────────────────────────────────────────────────────────────────
-- Bug reports.
--
-- Players hit a 🐞 button in the info-bar, type a description, submit.
-- The submit_bug_report RPC stores the description plus a server-side
-- snapshot of their state (profile, recent cash_transactions, recent
-- trader_visits, current inventory, current buildings) — so we can
-- forensically explore what the world looked like at the moment they
-- hit the button without making them describe every detail.
--
-- Reads are service-role-only (we look at them via psql); players
-- can INSERT their own. RLS is on.
-- ─────────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS public.bug_reports (
  id            uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  player_id     uuid        NOT NULL REFERENCES public.player_profiles(id) ON DELETE CASCADE,
  display_name  text,
  description   text        NOT NULL,
  client_state  jsonb,
  server_state  jsonb,
  created_at    timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS bug_reports_player_idx ON public.bug_reports (player_id, created_at DESC);
CREATE INDEX IF NOT EXISTS bug_reports_created_idx ON public.bug_reports (created_at DESC);

ALTER TABLE public.bug_reports ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS bug_reports_insert_own ON public.bug_reports;
CREATE POLICY bug_reports_insert_own ON public.bug_reports
  FOR INSERT TO authenticated
  WITH CHECK (player_id = auth.uid());

-- No SELECT policy → only service_role / postgres can read. We pull
-- via psql on the dev side; players can't snoop each other's reports.

CREATE OR REPLACE FUNCTION public.submit_bug_report(
  p_description text,
  p_client_state jsonb DEFAULT '{}'::jsonb
) RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_name text;
  v_server_state jsonb;
  v_id uuid;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
  IF p_description IS NULL OR length(trim(p_description)) = 0 THEN
    RAISE EXCEPTION 'Description is required';
  END IF;
  IF length(p_description) > 5000 THEN
    RAISE EXCEPTION 'Description too long (max 5000 chars)';
  END IF;

  SELECT display_name INTO v_name FROM public.player_profiles WHERE id = v_uid;

  -- Build the server snapshot. The player has just hit a button, so
  -- their data is fresh; we can synchronously grab everything the
  -- forensics view will want.
  v_server_state := jsonb_build_object(
    'snapshot_at', now(),
    'profile', (
      SELECT to_jsonb(p) FROM public.player_profiles p WHERE p.id = v_uid
    ),
    'inventory', (
      SELECT COALESCE(jsonb_object_agg(resource_key, quantity), '{}'::jsonb)
      FROM public.inventories WHERE player_id = v_uid
    ),
    'buildings', (
      SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'id', b.id, 'type', b.building_type_key, 'x', b.x, 'y', b.y,
        'status', b.status, 'is_staffed', b.is_staffed,
        'housing_tier', b.housing_tier, 'expansion_level', b.expansion_level,
        'stored_input', b.stored_input, 'stored_output', b.stored_output,
        'last_processed_at', b.last_processed_at,
        'target_x', b.target_x, 'target_y', b.target_y
      ) ORDER BY b.created_at), '[]'::jsonb)
      FROM public.buildings b WHERE b.player_id = v_uid
    ),
    'cash_recent', (
      SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'at', created_at, 'src', source, 'amt', amount, 'ctx', context,
        'period_start', period_start
      ) ORDER BY created_at DESC), '[]'::jsonb)
      FROM (
        SELECT * FROM public.cash_transactions
        WHERE player_id = v_uid
        ORDER BY created_at DESC LIMIT 50
      ) recent
    ),
    'trader_visits_recent', (
      SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'at', visited_at, 'trader', trader_key,
        'cap_total', capacity_total, 'cap_used', capacity_used,
        'summary', summary
      ) ORDER BY visited_at DESC), '[]'::jsonb)
      FROM (
        SELECT * FROM public.trader_visits
        WHERE player_id = v_uid
        ORDER BY visited_at DESC LIMIT 20
      ) recent
    ),
    'trade_policies', (
      SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'res', resource_key, 'mode', mode, 'reserve', reserve_target
      )), '[]'::jsonb)
      FROM public.trade_policies WHERE player_id = v_uid
    ),
    'agreements', (
      SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'id', id, 'role', CASE WHEN from_player_id = v_uid THEN 'sender' ELSE 'recipient' END,
        'counterparty', CASE WHEN from_player_id = v_uid THEN to_player_id ELSE from_player_id END,
        'give_resources', give_resources, 'receive_resources', receive_resources,
        'give_money', give_money, 'receive_money', receive_money,
        'interval_minutes', interval_minutes, 'status', status,
        'last_fired_at', last_fired_at
      )), '[]'::jsonb)
      FROM public.trade_agreements
      WHERE (from_player_id = v_uid OR to_player_id = v_uid) AND status = 'active'
    )
  );

  INSERT INTO public.bug_reports (player_id, display_name, description, client_state, server_state)
  VALUES (v_uid, v_name, p_description, COALESCE(p_client_state, '{}'::jsonb), v_server_state)
  RETURNING id INTO v_id;

  RETURN v_id;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.submit_bug_report(text, jsonb) TO authenticated;
