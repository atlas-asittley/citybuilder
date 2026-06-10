# Migrations archive

These are the layered migration files that built up the schema incrementally as features shipped: trade phases, housing/labor, roads, four resource chains, M1 districts, M2 distance-based collection, then post-M2 the second wave (multi-tile buildings, food chains, happiness, trade progression, crime + police, progressive unlocks, cash ledger, …).

They were **applied to the live production database** in the order they were authored (for the M0–M2 era, see the original-order list at the bottom of this file; for the post-M2 patches, follow `git log` on each file).

## Why they're archived

Layering N+1 migrations creates real maintenance debt. By the time we reached M2, `place_building` had been redefined **8 times** across these files, `process_production` 5 times, `choose_industry` 5 times. Bug fixes had to find the latest version, layer on top, and remember to keep all the prior checks intact. The `upgrade_secs` typo in M2's `process_production` is a concrete example — the bug was easy to introduce because the function had to be rewritten from scratch instead of patched in place.

We collapsed the lot into a single canonical `city-builder-mvp/baseline_schema.sql` generated from the live DB. New deployments run **only** the baseline. The baseline is periodically rebaselined (see `city-builder-mvp/migration_patches/README.md`) to fold accumulated patches in.

## Are these still useful?

- **Reference.** When debugging or understanding why a piece of schema looks the way it does, the migration history shows the chronology and the rationale ("Run AFTER housing labor migration", etc.).
- **Fallback.** If `baseline_schema.sql` ever fails on a fresh deploy and you need to bisect, you can fall back to running these in their original order.
- **Existing live DB safety.** The live production DB was built from these files. Running `baseline_schema.sql` on it would `DROP SCHEMA public CASCADE` and wipe everything. The archived files document exactly what's already there.

## Original migration order

Run order documented in `docs/ONBOARDING.md` and `city-builder-mvp/STRUCTURE.md` — preserved here for completeness:

1. `mvp_schema.sql`
2. `phase2a_trade_migration.sql`
3. `phase2b_trade_partners_migration.sql`
4. `black_market_migration.sql`
5. `housing_labor_migration.sql`
6. `roads_migration.sql`
7. `housing_evolution_migration.sql`
8. `road_connectivity_rule_migration.sql`
9. `grain_chain_migration.sql`
10. `clay_chain_migration.sql`
11. `tier3_chains_migration.sql`
12. `sculptor_migration.sql`
13. `housing_tiers_expansion.sql`
14. `district_scaffolding_migration.sql` *(M1)*
15. `resource_collection_migration.sql` *(M2)*
16. `worker_cost_tuning_migration.sql`

Plus the post-M2 wave of patches (multi-tile buildings, food chains, housing tiers expansion, trade progression, happiness, immigration walkers, crime + police, progressive unlocks, cash ledger, …) — also archived here, all merged into `baseline_schema.sql`.
