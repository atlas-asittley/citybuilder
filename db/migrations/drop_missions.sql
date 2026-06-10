-- ─────────────────────────────────────────────────────────────────────
-- Remove missions from the game.
--
-- Atlas's read: the Transport Network (airports / seaports / train
-- depots / truck depot) replaces the role missions used to play —
-- they're a richer, persistent way to add new trading partners and
-- give players reasons to expand. Missions were a one-shot timed
-- ask that didn't compose well with the rest of the economy and
-- added a third concept on top of NPC trade + P2P trade.
--
-- This migration drops:
--   - tables: trader_missions, trader_mission_donations
--   - functions: donate_to_mission, expire_old_missions,
--                get_active_missions, roll_trader_missions
--   - column:   traders.mission_cooldown_minutes
--
-- The reputation system is left in place: it's not user-visible
-- (no JS reads it) and removing it would require also touching
-- get_trade_partner_view. With missions gone its values just
-- freeze at whatever they are. Cleanup is a follow-up if/when it
-- becomes worth the work.
-- ─────────────────────────────────────────────────────────────────────

DROP FUNCTION IF EXISTS public.get_active_missions();
DROP FUNCTION IF EXISTS public.donate_to_mission(uuid, integer);
DROP FUNCTION IF EXISTS public.expire_old_missions();
DROP FUNCTION IF EXISTS public.roll_trader_missions();

DROP TABLE IF EXISTS public.trader_mission_donations;
DROP TABLE IF EXISTS public.trader_missions;

ALTER TABLE public.traders DROP COLUMN IF EXISTS mission_cooldown_minutes;
