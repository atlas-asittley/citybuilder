-- ============================================================
-- City Builder - Consolidated Housing Ladder (Tiers 0-5)
-- ============================================================
-- Replaces the original 5-tier expansion with a full 6-tier
-- housing progression from humble shanty to grand manor estate.
--
-- Tier 0: Shanty        (2w, no road)  - starter shelter
-- Tier 1: Mud Hut       (6w, road)     - basic dwelling
-- Tier 2: Cottage       (10w, road)    - first proper home
-- Tier 3: Townhouse     (16w, road)    - multi-family dwelling
-- Tier 4: Villa         (24w, road)    - prosperous residence
-- Tier 5: Manor Estate  (34w, road)    - late-game aspiration
--
-- Upgrade times increase per tier; devolve is always faster
-- so players don't lose progress as harshly.
-- ============================================================

INSERT INTO public.housing_tier_config (tier, name, label, workers, needs_road, upgrade_secs, devolve_secs)
VALUES
  (2, 'Cottage',       'C', 10, true, 60,  60),
  (3, 'Townhouse',     'T', 16, true, 120, 60),
  (4, 'Villa',         'V', 24, true, 180, 90),
  (5, 'Manor Estate',  'M', 34, true, 300, 120)
ON CONFLICT (tier) DO UPDATE SET
  name = EXCLUDED.name,
  label = EXCLUDED.label,
  workers = EXCLUDED.workers,
  needs_road = EXCLUDED.needs_road,
  upgrade_secs = EXCLUDED.upgrade_secs,
  devolve_secs = EXCLUDED.devolve_secs;
