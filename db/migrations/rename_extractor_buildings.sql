-- ── Rename extractor buildings to worker-camp wording ──
-- Old names (Timber Camp, Stone Quarry, Clay Pit, Iron Mine) conflated
-- the EXTRACTION SITE — the quarry / pit / mine the workers travel to —
-- with the BUILDING the player places, which is really the workers'
-- encampment that dispatches them. New names make the building a
-- workers' camp and leave the resource tile to keep its descriptive
-- name (quarry, pit, mine).
--
-- Keys stay the same — 30+ JS references (sprite gating, click
-- handlers, special-case logic) all use the key, only the display
-- `name` is what shows up in the build panel and inspector.

UPDATE public.building_types SET name = 'Logging Camp'        WHERE key = 'timber_camp';
UPDATE public.building_types SET name = 'Stonecutters'' Camp' WHERE key = 'stone_quarry';
UPDATE public.building_types SET name = 'Clay Diggers'' Camp' WHERE key = 'clay_pit';
UPDATE public.building_types SET name = 'Miners'' Camp'       WHERE key = 'iron_mine';
