-- ── Collapse the three legacy traders into one (2026-05-08) ──
-- Atlas: now that transport hubs unlock specialised trade routes,
-- the three baseline traders (River / Desert / Mountain) are
-- redundant. Replace with a single starter trader that gives a
-- modest income stream until the player can build their first
-- airport / seaport / train depot.
--
-- We keep the river_traders KEY (renaming would force a cascade
-- through trader_visits / trader_prices / trader_relationships /
-- trade_transactions) and just relabel its display name +
-- description. Desert Caravan and Mountain Folk get deactivated —
-- their catalogs and history stay in the DB for archive but they
-- stop visiting and don't appear in the trade panel.

-- 1) Rename river_traders → "Neighboring City"
UPDATE public.traders
   SET name = 'Neighboring City',
       description = 'Modest local trade route. Buys your raw goods and sells what your city can''t produce locally. Reliable income while you save up for an airport, seaport, or train depot — those unlock the bigger trade routes.'
 WHERE key = 'river_traders';

-- 2) Deactivate Desert Caravan and Mountain Folk + their prices.
UPDATE public.traders
   SET is_active = FALSE
 WHERE key IN ('desert_caravan', 'mountain_folk');

UPDATE public.trader_prices
   SET is_active = FALSE
 WHERE trader_key IN ('desert_caravan', 'mountain_folk');

-- 3) Simplify _trader_is_unlocked. Now there's exactly one always-on
-- legacy trader (river_traders) plus the transport-mode-bound ones.
CREATE OR REPLACE FUNCTION public._trader_is_unlocked(p_player_id uuid, p_trader_key text)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
AS $$
DECLARE
  v_mode text;
  v_tier integer;
  v_city_tiers integer;
BEGIN
  -- The collapsed starter trader is always on. The old 'desert_caravan'
  -- and 'mountain_folk' keys are unreachable here because their
  -- traders.is_active is now false and the auto-trader skips inactive
  -- traders, but we keep the explicit FALSE so any stale client cache
  -- still gets a sensible answer.
  IF p_trader_key = 'river_traders' THEN RETURN TRUE; END IF;
  IF p_trader_key IN ('desert_caravan', 'mountain_folk') THEN RETURN FALSE; END IF;

  -- Transport-mode traders.
  SELECT transport_mode, tier INTO v_mode, v_tier
  FROM public.traders WHERE key = p_trader_key;
  IF v_mode IS NULL OR v_tier IS NULL THEN RETURN FALSE; END IF;

  v_city_tiers := public._city_transport_tiers(p_player_id, v_mode);
  IF v_tier > v_city_tiers THEN RETURN FALSE; END IF;

  RETURN public._player_has_transport_access(p_player_id, v_mode);
END;
$$;
