-- get_active_missions: return open missions AND quiet traders with their
-- next-eligible-at timestamps, so the Missions sub-tab can show the player
-- when each trader's next request is coming.

CREATE OR REPLACE FUNCTION public.get_active_missions()
RETURNS json
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_open jsonb := '[]'::jsonb;
  v_quiet jsonb := '[]'::jsonb;
  m record;
  q record;
BEGIN
  -- Lazy housekeeping — same pattern as resolve_trader_visit.
  PERFORM public.expire_old_missions();
  PERFORM public.roll_trader_missions();
  PERFORM public.decay_reputations();

  -- Currently open missions.
  FOR m IN
    SELECT tm.*, t.name AS trader_name, t.specialty_template
    FROM public.trader_missions tm
    JOIN public.traders t ON t.key = tm.trader_key
    WHERE tm.status = 'open'
    ORDER BY tm.created_at DESC
  LOOP
    v_open := v_open || jsonb_build_object(
      'id', m.id,
      'trader_key', m.trader_key,
      'trader_name', m.trader_name,
      'resource_key', m.resource_key,
      'target_qty', m.target_qty,
      'current_qty', m.current_qty,
      'soft_deadline', m.soft_deadline,
      'expires_at', m.expires_at,
      'created_at', m.created_at,
      'your_donated_qty', COALESCE((
        SELECT SUM(qty) FROM public.trader_mission_donations
        WHERE mission_id = m.id AND player_id = v_uid
      ), 0)
    );
  END LOOP;

  -- Quiet traders: active, no open mission right now. Compute when
  -- their next request becomes eligible (last_resolved + cooldown).
  -- roll_trader_missions ran above, so any trader still in this set
  -- is genuinely mid-cooldown.
  FOR q IN
    SELECT t.key, t.name, t.mission_cooldown_minutes,
           (SELECT MAX(resolved_at) FROM public.trader_missions
              WHERE trader_key = t.key AND status <> 'open') AS last_resolved
    FROM public.traders t
    WHERE t.is_active
      AND NOT EXISTS (
        SELECT 1 FROM public.trader_missions
        WHERE trader_key = t.key AND status = 'open'
      )
    ORDER BY t.name
  LOOP
    v_quiet := v_quiet || jsonb_build_object(
      'trader_key', q.key,
      'trader_name', q.name,
      'last_resolved_at', q.last_resolved,
      'next_eligible_at',
        CASE WHEN q.last_resolved IS NULL THEN now()
             ELSE q.last_resolved + (q.mission_cooldown_minutes || ' minutes')::interval
        END,
      'cooldown_minutes', q.mission_cooldown_minutes
    );
  END LOOP;

  RETURN json_build_object('open', v_open, 'quiet', v_quiet);
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_active_missions() TO authenticated;
