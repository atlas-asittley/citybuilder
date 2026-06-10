-- Slow, steady housing upgrades: each tier adds exactly ONE new
-- prerequisite. Previously tier 1 already required road + well + food
-- and the road requirement was implicit baseline; the upgrade ladder
-- "skipped" several tiers without adding anything new (tier 5 had the
-- same prereqs as tier 4). Redistribute to a clean one-per-tier ladder.
--
-- New prereq ladder (cumulative):
--   T0 Shanty       — none (subsistence floor)
--   T1 Mud Hut      — well        (water access)
--   T2 Cottage      — + food
--   T3 Townhouse    — + road
--   T4 Villa        — + school
--   T5 Manor Estate — + temple
--   T6 Mansion      — + luxury food
--   T7 Estate       — + industrial luxury
--   T8 Palace       — + all four industrial luxuries
--
-- Tier 1 also stops consuming food (food_per_minute = 0) to match the
-- "water only" theme; tier 2+ rates are unchanged.
--
-- Apply: psql "$DB_URL" -f housing_progressive_prereqs.sql

UPDATE public.housing_tier_config
SET needs_road = false,
    needs_food = false,
    food_per_minute = 0
WHERE tier = 1;

UPDATE public.housing_tier_config
SET needs_road = false  -- tier 2 still needs well + food, no road yet
WHERE tier = 2;

UPDATE public.housing_tier_config
SET needs_school = false  -- tier 3 adds road; school waits until tier 4
WHERE tier = 3;

UPDATE public.housing_tier_config
SET needs_temple = false  -- tier 4 adds school; temple waits until tier 5
WHERE tier = 4;

-- Tier 5 already has temple = true (it inherited from tier 4 in the old
-- model). Confirm it stays true so it's the gate at tier 5.
UPDATE public.housing_tier_config
SET needs_temple = true
WHERE tier = 5;

-- Tier 6+ untouched: their luxury-food / industrial-luxury gates stay.
