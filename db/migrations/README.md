# Migration patches

Inbox for new migration patches as features ship. Each `.sql` file in this directory is a small, idempotent diff applied against the live database (typically via the Supabase web SQL editor or — when on mobile — by copying the raw GitHub URL).

After every rebaseline, this directory is emptied: the patches get folded into `db/baseline_schema.sql` (regenerated via `pg_dump` against the live DB) and the individual files move to `db/migrations-archive/`. See the archive README for history.

## Adding a new patch

1. Write the SQL as a standalone, idempotent file (`CREATE OR REPLACE FUNCTION`, `CREATE TABLE IF NOT EXISTS`, `DROP POLICY IF EXISTS` before `CREATE POLICY`, etc.).
2. Apply it to the live DB via the Supabase SQL editor.
3. Commit the file here.
4. Add or update a regression test under `tests/`.

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
