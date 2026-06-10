-- ─────────────────────────────────────────────────────────────────────
-- Feedback prompts (2026-05-21)
--
-- Atlas wants a way to ask specific players targeted questions when
-- they open the game. Use case: after shipping a batch of bug fixes,
-- prompt the reporter to confirm things look right.
--
-- Flow:
--   1. Atlas (or any future routine) inserts a row in feedback_prompts
--      targeting a player_id with a prompt_text and a topic key.
--   2. Next time that player opens the game, the FE calls
--      get_pending_feedback_prompt() — returns the oldest undismissed
--      unresponded prompt for the caller, or NULL.
--   3. The FE renders a small modal; player types a reply or skips.
--      Reply → submit_feedback_response(p_id, p_response).
--      Skip  → dismiss_feedback_prompt(p_id).
--   4. Atlas reads responses via direct SELECT.
--
-- One prompt at a time per player; multiple pending prompts are queued
-- oldest-first.
-- ─────────────────────────────────────────────────────────────────────


CREATE TABLE IF NOT EXISTS public.feedback_prompts (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  target_player_id uuid NOT NULL REFERENCES public.player_profiles(id) ON DELETE CASCADE,
  topic text NOT NULL,
  prompt_text text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  dismissed_at timestamptz,
  response_text text,
  response_at timestamptz
);

CREATE INDEX IF NOT EXISTS feedback_prompts_pending_idx
  ON public.feedback_prompts (target_player_id, created_at)
  WHERE dismissed_at IS NULL AND response_text IS NULL;

ALTER TABLE public.feedback_prompts ENABLE ROW LEVEL SECURITY;

-- Players can SELECT their own prompts (the RPC uses SECURITY DEFINER
-- but having a policy lets future direct-table reads work too).
DROP POLICY IF EXISTS feedback_prompts_own_select ON public.feedback_prompts;
CREATE POLICY feedback_prompts_own_select ON public.feedback_prompts
  FOR SELECT USING (target_player_id = auth.uid());

-- INSERT/UPDATE/DELETE go through the SECURITY DEFINER RPCs only.
-- No anon role grants — Atlas writes prompts via the direct DB
-- connection, not through the API.


-- Returns the oldest pending (undismissed, unresponded) prompt for
-- the auth'd player, or NULL if there isn't one.
CREATE OR REPLACE FUNCTION public.get_pending_feedback_prompt()
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_row record;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'auth required'; END IF;
  SELECT id, topic, prompt_text, created_at INTO v_row
  FROM public.feedback_prompts
  WHERE target_player_id = v_uid
    AND dismissed_at IS NULL
    AND response_text IS NULL
  ORDER BY created_at ASC
  LIMIT 1;
  IF NOT FOUND THEN RETURN NULL; END IF;
  RETURN json_build_object(
    'id', v_row.id,
    'topic', v_row.topic,
    'prompt_text', v_row.prompt_text,
    'created_at', v_row.created_at
  );
END;
$function$;


-- Records a free-text reply. Only the targeted player can answer their
-- own prompt; cross-player writes are rejected.
CREATE OR REPLACE FUNCTION public.submit_feedback_response(p_id uuid, p_response text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
DECLARE
  v_uid uuid := auth.uid();
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'auth required'; END IF;
  IF p_response IS NULL OR length(trim(p_response)) = 0 THEN
    RAISE EXCEPTION 'Response cannot be empty';
  END IF;
  UPDATE public.feedback_prompts
  SET response_text = p_response, response_at = now()
  WHERE id = p_id
    AND target_player_id = v_uid
    AND response_text IS NULL
    AND dismissed_at IS NULL;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Prompt not found, already answered, or not yours';
  END IF;
END;
$function$;


-- "Skip / not now" — marks the prompt as dismissed without a response.
-- Same ownership / single-write semantics as submit.
CREATE OR REPLACE FUNCTION public.dismiss_feedback_prompt(p_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
DECLARE
  v_uid uuid := auth.uid();
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'auth required'; END IF;
  UPDATE public.feedback_prompts
  SET dismissed_at = now()
  WHERE id = p_id
    AND target_player_id = v_uid
    AND response_text IS NULL
    AND dismissed_at IS NULL;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Prompt not found, already handled, or not yours';
  END IF;
END;
$function$;


GRANT EXECUTE ON FUNCTION public.get_pending_feedback_prompt() TO authenticated;
GRANT EXECUTE ON FUNCTION public.submit_feedback_response(uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.dismiss_feedback_prompt(uuid) TO authenticated;
