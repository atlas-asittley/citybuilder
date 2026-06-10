-- ─────────────────────────────────────────────────────────────────────
-- Bug-report resolution workflow (2026-05-11).
--
-- Atlas: "we should have a process for bug reports. like, after
-- completing, we remove it from there and save it to a file of
-- completed bug reports or something."
--
-- Hybrid: keep the rich server-side snapshot (client_state +
-- server_state JSON), but mark each row resolved once we ship a fix.
-- A markdown file `BUG_REPORTS.md` mirrors the resolution log in
-- human-readable form for browsing without psql.
--
-- Schema:
--   bug_reports.resolved_at        — timestamp the fix shipped
--   bug_reports.resolution_notes   — short prose: what was wrong + fix
--   bug_reports.resolution_commit  — git SHA of the fix commit
--
-- View:
--   open_bug_reports — filtered to WHERE resolved_at IS NULL so the
--   inbox query stays clean.
-- ─────────────────────────────────────────────────────────────────────

ALTER TABLE public.bug_reports
  ADD COLUMN IF NOT EXISTS resolved_at timestamptz,
  ADD COLUMN IF NOT EXISTS resolution_notes text,
  ADD COLUMN IF NOT EXISTS resolution_commit text;

CREATE OR REPLACE VIEW public.open_bug_reports AS
  SELECT id, player_id, display_name, description, client_state, server_state, created_at
  FROM public.bug_reports
  WHERE resolved_at IS NULL
  ORDER BY created_at;

-- Mark Jill's bug resolved (fixed in commits 25aa226 + f9497ac).
UPDATE public.bug_reports
SET resolved_at = '2026-05-11 02:00:00+00'::timestamptz,
    resolution_notes = E'Two interacting issues:\n'
      '1. showToast was a no-op (stripped 2026-05-08, commit 7f58698); '
      'upgrade_house error message disappeared into the void. '
      'Fixed in commit 25aa226 — error toasts converted to alert() per '
      'feedback_bell_log_policy.md.\n'
      '2. State.allBuildings went stale because realtime only watched '
      'INSERT/DELETE not UPDATE; eligibility-cleared houses kept '
      'showing the Upgrade button. Server side also missed a "lost '
      'eligibility" event. Fixed in commits 25aa226 (server event) + '
      'f9497ac (client UPDATE listener).',
    resolution_commit = '25aa226 + f9497ac'
WHERE display_name = 'Jill'
  AND description LIKE '%unable to update from a townhouse to a villa%'
  AND resolved_at IS NULL;
