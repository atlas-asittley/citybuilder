#!/usr/bin/env bash
# Hourly cron: notify Atlas on Discord when there are NEW in-game bug reports.
#
# History: replaced the old "full auto" fixer (auto_bug_triage.sh) on 2026-07-14
# at Atlas's request — it now only NOTIFIES, it does not diagnose or fix anything.
#
# Behavior:
#   - Lockfile guards against overlap.
#   - Query public.open_bug_reports. Dedup against a local state file of
#     already-notified bug ids, so each bug pings exactly once (notify-only
#     means bugs stay open until Atlas handles them; without dedup we'd spam
#     the same bug every hour).
#   - If there are NEW bugs, send a Discord DM to Atlas via OpenClaw's gateway.
#     Only mark bugs as notified if delivery actually succeeds (else retry next hour).
#   - No Claude session, no code changes, no auto-push.
#   - Logs to logs/bug_report_notify_<ts>.log only on runs that had new bugs; keeps last 30.

set -euo pipefail

GAME=/home/atlas/citybuilder-game
LOCKFILE=$GAME/scripts/.bug_report_notify.lock
STATEFILE=$GAME/scripts/.notified_bug_ids
LOGDIR=$GAME/logs
TS=$(date -u +%Y%m%dT%H%M%SZ)
LOGFILE=$LOGDIR/bug_report_notify_$TS.log
DISCORD_TARGET="user:684837479525908529"   # Atlas's Discord DM

# Cron has a minimal env — make openclaw + python resolve.
export PATH=/home/atlas/.nvm/versions/node/v22.22.0/bin:/usr/local/bin:/usr/bin:/bin:$PATH
[ -f /home/atlas/.bash_profile ] && source /home/atlas/.bash_profile || true

mkdir -p "$LOGDIR"
touch "$STATEFILE"

exec 9>"$LOCKFILE"
if ! flock -n 9; then
  echo "[$TS] previous run still active, skipping." >&2
  exit 0
fi

python3 - "$STATEFILE" "$DISCORD_TARGET" "$LOGFILE" <<'PY'
import sys, os, json, subprocess, datetime

statefile, target, logfile = sys.argv[1], sys.argv[2], sys.argv[3]

# --- fetch open bugs ---
try:
    import psycopg2
    url = open(os.path.expanduser('~/.citybuilder_db_url')).read().strip()
    cur = psycopg2.connect(url).cursor()
    cur.execute("""
        SELECT id, display_name, description, created_at
        FROM public.open_bug_reports
        ORDER BY created_at ASC
    """)
    rows = cur.fetchall()
except Exception as e:
    sys.stderr.write(f"DB pre-check failed: {e}\n")
    sys.exit(1)

if not rows:
    sys.exit(0)  # inbox empty — silent, no log

# --- dedup against already-notified ids ---
notified = set(l.strip() for l in open(statefile) if l.strip())
new = [r for r in rows if str(r[0]) not in notified]
if not new:
    sys.exit(0)  # all current bugs already announced — silent

# --- build the notification ---
def short(txt, n=140):
    txt = ' '.join((txt or '').split())
    return txt if len(txt) <= n else txt[:n-1] + '…'

n = len(new)
lines = [f"🐛 [city-builder] {n} new bug report{'s' if n != 1 else ''}:", ""]
for bid, name, desc, created in new:
    when = created.strftime('%Y-%m-%d %H:%M UTC') if hasattr(created, 'strftime') else str(created)
    lines.append(f"• \"{short(desc)}\" — {name or 'anon'} ({when})")
    lines.append(f"  id {str(bid)[:8]}")
lines.append("")
lines.append("Auto-fix is off — review in ~/citybuilder-game when you get a chance.")
msg = "\n".join(lines)

# --- deliver via OpenClaw Discord DM ---
instruction = ("Deliver the following notification to Discord verbatim. "
               "Reply with ONLY this text, exactly as written, nothing added:\n\n" + msg)
try:
    out = subprocess.run(
        ["openclaw", "agent", "--agent", "main", "--channel", "discord",
         "--deliver", "--reply-to", target, "--timeout", "200", "--json",
         "-m", instruction],
        capture_output=True, text=True, timeout=240)
    data = json.loads(out.stdout or "{}")
    res = data.get("result", data)
    ok = bool(res.get("deliverySucceeded"))
except Exception as e:
    sys.stderr.write(f"OpenClaw delivery error: {e}\n")
    ok = False

# --- log + update state ---
with open(logfile, "a") as f:
    f.write(f"=== bug_report_notify — {n} new bug(s), delivered={ok} ===\n")
    f.write(msg + "\n")

if ok:
    with open(statefile, "a") as f:
        for r in new:
            f.write(str(r[0]) + "\n")
    print(f"notified {n} new bug(s)")
else:
    sys.stderr.write("delivery failed — not marking notified; will retry next run.\n")
    sys.exit(1)
PY

# Retain the last 30 logs.
ls -1t "$LOGDIR"/bug_report_notify_*.log 2>/dev/null | tail -n +31 | xargs -r rm -f || true
