-- Trade progression: tables + indexes for missions, donations, and per-player reputation.
-- See docs/TRADE_PROGRESSION.md for the full design.
-- Idempotent: safe to re-run; uses CREATE IF NOT EXISTS / DROP POLICY IF EXISTS.

-- ── 1. trader_relationships ─────────────────────────────
-- Personal reputation per (player, trader). Created on first donation.
CREATE TABLE IF NOT EXISTS public.trader_relationships (
  player_id        uuid NOT NULL REFERENCES public.player_profiles(id) ON DELETE CASCADE,
  trader_key       text NOT NULL REFERENCES public.traders(key) ON DELETE CASCADE,
  reputation       numeric NOT NULL DEFAULT 0,
  last_donation_at timestamptz,
  last_decay_at    timestamptz NOT NULL DEFAULT now(),
  created_at       timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (player_id, trader_key),
  CONSTRAINT trader_relationships_rep_nonneg CHECK (reputation >= 0)
);

CREATE INDEX IF NOT EXISTS idx_trader_relationships_trader
  ON public.trader_relationships (trader_key);

ALTER TABLE public.trader_relationships ENABLE ROW LEVEL SECURITY;

-- Any authenticated player can read all reputations — needed for the
-- city-rep weighted average computation. Writes go through SECURITY
-- DEFINER RPCs only.
DROP POLICY IF EXISTS trader_relationships_select ON public.trader_relationships;
CREATE POLICY trader_relationships_select ON public.trader_relationships
  FOR SELECT
  USING (auth.uid() IS NOT NULL);

-- ── 2. trader_missions ──────────────────────────────────
-- Open + historical mission requests from each trader.
CREATE TABLE IF NOT EXISTS public.trader_missions (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  trader_key    text NOT NULL REFERENCES public.traders(key) ON DELETE CASCADE,
  kind          text NOT NULL DEFAULT 'deliver_resource',
  resource_key  text NOT NULL REFERENCES public.resources(key),
  target_qty    integer NOT NULL,
  current_qty   integer NOT NULL DEFAULT 0,
  soft_deadline timestamptz NOT NULL,
  expires_at    timestamptz NOT NULL,
  status        text NOT NULL DEFAULT 'open',
  created_at    timestamptz NOT NULL DEFAULT now(),
  resolved_at   timestamptz,
  CONSTRAINT trader_missions_status_check
    CHECK (status IN ('open', 'fulfilled', 'expired')),
  CONSTRAINT trader_missions_kind_check
    CHECK (kind IN ('deliver_resource')),
  CONSTRAINT trader_missions_target_pos CHECK (target_qty > 0),
  CONSTRAINT trader_missions_current_nonneg CHECK (current_qty >= 0)
);

CREATE INDEX IF NOT EXISTS idx_trader_missions_status
  ON public.trader_missions (status, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_trader_missions_trader_status
  ON public.trader_missions (trader_key, status, created_at DESC);

-- Only one open mission per trader at a time.
CREATE UNIQUE INDEX IF NOT EXISTS idx_trader_missions_one_open_per_trader
  ON public.trader_missions (trader_key)
  WHERE status = 'open';

ALTER TABLE public.trader_missions ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS trader_missions_select ON public.trader_missions;
CREATE POLICY trader_missions_select ON public.trader_missions
  FOR SELECT
  USING (auth.uid() IS NOT NULL);

-- ── 3. trader_mission_donations ─────────────────────────
-- Per-player donations against a mission.
CREATE TABLE IF NOT EXISTS public.trader_mission_donations (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  mission_id  uuid NOT NULL REFERENCES public.trader_missions(id) ON DELETE CASCADE,
  player_id   uuid NOT NULL REFERENCES public.player_profiles(id) ON DELETE CASCADE,
  qty         integer NOT NULL,
  donated_at  timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT trader_mission_donations_qty_pos CHECK (qty > 0)
);

CREATE INDEX IF NOT EXISTS idx_donations_mission
  ON public.trader_mission_donations (mission_id, donated_at DESC);
CREATE INDEX IF NOT EXISTS idx_donations_player
  ON public.trader_mission_donations (player_id, donated_at DESC);

ALTER TABLE public.trader_mission_donations ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS trader_mission_donations_select ON public.trader_mission_donations;
CREATE POLICY trader_mission_donations_select ON public.trader_mission_donations
  FOR SELECT
  USING (auth.uid() IS NOT NULL);

-- ── 4. Trader-level mission cadence column ──────────────
-- Each trader rolls a new mission this often.
ALTER TABLE public.traders
  ADD COLUMN IF NOT EXISTS mission_cooldown_minutes integer NOT NULL DEFAULT 30;

-- Default base request quantity. Mission generator scales this with city size.
ALTER TABLE public.traders
  ADD COLUMN IF NOT EXISTS base_request_qty integer NOT NULL DEFAULT 25;

-- Soft-deadline window after mission spawn.
ALTER TABLE public.traders
  ADD COLUMN IF NOT EXISTS soft_deadline_minutes integer NOT NULL DEFAULT 60;

-- Specialty template; null on existing rows. New traders carry one.
ALTER TABLE public.traders
  ADD COLUMN IF NOT EXISTS specialty_template text;
