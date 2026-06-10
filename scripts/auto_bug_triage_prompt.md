You are running as a scheduled job to triage and resolve open in-game bug reports. This is a fresh session with no conversation history; rely on memory + the existing repo state.

## Your task — concise

1. Query `public.open_bug_reports` (use psycopg2 + the connection string at `~/.citybuilder_db_url`). If the view is empty, write a one-line summary "no open bugs" to stdout and exit cleanly.
2. For each open bug:
   - Diagnose using its `server_state` JSON snapshot + live DB queries as needed.
   - Decide if you can confidently ship a fix. Your bar: same threshold I'd apply in an interactive session.
   - **If yes, fix it end-to-end** per the standard workflow:
     - Ship the code or migration change.
     - Commit + push to origin/main (auto-push is the standard).
     - `UPDATE bug_reports SET resolved_at = now(), resolution_notes = ..., resolution_commit = ...` for that row.
     - Append a `## YYYY-MM-DD — Reporter — "verbatim"` entry to `/home/atlas/citybuilder/BUG_REPORTS.md` and commit it.
     - Insert a `feedback_prompts` row for the reporter so they hear about it on their next login. **This is required for every fix — Atlas made it standard 2026-05-21.**
   - **If no — uncertain diagnosis, ambiguous fix, or scope outside the safe-fix list below — leave the row untouched.** Don't mark it resolved. Don't ship a guess.
3. End by writing a single-line summary to stdout: `fixed N, deferred M` so the cron log captures progress.

## What's safe to auto-fix

- Missing pagination (PostgREST 1000-row cap on `.select()` calls — the `fetchTileMap` case)
- FE/server string drift (one side uses `'hold'`, other uses `'keep'`)
- Shape drift in JSONB columns (`{key: qty}` vs `[{resource_key, quantity}]`) — see the [[feedback-p2p-trade-shape]] memory
- Missing CHECK constraint entries when adding a new ledger source
- Race conditions where adding `FOR UPDATE` is clearly the right fix
- Math bugs where the server-side formula is documented and the FE just got the formula wrong
- Cache invalidation issues where adding a short TTL or refreshing on tick is the obvious answer
- Trivial visual / copy fixes the reporter clearly identified

## What requires human review — defer it

- New design choices ("should we have feature X?")
- Balance changes that aren't pure 1:1 corrections (anything that meaningfully changes the curve, threshold, or rate of ANY mechanic — only Atlas signs off on balance)
- Schema migrations that DROP columns/tables, change column types, or might lose data
- Cross-player consequences (a fix that benefits one player at another's expense)
- Anything where the diagnosis is "I think this might be X" rather than "I can prove it's X"
- Bugs whose `server_state` snapshot looks like a transient client-side glitch (browser cache, lost session) — those usually self-resolve

For deferrals, optionally leave a one-liner in `resolution_notes` on the row prefixed with `auto-defer:` so a human reviewer (Atlas) can find it later. **Do NOT set `resolved_at`** on a deferred bug.

## Constraints

- Don't refactor anything you weren't explicitly fixing.
- Don't add new features.
- Don't change balance parameters except as a direct 1:1 fix for the reported bug.
- Don't fix the same bug twice — check the row's `resolved_at` is NULL before working on it.
- Stay under ~$2 of API spend for a single run. If you've made one substantial fix, stop; the next run can pick up the rest.

## Memory + workflow

Auto-load handles your memory. The relevant entries: `feedback-bug-report-workflow`, `feedback-auto-push`, `feedback-cash-ledger-invariant`, `feedback-changelog-publishing`, `feedback-p2p-trade-shape`, `clock-timestamp-for-round-boundaries`, `project-feedback-prompts`. If any of these contradicts what I've said here, the memory wins.

Database: `~/.citybuilder_db_url` (psycopg2-compatible).
Repos: `/home/atlas/citybuilder` (v1 / tests / migrations) and `/home/atlas/citybuilder-game` (v2 / Phaser FE).

Start now. No clarifying questions — Atlas already approved the full-auto mode.
