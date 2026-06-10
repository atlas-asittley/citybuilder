# Database — server-side source of truth

The game is server-authoritative: all game logic lives in PostgreSQL (Supabase
project `igaulapupbtdcqqjobhs`). Both the v2 front end (`src/`) and the now-retired
v1 front end read/write this one shared DB.

## Layout
- `migrations/` — the active patch inbox. Idempotent `.sql` diffs applied by hand
  via the Supabase SQL editor (or raw GitHub URL on mobile). Apply in chronological
  order. See `migrations/README.md` for the add-a-patch and rebaseline workflow.
- `migrations-archive/` — patches already folded into the baseline on past rebaselines.
- `baseline_schema.sql` — `pg_dump` snapshot of the schema + catalog seed data.

## Connecting
Connection string lives at `~/.citybuilder_db_url` (Supabase Session pooler, IPv4).
`psycopg2` is installed in system Python. Never print/commit the URL. See
`reference_database_access` in Claude memory for details.

## History note
This `db/` tree was migrated out of the old `atlas-asittley.github.io` repo
(`city-builder-mvp/migration_patches/`, `city-builder-mvp/migrations-archive/`,
`city-builder-mvp/baseline_schema.sql`) on 2026-06-10 during the v1→v2
consolidation. Pre-move file history is preserved in that repo's git log.
</content>
