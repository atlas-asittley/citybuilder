-- ─────────────────────────────────────────────────────────────────────
-- Even self-sufficiency for the staple lifestyle demand (2026-06-10).
--
-- Housing demands a "staple" at tiers 3-8, keyed in the data as 'bread'.
-- Substitutes (2026-05-18) let the non-iron luxury foods stand in
-- (spirits/caviar/spices). That left it uneven: iron self-satisfied with
-- a BASIC good (bread) while timber/stone/clay had to climb to a LUXURY
-- food, and the basic staple foods from the food-spine-symmetry fix
-- (stew/chowder/pottage) couldn't substitute at all. Iron's own luxury
-- (ale) also couldn't substitute.
--
-- Now every industry can satisfy the staple demand with its OWN basic
-- staple AND its own luxury food — fully even, fully parallel:
--     timber: stew    / spirits
--     stone:  chowder / caviar
--     clay:   pottage / spices
--     iron:   bread   / ale
--
-- Adding substitutes only makes the demand EASIER to meet, so no housing
-- can devolve from this change (some players may newly be able to
-- upgrade). The refill + upgrade/devolve gates already handle substitutes
-- generically (see lifestyle_substitutes.sql). Idempotent.
-- ─────────────────────────────────────────────────────────────────────

INSERT INTO public.lifestyle_substitutes (primary_key, substitute_key) VALUES
  ('bread', 'stew'),     -- timber basic staple
  ('bread', 'chowder'),  -- stone basic staple
  ('bread', 'pottage'),  -- clay basic staple
  ('bread', 'ale')       -- iron luxury (parity with spirits/caviar/spices)
ON CONFLICT DO NOTHING;
