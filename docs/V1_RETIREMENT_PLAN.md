# V1 → V2 Consolidation & Retirement Plan

_Drafted 2026-06-10. Status: **executing — Phase A in progress.** This doc is the
deep-dive plan for folding everything into the v2 (`citybuilder`) repo and
retiring v1._

## Decisions (locked 2026-06-10)
1. **v2 is production.** Real players are on `/citybuilder/`; `/city-builder-mvp/` is safe to take offline (Phase E).
2. **URL:** keep v2 at `/citybuilder/`; redirect `/city-builder-mvp/` → `/citybuilder/`.
3. **History:** simple copy; pre-move history stays in the `atlas-asittley.github.io` repo (pointer in `db/README.md`).
4. **`db/` layout:** `db/migrations/`, `db/migrations-archive/`, `db/baseline_schema.sql`.
5. **Archive:** lightweight historical docs + legacy prototype → `archive/` in v2; the bulky v1 front-end is preserved via a `v1-final` git tag on the hub repo cut just before Phase E (not copied into v2).

---

## 0. The map as it exists today

Two repos, one shared database. **The consolidation touches files and
automation only — it does NOT touch the Supabase database, so the live game
keeps running the entire time.**

### Repo A — `atlas-asittley.github.io` (local: `~/citybuilder`)
This is the **GitHub user Pages site**, served at the domain root. It is **two
things mashed together**:
1. **The landing hub** — `index.html` at the root links out to *all* Atlas
   projects (RPG, Mucklo, dental, etc., each its own repo). **This must
   survive.** Retiring v1 ≠ deleting this repo.
2. **The v1 city-builder + its entire server-side workshop** — everything else
   in the repo:
   - `city-builder-mvp/` (253 files) — the **deployed v1 game** (vanilla JS, served at `/city-builder-mvp/`) **plus** the server-side source of truth:
     - `migration_patches/` — **125 `.sql` files + README** (idempotent diffs, applied by hand via the Supabase SQL editor / raw GitHub URL on mobile)
     - `migrations-archive/` — 67 superseded `.sql` (folded into baseline on rebaseline)
     - `baseline_schema.sql` — 252 KB pg_dump snapshot
     - `js/ css/ assets/ graphics/ index.html STRUCTURE.md` — the v1 front end (superseded by v2 `src/`)
   - `tests/` (65 files) — **pytest suite for the server SQL logic**, savepoint-isolated against the live DB, run via `./tests/run.sh`. Still relevant to v2 (same DB).
   - `sandbox/` (6 files) — Python balance simulators.
   - `scripts/` — **UNTRACKED.** `auto_bug_triage.sh` + `auto_bug_triage_prompt.md` + lockfile. Hourly cron automation (see §1).
   - `logs/` — UNTRACKED. auto_bug_triage run logs.
   - `GAME_DESIGN.md`, `TODO.md`, `BUG_REPORTS.md` — **canonical** design/task/bug docs (the automation writes `BUG_REPORTS.md` + `TODO.md` here).
   - `AUDIT_FINDINGS.md`, `AUDIT_NUMBERS.md`, `archive/`, `city-builder/` (legacy pre-MVP prototype) — historical.
   - Deploy: **classic GitHub Pages from `main` root** (no Actions). Push = live.

### Repo B — `citybuilder` (local: `~/citybuilder-game`)
The **v2 Phaser rewrite** — the destination.
- `src/` (58 files, ~11k LOC), `index.html`, `vite.config.js`, `package.json`.
- `docs/` (10 files), `GAME_DESIGN.md`, `TODO.md`, `BUG_REPORTS.md`, `V2_PARITY_AUDIT.md`, `README.md`.
- Deploy: **GitHub Actions** (`.github/workflows/deploy.yml`) → `npm ci && npm test (vitest) && npm run build` → `actions/deploy-pages`. Served at **`/citybuilder/`** (vite `base` is `/citybuilder/` in prod).
- **No migrations, no pytest, no sandbox, no automation** — those all still live in v1.

### Shared infrastructure (unaffected by the move)
- One Supabase project (`igaulapupbtdcqqjobhs`). Both front ends read/write it.
- `~/.citybuilder_db_url` — pooler connection string. Stays in home dir.
- Claude memory: physically in `~/.claude/projects/-home-atlas-citybuilder/memory/`; the `-home-atlas-citybuilder-game` project **symlinks** to it. Same store either way.

---

## 1. Why v1 is not just a dead deploy (the load-bearing dependency)

`crontab -l` has an **hourly** job:
```
0 * * * * /home/atlas/citybuilder/scripts/auto_bug_triage.sh
```
This script:
- `cd`s into `~/citybuilder` (v1) because "that's where BUG_REPORTS.md + migrations live,"
- `--add-dir`s `~/citybuilder-game` (v2),
- runs `claude --print` to triage + fix open in-game bug reports, ship code/migrations, and append to **`/home/atlas/citybuilder/BUG_REPORTS.md`**.

So v1 is the **active server-side workshop**. Any consolidation MUST repoint this
automation, or hourly bug-triage silently breaks (or keeps writing to a
soon-to-be-deleted location). This is the single most important moving part.

(The other cron line — `0 12 * * *` curl to a Supabase counter — is unrelated; leave it.)

---

## 2. Goals & non-goals

**Goals**
- One repo (`citybuilder`) holds the v2 front end **and** the server-side workshop (migrations, tests, sandbox, automation, canonical docs).
- v1 front end (`/city-builder-mvp/`) taken offline; its dirs removed from the hub repo.
- Hub landing page (`index.html`) preserved and updated.
- Hourly automation, memory pointers, and all path references repointed to v2.
- No database changes; no player-facing downtime.

**Non-goals**
- Not deleting the `atlas-asittley.github.io` repo (it's the hub for every project).
- Not changing DB schema or the migration *workflow* (still hand-applied via Supabase SQL editor).
- Not migrating other projects (RPG, Mucklo, …) — out of scope.

---

## 3. What moves where (inventory + disposition)

| v1 item | Disposition | Target in `citybuilder` |
|---|---|---|
| `city-builder-mvp/migration_patches/` (125 sql + README) | **MOVE** | `db/migrations/` |
| `city-builder-mvp/migrations-archive/` (67 sql) | **MOVE** | `db/migrations-archive/` |
| `city-builder-mvp/baseline_schema.sql` | **MOVE** | `db/baseline_schema.sql` |
| `tests/` (pytest, 65 files) + `pytest.ini` | **MOVE** | `tests/` + `pytest.ini` |
| `sandbox/` (6 files) | **MOVE** | `sandbox/` |
| `scripts/auto_bug_triage.*` (untracked) | **MOVE + version** | `scripts/` (now git-tracked) |
| `logs/` (untracked) | recreate empty; gitignore | `logs/` (gitignored) |
| `TODO.md` | **MOVE (v1 canonical)** — overwrite v2's stale copy | `TODO.md` |
| `BUG_REPORTS.md` | **MOVE (v1 canonical, 59 KB vs v2's 8 KB stale)** | `BUG_REPORTS.md` |
| `GAME_DESIGN.md` | already **identical** in v2 → no move; drop v1 copy | `GAME_DESIGN.md` (unchanged) |
| `docs/*` | already **byte-identical** in v2 (+ v2 has `CIVIC_METRICS_EXPANSION.md`) → no move; drop v1 copies | `docs/` (unchanged) |
| `AUDIT_FINDINGS.md`, `AUDIT_NUMBERS.md` | **MOVE to archive** (historical) | `archive/` |
| `archive/` (runbook, readme) | **MOVE** | `archive/` |
| `city-builder/` (legacy pre-MVP prototype) | **DROP** (recoverable from git history) | — |
| `city-builder-mvp/{js,css,assets,graphics,index.html,STRUCTURE.md}` | **DROP** — superseded by v2 `src/` (keep `STRUCTURE.md` in `archive/` if wanted) | — |

**Net new top-level dirs in `citybuilder`:** `db/`, `tests/`, `sandbox/`, `scripts/`, `archive/` (+ gitignored `logs/`).

**Doc-canonicality note:** today v1 owns the live `TODO.md`/`BUG_REPORTS.md` (automation writes them). After the move, v2's copies become canonical and the automation writes there.

---

## 4. Cross-references to update (the "don't forget" list)

1. **crontab** — repoint hourly job to `~/citybuilder-game/scripts/auto_bug_triage.sh`.
2. **`auto_bug_triage.sh`** — `CITYBUILDER`/`GAME`/`LOCKFILE`/`LOGDIR`/`PROMPT` vars, the `cd`, and `--add-dir`. After consolidation it's a single repo, so drop the two-repo split.
3. **`auto_bug_triage_prompt.md`** — `BUG_REPORTS.md` path (`/home/atlas/citybuilder/...`) and the "Repos:" line describing v1+v2.
4. **Memory files** (7) that hard-code the v1 path — repoint to `~/citybuilder-game/...`:
   - `project_city_builder_orientation.md` (many paths; the "Read these first" + structure section)
   - `feedback_keep_todo_synced.md` (TODO.md path)
   - `feedback_bug_report_workflow.md` (BUG_REPORTS.md)
   - `reference_test_suite.md` (tests path)
   - `project_balance_sandbox.md` (sandbox path)
   - `feedback_session_decisions_2026_05_07.md`
   - `MEMORY.md` (index pointers)
   - (`feedback_v2_is_destination.md` already updated 2026-06-10.)
5. **Migration README / workflow doc** — the "apply via raw GitHub URL" instruction now points at the `citybuilder` repo path.
6. **Hub `index.html`** — see §5.

---

## 5. Deploy & URL changes

- **v2 stays at `/citybuilder/`.** No build change needed (Actions deploy already works).
- **Landing page (`index.html` in hub repo):**
  - Remove the **"City Builder"** (v1, `/city-builder-mvp/`) card.
  - Rename **"City Builder v2"** → **"City Builder"**, drop the `Dev preview` tag → `Game`.
- **Old URL preservation:** players may have `/city-builder-mvp/` bookmarked. Recommended: leave a tiny redirect stub at `city-builder-mvp/index.html`:
  ```html
  <!doctype html><meta http-equiv="refresh" content="0; url=/citybuilder/">
  <link rel="canonical" href="/citybuilder/"><title>Moved</title>
  <a href="/citybuilder/">City Builder has moved →</a>
  ```
  (Alternative: delete the folder entirely and accept a 404. Redirect is friendlier.)

---

## 6. Execution sequence (phased, additive-first, reversible)

Ordering principle: **add everything to v2 and repoint automation BEFORE deleting
anything from v1.** Nothing in v1 is removed until Phase E, by which point v2 has
fully taken over and soaked.

### Phase 0 — Decisions (blocking)
Resolve the open decisions in §9 before touching anything.

### Phase A — Populate v2 (purely additive; zero risk)
1. In `~/citybuilder-game`, create `db/` and copy in `migration_patches/` → `db/migrations/`, `migrations-archive/` → `db/migrations-archive/`, `baseline_schema.sql` → `db/`.
2. Copy `tests/` + `pytest.ini`, `sandbox/`, `scripts/` (now tracked), `AUDIT_*.md` + `archive/` → `archive/`.
3. Overwrite v2's `TODO.md` and `BUG_REPORTS.md` with v1's canonical copies.
4. Add `logs/` to `.gitignore`; add `scripts/.auto_bug_triage.lock` to `.gitignore`.
5. Update `db/migrations/README.md` paths (repo-relative now).
6. Sanity-check vitest config doesn't try to run `.py`; pytest's `pytest.ini` doesn't scan `src/`/`node_modules`.
7. **Verify:** `cd ~/citybuilder-game && ./tests/run.sh` (pytest, needs `~/.citybuilder_db_url`) → all green; `npm test` (vitest) → green; `npm run build` → green.
8. Commit + push v2. (v1 still fully intact — totally reversible.)

### Phase B — Repoint automation (the live-risk step)
1. Edit `~/citybuilder-game/scripts/auto_bug_triage.sh`: single-repo paths, `cd ~/citybuilder-game`, drop `--add-dir`, point `BUG_REPORTS.md` to the v2 path.
2. Edit `auto_bug_triage_prompt.md`: BUG_REPORTS path + repo description.
3. Update **crontab** line to the new script path.
4. **Verify:** run the script manually once (`bash scripts/auto_bug_triage.sh`) — with 0 open bugs it should exit silently; if bugs exist, confirm it writes to v2's `BUG_REPORTS.md` and commits there. Watch one real hourly tick + its log.

### Phase C — Memory + pointers
Update the 7 memory files + `MEMORY.md` (§4.4) to v2 paths. Verify orientation memory reads correctly.

### Phase D — Flip the landing page
1. Edit hub `index.html` (§5): remove v1 card, rename v2 card, add redirect stub at `city-builder-mvp/index.html`.
2. Push hub repo. **Verify:** `/` hub renders, `/citybuilder/` live, `/city-builder-mvp/` redirects.

### Phase E — Retire v1 (after a soak period, e.g. a few days of clean hourly runs from v2)
1. In hub repo, `git rm -r` the city-builder workshop: `city-builder-mvp/` (except the redirect stub), `city-builder/`, `tests/`, `sandbox/`, `docs/`, `GAME_DESIGN.md`, `TODO.md`, `BUG_REPORTS.md`, `AUDIT_*.md`, `archive/`, `pytest.ini`. Keep `index.html`, `.gitignore`, redirect stub.
2. Push. **Verify:** hub still renders; `/citybuilder/` unaffected; nothing else 404s.
3. Optionally delete the local `~/citybuilder` working copy later (the hub repo can be re-cloned; but note the Claude memory dir lives under its project path — see Phase F).

### Phase F — Cleanup
1. Memory symlink: the canonical store is under `-home-atlas-citybuilder`. Since we'll now run Claude from `~/citybuilder-game`, consider making the real dir live under `-home-atlas-citybuilder-game` and symlinking the other way (or leave as-is — it works regardless). **Do not delete the `-home-atlas-citybuilder` project dir while it holds the real memory files.**
2. Confirm `~/.citybuilder_db_url` untouched; `reference_database_access.md` still valid.

---

## 7. Verification checklist (per phase)
- [ ] Phase A: pytest green from v2, vitest green, build green, push clean.
- [ ] Phase B: manual run exits clean; one hourly cron tick logs to v2; a test bug round-trips to v2 `BUG_REPORTS.md`.
- [ ] Phase C: orientation memory paths resolve; no stale v1 path left (`grep -rl '/home/atlas/citybuilder\b' memory/` returns nothing but intended).
- [ ] Phase D: hub `/` OK, `/citybuilder/` OK, `/city-builder-mvp/` → redirect.
- [ ] Phase E: hub renders; no broken project links; v2 unaffected.

## 8. Rollback
- Phases A–C: revert commits / restore crontab line — v1 untouched, instant rollback.
- Phase D: `git revert` the hub index change.
- Phase E: the deletion is a single commit; `git revert` restores the v1 deploy from history. (Keep the soak period so this is rarely needed.)

## 9. Open decisions (need Atlas input)
1. **Is v2 the production game now?** Are Drew/Jill/Max actually playing `/citybuilder/`, and is `/city-builder-mvp/` safe to take offline? — *Gates Phase E.*
2. **URL strategy:** keep v2 at `/citybuilder/` + redirect the old URL (recommended), or repoint v2's vite `base` to `/city-builder-mvp/` to preserve the canonical URL (more disruptive)?
3. **Git history of moved files:** simple copy (recommended — v1 repo history stays accessible), or preserve line history via `git subtree`/`git filter-repo` graft (more work)?
4. **`db/` layout:** `db/migrations/` + `db/migrations-archive/` + `db/baseline_schema.sql` as proposed, or a different convention?
5. **Drop vs archive** the legacy `city-builder/` prototype and v1 front-end `js/css/assets/graphics`? (Proposed: drop — recoverable from git.)
</content>
</invoke>
