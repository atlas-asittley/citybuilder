# Run M1 + M2 migrations on Supabase

**Audience:** an AI agent (or human) with access to this project's Supabase database. Read this top-to-bottom and follow it exactly.

## Task

Run two SQL migrations on the Supabase database for the City Builder game, in order, and verify the results.

## Project location

`/home/atlas/citybuilder/city-builder-mvp/`

## Migration files (run in this order)

1. **`district_scaffolding_migration.sql` (M1)** — adds per-tile and per-chunk ownership, plus the spiral allocator that lets new players join without overlapping existing ones.

   ★ **This migration is destructive.** Section 8 deletes all existing rows from `buildings`, `map_tiles`, and `district_chunks`, then reallocates a fresh starting chunk for each existing player. This is intentional — the user is the only player and has confirmed the wipe. **Do NOT edit out section 8 unless explicitly told to.**

2. **`resource_collection_migration.sql` (M2)** — adds `target_x`, `target_y`, `path_length` columns to `buildings`, adds `claimed_by_building_id` to `map_tiles`, adds BFS pathfinding functions, and replaces `place_building` and `process_production` with versions that scale extractor output by path length.

## Steps

1. Connect to the Supabase database. Connection details should already be configured for this project — check `js/config.js` or the user's Supabase dashboard if you need them.
2. Run `district_scaffolding_migration.sql` end to end. Capture any errors verbatim.
3. **Only if M1 succeeded**, run `resource_collection_migration.sql` end to end. Capture any errors.
4. Run the verification queries below and capture the output.

## Verification queries

Run these after both migrations complete and include the results in your report.

```sql
-- 1. Player profiles: should show 1 row per player, chunks_owned >= 1, home_x/home_y populated
SELECT id, display_name, industry_key, money, chunks_owned, home_x, home_y
FROM public.player_profiles;

-- 2. District chunks: one chunk per player, starting at (0,0)
SELECT chunk_x, chunk_y, owner_player_id, allocated_at
FROM public.district_chunks
ORDER BY allocated_at;

-- 3. Tile ownership: 225 tiles per chunk, ~8% with a resource_node_key
SELECT
  owner_player_id,
  COUNT(*) AS total_tiles,
  COUNT(resource_node_key) AS resource_tiles,
  MIN(x) AS min_x, MAX(x) AS max_x,
  MIN(y) AS min_y, MAX(y) AS max_y
FROM public.map_tiles
WHERE owner_player_id IS NOT NULL
GROUP BY owner_player_id;

-- 4. New columns on buildings
SELECT column_name, data_type
FROM information_schema.columns
WHERE table_schema = 'public'
  AND table_name = 'buildings'
  AND column_name IN ('target_x', 'target_y', 'path_length');

-- 5. New columns on map_tiles
SELECT column_name, data_type
FROM information_schema.columns
WHERE table_schema = 'public'
  AND table_name = 'map_tiles'
  AND column_name IN ('owner_player_id', 'claimed_by_building_id');

-- 6. New functions
SELECT proname
FROM pg_proc
WHERE proname IN (
  'next_unowned_chunk_slot',
  'allocate_district_chunk',
  'expand_district',
  'find_nearest_unclaimed_resource',
  'verify_extractor_path',
  'recompute_extractor_paths',
  'handle_building_change'
)
ORDER BY proname;
```

## What to report back

- Did each migration run clean? (yes/no per migration, with full error text if any)
- Verification query results, especially:
  - Number of `player_profiles` rows and the `chunks_owned`, `home_x`, `home_y` values
  - Number of tiles owned per player (should be 225 × number of players)
  - Resource tile count per player (should be roughly 18, give or take from the random 8% seeding — anywhere from ~12 to ~24 is fine)
  - List of new functions confirmed present
- Any warnings emitted during migration (constraint conflicts, RLS issues, slow queries, etc.)

## Do NOT

- Modify the migration files.
- Run any other migrations from the `city-builder-mvp/` directory.
- Skip the verification queries.
- Assume success without checking — report the actual query output.
- Run M2 if M1 failed partway through. In that case, report the failure point and stop, so the user can inspect manually.

## Context

These migrations are part of a planned redesign captured in `/home/atlas/citybuilder/GAME_DESIGN.md`. The companion frontend changes are already merged on `main` and assume the schema is up to date. After both migrations run clean, the user will refresh the game tab and exercise the new behavior:

- Districts are visible on the map; tiles outside the player's district are desaturated and reject placement.
- Extractors place anywhere road-adjacent in the player's district (no longer required to sit on a resource tile).
- A collector walker loops between each extractor and its claimed resource tile.
- The inspector shows each extractor's target, path length, and effective production rate.
- An "+ Expand" button in the topbar buys the next chunk for `$500 × chunks_owned²`.

If you see anything weird in verification (e.g. zero resource tiles, missing columns, missing functions), say so explicitly — don't paper over it.
