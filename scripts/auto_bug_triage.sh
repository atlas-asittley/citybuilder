#!/usr/bin/env bash
# Hourly cron: process every open in-game bug report end-to-end.
# Atlas turned this on 2026-05-21 after picking the "full auto" mode
# (option 3 of the bug-fix automation menu).
#
# Behavior:
#   - Lockfile guards against overlap (a long-running fix won't start
#     a second instance at the next hour mark).
#   - Cheap pre-check: query open_bug_reports first. If empty, exit
#     silently — no Claude session, no token spend.
#   - If non-empty, hand off to claude --print with the prompt and
#     a wide tool allowlist + bypass mode. The prompt has the full
#     workflow including the "always queue a reporter feedback_prompt"
#     standard.
#   - Logs everything to logs/auto_bug_triage_<timestamp>.log; keeps
#     the last 30 runs (older ones rotate out).

set -euo pipefail

CITYBUILDER=/home/atlas/citybuilder
GAME=/home/atlas/citybuilder-game
LOCKFILE=$CITYBUILDER/scripts/.auto_bug_triage.lock
LOGDIR=$CITYBUILDER/logs
PROMPT=$CITYBUILDER/scripts/auto_bug_triage_prompt.md
TS=$(date -u +%Y%m%dT%H%M%SZ)
LOGFILE=$LOGDIR/auto_bug_triage_$TS.log

# Cron's environment is minimal — make sure PATH + auth are set so
# `claude` resolves and Anthropic auth works. ANTHROPIC_API_KEY should
# already be in the user's profile; we source it from bash_profile if
# present (silent if not).
export PATH=/home/atlas/.nvm/versions/node/v22.22.0/bin:/usr/local/bin:/usr/bin:/bin:$PATH
[ -f /home/atlas/.bash_profile ] && source /home/atlas/.bash_profile || true

mkdir -p "$LOGDIR"

# Lock with exec 9>$LOCKFILE + flock -n 9. If another run is going,
# bail without touching the log so the cron doesn't spam.
exec 9>"$LOCKFILE"
if ! flock -n 9; then
  echo "[$TS] previous run still active, skipping." >&2
  exit 0
fi

# Cheap pre-check: any open bugs at all? If not, exit. This avoids
# spinning up a Claude session 23 hours a day when the inbox is empty.
OPEN_COUNT=$(python3 -c "
import psycopg2, os, sys
url = open(os.path.expanduser('~/.citybuilder_db_url')).read().strip()
conn = psycopg2.connect(url)
cur = conn.cursor()
cur.execute('SELECT COUNT(*) FROM public.open_bug_reports')
print(cur.fetchone()[0])
" 2>/dev/null || echo "ERROR")

if [ "$OPEN_COUNT" = "ERROR" ]; then
  echo "[$TS] DB pre-check failed (no creds or DB down). Skipping." >&2
  exit 1
fi

if [ "$OPEN_COUNT" = "0" ]; then
  # Truly silent — don't even create a log file.
  exit 0
fi

# We have work. Log the run.
{
  echo "=== auto_bug_triage @ $TS — $OPEN_COUNT open bug(s) ==="
  echo

  # claude --print so it exits when done. --permission-mode bypassPermissions
  # so it doesn't hang on prompts. --add-dir for both repos. --max-budget-usd
  # caps cost at $2 per run. --model sonnet (cheaper than opus, sufficient
  # for the workflow). cwd is the v1 repo since that's where BUG_REPORTS.md
  # + migrations live; claude can navigate to citybuilder-game via --add-dir.
  cd "$CITYBUILDER"

  claude --print \
    --permission-mode bypassPermissions \
    --add-dir "$GAME" \
    --max-budget-usd 2 \
    --model claude-sonnet-4-6 \
    --no-session-persistence \
    < "$PROMPT"

  echo
  echo "=== done ==="
} >> "$LOGFILE" 2>&1

# Retain the last 30 logs.
ls -1t "$LOGDIR"/auto_bug_triage_*.log 2>/dev/null | tail -n +31 | xargs -r rm -f
