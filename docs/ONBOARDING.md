# Onboarding

How to get the City Builder running locally and contribute changes.

## What this is

A multiplayer city builder. Static frontend (no build step) deployed via GitHub Pages, backed by Supabase (Postgres + Auth + RPC + Realtime). Every push to `main` deploys to production in ~40 seconds.

For game mechanics, read `GAME_DESIGN.md` at the repo root. For file layout and module dependencies, read `city-builder-mvp/STRUCTURE.md`.

## Prerequisites

- Git
- A web browser (mobile Safari/Chrome works)
- A static file server (any of: `python3 -m http.server`, `npx http-server`, VSCode Live Server, etc.)
- A Supabase project (free tier is fine)

That's it. **No Node, no bundler, no build step.** The frontend uses native ES modules.

## First-time setup

### 1. Clone and serve

```bash
git clone https://github.com/atlas-asittley/atlas-asittley.github.io.git citybuilder
cd citybuilder/city-builder-mvp
python3 -m http.server 8000
```

Open `http://localhost:8000`. You'll see a blank login screen until Supabase is wired up.

### 2. Create a Supabase project

- Go to https://supabase.com → New project.
- Pick a region close to you. Free tier is fine for development.
- After provisioning, go to **Project Settings → API** and copy:
  - `Project URL`
  - `anon public` key (NOT the service-role key)

### 3. Wire the client to Supabase

Edit `city-builder-mvp/js/config.js` (only file with credentials in it; do not commit your changes):

```javascript
var SUPABASE_URL = 'https://[your-project-ref].supabase.co';
var SUPABASE_ANON_KEY = 'sb_publishable_...';
```

The anon key is safe to expose; RLS policies enforce all access control. The service-role key must NEVER end up in client code.

### 4. Run the baseline schema

Open Supabase Dashboard → SQL Editor → New query. Paste the contents of:

```
city-builder-mvp/baseline_schema.sql
```

Run it. That's the entire schema — tables, indexes, RLS policies, all functions, triggers, the full catalog of resources / building types / traders / housing tier configs / NPC trade partners. About 2,000 lines, runs in a few seconds.

> **Why one big file?** Earlier the schema lived in 16 layered migration files where `place_building` was redefined 8 times across them. That created real maintenance debt and silent bugs (e.g. an `upgrade_secs` typo introduced during a rewrite). We collapsed everything into one canonical baseline generated from the live DB. The historical migration files are kept under `city-builder-mvp/migrations-archive/` for reference and as a fallback if the baseline ever fails.

> **Mobile note:** Supabase's SQL editor on mobile occasionally truncates large pastes. If you see "function not found" errors after running the baseline, paste the affected function's definition again as a standalone query. The patches under `city-builder-mvp/migration_patches/` are small standalone copies of the most-frequently-truncated functions for exactly this case.

### 5. Apply any post-baseline migrations

When new features ship, additional migration files will land at `city-builder-mvp/*.sql` alongside the baseline. Run them in chronological order on top of the baseline. (As of this writing there are none — the baseline is current.)

### 6. Sign in and start playing

Go back to the local server tab. Sign up with email/password. Pick an industry (timber, stone, grain, or clay). You'll be allocated a 15×15 starting district at the origin, with ~18 randomly-scattered resource tiles of your industry.

## Day-to-day development

- **Edit, save, refresh.** The frontend has no build step. ES modules load directly from disk.
- **Commit and push to `main`** for changes to go live. GitHub Pages serves with `Cache-Control: max-age=600` so users may need a hard-refresh after CSS/JS changes.
- **SQL changes** are migrations: write a new `*.sql` file under `city-builder-mvp/`, run it on Supabase. **Never** edit a previously-shipped migration file in place.
- **Don't bypass server authority.** All inventory mutations, placements, and demolitions go through RPCs. The client only displays state.

## Direct database access (advanced)

For debugging and one-off queries, save your Supabase Session-pooler URL to `~/.citybuilder_db_url` (chmod 600). Then use `psql` or `psycopg2` directly — see `~/.claude/projects/-home-atlas-citybuilder/memory/reference_database_access.md` for the patterns.

The Session pooler URL is found in Supabase Dashboard → Settings → Database → Connection string → Session pooler. Direct connections (`db.[ref].supabase.co`) are IPv6-only on free tier and frequently fail.

## Tests

A pytest suite covers the database RPCs and RLS policies. Run with:

```bash
./tests/run.sh
```

Each test runs inside a transaction savepoint and rolls back, so the live database stays untouched. See `tests/README.md` for the philosophy and how to add tests after a bugfix.

## Where to find more

- `GAME_DESIGN.md` — canonical mechanics reference (target state)
- `city-builder-mvp/STRUCTURE.md` — file layout, module deps, deployment
- `city-builder-mvp/graphics/ART_DIRECTION.md` — visual style for any new sprites
- `tests/README.md` — what's tested, how to run, how to add tests
- `archive/` — historical runbooks and shipped initiative plans, kept for context
