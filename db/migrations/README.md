# Migration patches

Inbox for new migration patches as features ship. Each `.sql` file in this directory is a small, idempotent diff applied against the live database (typically via the Supabase web SQL editor or — when on mobile — by copying the raw GitHub URL).

After every rebaseline, this directory is emptied: the patches get folded into `db/baseline_schema.sql` (regenerated via `pg_dump` against the live DB) and the individual files move to `db/migrations-archive/`. See the archive README for history.

## Adding a new patch

1. Write the SQL as a standalone, idempotent file (`CREATE OR REPLACE FUNCTION`, `CREATE TABLE IF NOT EXISTS`, `DROP POLICY IF EXISTS` before `CREATE POLICY`, etc.).
2. If the patch creates a table, follow the new-table checklist below.
3. Apply it to the live DB via the Supabase SQL editor.
4. Commit the file here.
5. Add or update a regression test under `tests/`.

## New-table checklist

Every `CREATE TABLE` in `public` needs RLS and explicit grants — both are
easy to forget and neither fails loudly.

**RLS is mandatory.** Supabase's security advisor emails a weekly
"Action required: security vulnerabilities detected" alert for any table
in `public` without it (rule `rls_disabled_in_public`). `trader_name_pool`
shipped without it and nagged for months. `tests/db/test_rls.py::
test_every_public_table_has_rls_enabled` now fails the suite if a table
misses it.

```sql
ALTER TABLE public.your_table ENABLE ROW LEVEL SECURITY;
```

Then pick the access shape:

- **Server-side only** (catalog/flavour data, reached solely through
  `SECURITY DEFINER` RPCs) — enable RLS, add *no* policies, and revoke
  the client grants. postgres owns the tables and bypasses RLS, so the
  definer path keeps working. See `trader_name_pool`, `changelog_entries`.
  ```sql
  REVOKE ALL ON public.your_table FROM anon, authenticated;
  ```
- **Client-readable** — add a `SELECT` policy only. All writes go through
  RPCs; direct write policies were deliberately dropped in the 2026-05-09
  lockdown, so don't reintroduce them.

**Grants become mandatory on 2026-10-30.** Supabase is dropping the
automatic Data API exposure of new `public` tables. Existing tables keep
their current grants and nothing breaks on that date, but any table
created afterwards is invisible to PostgREST/supabase-js until granted —
a missing grant surfaces as a `42501` error naming the exact fix. For
client-readable tables, state it explicitly rather than relying on the
inherited default:

```sql
GRANT SELECT ON public.your_table TO anon, authenticated;
```

Background: <https://github.com/orgs/supabase/discussions/45329>

## Rebaselining

When the inbox grows uncomfortable (~30+ files) or the schema state is hard to reason about from layered patches alone:

```bash
# 1. Dump current live schema
pg_dump "$(cat ~/.citybuilder_db_url)" --schema-only --schema=public --no-owner > /tmp/schema.sql

# 2. Dump catalog seed data
pg_dump "$(cat ~/.citybuilder_db_url)" --data-only --no-owner --column-inserts \
  -t public.resources -t public.building_types -t public.housing_tier_config \
  -t public.traders -t public.trader_prices -t public.external_trade_partners \
  > /tmp/seed.sql

# 3. Splice into db/baseline_schema.sql with a `DROP SCHEMA IF EXISTS public CASCADE;` preamble.
# 4. Move all db/migrations/*.sql to db/migrations-archive/.
# 5. Run ./tests/run.sh to confirm the test fixtures still match.
# 6. Commit + push.
```

`pg_dump` must match the server's major version. Live runs on PG 17, so install `postgresql-client-17` from the PGDG apt repo.
