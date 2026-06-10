-- ─────────────────────────────────────────────────────────────────────
-- Player-facing changelog (2026-05-09).
--
-- Atlas: "we need a window that pops up once for each player when
-- there have been changes to the game. tells them what the new
-- features are."
--
-- Design:
--   - changelog_entries: rows authored by hand each time we ship a
--     feature worth surfacing. (slug, title, body, published_at)
--   - player_profiles.last_changelog_seen_at: timestamp watermark.
--     get_unseen_changelog_entries() returns every entry newer than
--     this; mark_changelog_seen() bumps it to now() so the modal
--     stops appearing.
--   - Body is plain text (\n separates paragraphs). Keep entries
--     short — this is a "what's new" surface, not release notes.
-- ─────────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS public.changelog_entries (
  id           uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  slug         text        UNIQUE NOT NULL,
  title        text        NOT NULL,
  body         text        NOT NULL,
  published_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_changelog_entries_published_at
  ON public.changelog_entries (published_at DESC);

-- Lock down the table — reads go through the SECURITY DEFINER RPC.
-- Authoring is direct SQL via migrations (no client write path).
ALTER TABLE public.changelog_entries ENABLE ROW LEVEL SECURITY;

-- Player watermark.
ALTER TABLE public.player_profiles
  ADD COLUMN IF NOT EXISTS last_changelog_seen_at timestamptz;

-- ─────────────────────────────────────────────────────────────────────
-- get_unseen_changelog_entries: returns entries newer than the
-- player's watermark, newest first. NULL watermark = "never seen
-- anything"; only return the most recent one in that case so a
-- brand-new player doesn't get a wall of historical context.
--
-- (A returning player will see everything since their last visit.)
-- ─────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.get_unseen_changelog_entries()
RETURNS TABLE(
  id uuid,
  slug text,
  title text,
  body text,
  published_at timestamptz
)
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_seen timestamptz;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'auth required'; END IF;

  SELECT last_changelog_seen_at INTO v_seen
  FROM public.player_profiles
  WHERE player_profiles.id = v_uid;

  IF v_seen IS NULL THEN
    -- First-time: only the most recent entry, so the player isn't
    -- buried in stale changelog they didn't sign up for.
    RETURN QUERY
      SELECT ce.id, ce.slug, ce.title, ce.body, ce.published_at
      FROM public.changelog_entries ce
      ORDER BY ce.published_at DESC
      LIMIT 1;
  ELSE
    RETURN QUERY
      SELECT ce.id, ce.slug, ce.title, ce.body, ce.published_at
      FROM public.changelog_entries ce
      WHERE ce.published_at > v_seen
      ORDER BY ce.published_at DESC;
  END IF;
END;
$$;

-- list_changelog_entries: full history, for the "What's new" button
-- in Settings (lets a player re-read past entries on demand).
CREATE OR REPLACE FUNCTION public.list_changelog_entries(p_limit integer DEFAULT 30)
RETURNS TABLE(
  id uuid,
  slug text,
  title text,
  body text,
  published_at timestamptz
)
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_uid uuid := auth.uid();
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'auth required'; END IF;
  RETURN QUERY
    SELECT ce.id, ce.slug, ce.title, ce.body, ce.published_at
    FROM public.changelog_entries ce
    ORDER BY ce.published_at DESC
    LIMIT GREATEST(1, LEAST(COALESCE(p_limit, 30), 100));
END;
$$;

-- mark_changelog_seen: bumps the player's watermark to now(). Idempotent.
CREATE OR REPLACE FUNCTION public.mark_changelog_seen()
RETURNS timestamptz
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_now timestamptz := now();
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'auth required'; END IF;
  UPDATE public.player_profiles
  SET last_changelog_seen_at = v_now
  WHERE id = v_uid;
  RETURN v_now;
END;
$$;

-- ─────────────────────────────────────────────────────────────────────
-- Seed entry: covers the work shipped today (2026-05-09).
-- Use a stable slug so re-running the migration doesn't duplicate.
-- ─────────────────────────────────────────────────────────────────────
INSERT INTO public.changelog_entries (slug, title, body)
VALUES (
  '2026-05-09-trade-redesign',
  'Trade Partners — redesigned',
  E'The Trade → Partners tab is now a single scrolling list of trader cards instead of one tab per partner. Each card shows what that trader buys, sells, and how often they visit, and you can collapse a card you''re not focused on.\n\nNew: reservation prices. On City → Resources, set "Sell at $X+" or "Buy at $X−" alongside any auto-trade rule. The auto-trade only fires when a partner''s offer beats your floor (or stays under your ceiling). Leave it blank to accept any price like before.\n\nA "Your price gates" banner at the top of Partners shows — for each resource you''ve gated — which trader currently meets your terms (and at what price), so you can see at a glance whether anyone wants what you''re selling.\n\nMore trade partners will appear as you build and upgrade transport hubs. The locked-partner list is gone — you''ll discover them when they arrive.'
)
ON CONFLICT (slug) DO NOTHING;

INSERT INTO public.changelog_entries (slug, title, body)
VALUES (
  '2026-05-09-treasury-chart-fix',
  'Treasury chart — full data restored',
  E'The Treasury chart was missing data for heavy traders. The client used to download every cash_transactions row and bucket them in JS, but the server caps responses at 1000 rows by default — so once your ledger crossed that, the chart silently dropped older transactions and the daily-net + cumulative-balance lines understated reality.\n\nAggregation now runs server-side. The chart shows the full 7 days regardless of how busy your treasury is, and cross-midnight upkeep events still split proportionally across the days they touch.'
)
ON CONFLICT (slug) DO NOTHING;

INSERT INTO public.changelog_entries (slug, title, body)
VALUES (
  '2026-05-09-per-house-pantry',
  'Houses now have pantries — no more cascade devolves',
  E'Houses no longer all devolve at the same instant when a resource runs out. Each house now has its own per-resource pantry that buffers ~30 minutes of consumption. When city stock empties, the pantries drain at each house''s individual rate — devolves now trickle out one at a time over the next half hour instead of cascading.\n\nConcretely: if your furniture supply hits zero, you have ~30 minutes to react before any house actually devolves, and devolves spread out instead of all happening together. Same model applies to food and every lifestyle good (pottery / bread / furniture / statuary).\n\nExisting houses were seeded with full pantries on rollout, so nothing devolves immediately.'
)
ON CONFLICT (slug) DO NOTHING;

INSERT INTO public.changelog_entries (slug, title, body)
VALUES (
  '2026-05-11-auto-upgrade-toggle',
  'Houses get a per-house auto-upgrade toggle',
  E'Tap a house in the inspector to find a new "Auto-upgrade" toggle. When ON, the server bumps the house''s tier the moment all the conditions are met — no more tapping Upgrade to confirm each one. When OFF, you keep the manual button you''re used to.\n\nNew houses you place from this point on default to auto-upgrade ON. Your existing houses default to OFF so nothing changes for them unless you flip the switch.'
)
ON CONFLICT (slug) DO NOTHING;

INSERT INTO public.changelog_entries (slug, title, body)
VALUES (
  '2026-05-11-server-side-ticks',
  'Your city now ticks even when you''re offline',
  E'The game world used to advance only when someone was looking at it — a player offline for 8 hours came back to ONE huge catch-up tick that compressed 8 hours of production, consumption, and trading into a single processing step. The phase order in that compressed tick caused weird side-effects, like schools running out of inputs even though imports would have arrived in time during real-time play.\n\nNow a server-scheduled job ticks every player''s city once per minute, online or offline. Your trader imports actually arrive on schedule. Your tax revenue accrues continuously. Your devolves (if any) reflect what would have happened minute-by-minute, not what 8 hours of squashed-together math produces.\n\nNothing about the in-game cadence changes when you''re playing. The change is invisible during active play — it''s the offline experience that''s now honest.'
)
ON CONFLICT (slug) DO NOTHING;

INSERT INTO public.changelog_entries (slug, title, body)
VALUES (
  '2026-05-10-devolve-reason',
  'Houses now tell you why they downgraded',
  E'Tap a house that recently devolved, and the inspector shows the specific reason — "ran out of bread," "lost school coverage," "tile desirability dropped below threshold," etc.\n\nUntil a house downgrades, this section is hidden. Once one does, it stays visible until the next devolve overwrites it. Same vocabulary the inspector already uses for upgrade blockers, so the prose reads consistently.'
)
ON CONFLICT (slug) DO NOTHING;

INSERT INTO public.changelog_entries (slug, title, body)
VALUES (
  '2026-05-10-procedural-traders',
  'Trade partners are now procedurally generated',
  E'The fixed roster of named hub partners (Sky Caravans, Coastal Merchants, Inland Caravans, etc.) is gone. Every time anyone in the city builds or expands a transport hub — airport, seaport, train depot, or truck depot — a new procedurally-generated trade partner shows up.\n\nEach new partner picks a random name from a pool, picks 3-6 random resources to trade, and rolls its own prices and volumes. Partners stay forever once created. Build more hubs, get more partners.\n\nThe starter Neighboring City trader is unchanged. Existing players had procedural partners retroactively generated to replace the old named roster, so no one lost trade routes.'
)
ON CONFLICT (slug) DO NOTHING;

INSERT INTO public.changelog_entries (slug, title, body)
VALUES (
  '2026-05-10-hub-trader-volume',
  'Hub trade partners: 100× more volume',
  E'Trade partners unlocked through transport hubs (airport / seaport / train / truck) now buy and sell roughly 100× more per visit and per day. Building a hub is now a real volume play instead of an anticlimactic unlock.\n\nThe starter trader (Neighboring City) is unchanged. Prices are unchanged — the bump is purely on quantity. Your reservation-price gates and reserve targets still control when and what you trade.'
)
ON CONFLICT (slug) DO NOTHING;

INSERT INTO public.changelog_entries (slug, title, body)
VALUES (
  '2026-05-10-double-starting-money',
  'Starting money doubled to $2,000',
  E'New players now start with $2,000 instead of $1,000. Easier ramp into the early roads + first food extractor without budget anxiety.\n\nExisting players are not retroactively credited.'
)
ON CONFLICT (slug) DO NOTHING;

INSERT INTO public.changelog_entries (slug, title, body)
VALUES (
  '2026-05-10-inspector-scroll',
  'Scroll the map with the inspector open',
  E'You can now scroll, zoom, and pan the map while the inspector panel is open at the bottom. Previously the inspector''s invisible overlay was catching every touch in the viewport, freezing the map.\n\nTrade-off: tapping the area above the inspector no longer closes it (those taps go to the map now). Use the X in the inspector header, or tap another building to switch focus.'
)
ON CONFLICT (slug) DO NOTHING;

INSERT INTO public.changelog_entries (slug, title, body)
VALUES (
  '2026-05-10-aoe-highlight',
  'Tap a service / police / booster to see its coverage area',
  E'Tap a Well, School, Temple, Bathhouse, police building, park, or booster (foresters_office / mine_office / etc.) and the area it covers is now highlighted on the map with a per-kind colored tint.\n\nSame shape as the existing pollution heatmap, but scoped to the building you just tapped — makes it obvious which houses are within school range, which extractors a booster reaches, exactly where a police station''s coverage stops, etc.'
)
ON CONFLICT (slug) DO NOTHING;

INSERT INTO public.changelog_entries (slug, title, body)
VALUES (
  '2026-05-10-animations-toggle',
  'Settings: turn off animations on slow devices',
  E'Settings now has an Animations toggle. Switch it off if your browser or phone is struggling with the animated buildings, walkers, or UI transitions — everything turns static and the rendering load drops significantly.\n\nUseful for slower devices, browsers that get glitchy under load, or anyone who just wants a calmer visual. Setting persists across sessions.'
)
ON CONFLICT (slug) DO NOTHING;

INSERT INTO public.changelog_entries (slug, title, body)
VALUES (
  '2026-05-10-upgrade-button-fix',
  'Upgrade buttons: real errors + no more stale buttons',
  E'Two related fixes: (1) When you click an action button (Upgrade, Demolish, Expand, Trade, etc.) and the server rejects it, you now get a popup explaining why — previously these errors disappeared silently and the button just looked broken. Jill reported this on a Townhouse → Villa upgrade where conditions had slipped server-side but the button was still visible.\n\n(2) The server now tells the client when a house''s upgrade eligibility is revoked (e.g., a school stopped operating, food ran out). Previously the client never found out, so the Upgrade button would stick around as stale UI even after the upgrade had been server-side blocked. Now any eligibility transition keeps the client in sync.'
)
ON CONFLICT (slug) DO NOTHING;

INSERT INTO public.changelog_entries (slug, title, body)
VALUES (
  '2026-05-09-trader-reset-clock',
  'Trader-cap reset countdown in topbar',
  E'A new 🔄 pill in the topbar shows when trader daily caps reset, so you can plan your buys and sells around the boundary instead of guessing.\n\nDaily caps refresh at UTC midnight — that''s when each trader''s per-resource buy and sell quotas reset to zero. The countdown shows hours/minutes left in the current day.'
)
ON CONFLICT (slug) DO NOTHING;

INSERT INTO public.changelog_entries (slug, title, body)
VALUES (
  '2026-05-09-map-tile-cap-fix',
  'Map fix — full parcels render again',
  E'Some players were seeing only part of their parcel render — and on a multi-player world, parts of other players'' districts were also getting silently dropped from the map. Same 1000-row response cap that bit the Treasury chart earlier today. The shared world crossed it when Max joined.\n\nThe map fetch now paginates in 1000-row chunks, so it can pull arbitrarily many tiles regardless of the server cap. Every parcel renders fully again.'
)
ON CONFLICT (slug) DO NOTHING;
