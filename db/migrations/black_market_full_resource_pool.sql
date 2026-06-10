-- ─────────────────────────────────────────────────────────────────────
-- Black Market expansion + base_price column on resources.
--
-- Design:
--   Every active resource gets a `base_price` integer = the canonical
--   "fair" price for that resource. Black Market sells TO the player at
--   200% of base_price (you pay double); buys FROM the player at 35% of
--   base_price (you take a 65% haircut). Always-on, every resource —
--   the emergency option you reach for when nothing else fits.
--
--   The same base_price will feed the randomized-trader-catalog roller
--   in a follow-up migration. Trader prices will be set as fixed
--   multipliers off base_price (e.g. partner buy = 70%, sell = 130%) so
--   randomness is in coverage not value.
--
-- Tiering rule (informal, used for the seed values below):
--   A. Raw bulk      (timber, stone, clay, iron, grain)        →  5
--   B. Raw food      (vegetables, berries, fish)               →  5
--   C. Basic processed (lumber, brick, flour, charcoal, lime,
--                       iron_ingot, nails, tools, pottery)     → 10
--   D. Cooked food   (bread, preserves, smoked_fish)           → 15
--   E. Lifestyle     (tiles, glass, furniture, statuary, wine,
--                     ale)                                     → 20
--   F. Industrial luxury (cabinets, machinery, monuments,
--                          mosaics)                            → 30
--   G. Luxury food   (caviar, spirits, spices)                 → 35
-- ─────────────────────────────────────────────────────────────────────

ALTER TABLE public.resources
  ADD COLUMN IF NOT EXISTS base_price integer;

UPDATE public.resources SET base_price = CASE
  -- Tier A: raw bulk
  WHEN key IN ('timber','stone','clay','iron','grain') THEN 5
  -- Tier B: raw food
  WHEN key IN ('vegetables','berries','fish') THEN 5
  -- Tier C: basic processed
  WHEN key IN ('lumber','brick','flour','charcoal','lime','iron_ingot','nails','tools','pottery') THEN 10
  -- Tier D: cooked food
  WHEN key IN ('bread','preserves','smoked_fish') THEN 15
  -- Tier E: lifestyle
  WHEN key IN ('tiles','glass','furniture','statuary','wine','ale') THEN 20
  -- Tier F: industrial luxury
  WHEN key IN ('cabinets','machinery','monuments','mosaics') THEN 30
  -- Tier G: luxury food
  WHEN key IN ('caviar','spirits','spices') THEN 35
  ELSE 10
END
WHERE is_active;

-- Lock down: every active resource must have a base_price going forward.
ALTER TABLE public.resources
  ADD CONSTRAINT resources_base_price_positive_when_active
  CHECK (NOT is_active OR (base_price IS NOT NULL AND base_price > 0))
  NOT VALID;
ALTER TABLE public.resources
  VALIDATE CONSTRAINT resources_base_price_positive_when_active;


-- ── black_market_trade: compute prices from base_price ──
-- Old behavior used hardcoded buy_from_player / sell_to_player values
-- plumbed in from a fixed lookup. New behavior: derive from
-- resources.base_price, with a flat 35% sell / 200% buy markup.
CREATE OR REPLACE FUNCTION public.black_market_trade(
  p_resource_key text,
  p_quantity integer,
  p_direction text
) RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_base_price integer;
  v_unit_price integer;
  v_total integer;
  v_available numeric;
  v_player_money integer;
  v_new_money integer;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
  IF p_quantity <= 0 THEN RAISE EXCEPTION 'Quantity must be positive'; END IF;
  IF p_direction NOT IN ('buy','sell') THEN
    RAISE EXCEPTION 'direction must be ''buy'' or ''sell''';
  END IF;

  SELECT base_price INTO v_base_price
  FROM public.resources WHERE key = p_resource_key AND is_active;
  IF v_base_price IS NULL THEN
    RAISE EXCEPTION 'Resource % not available on black market', p_resource_key;
  END IF;

  IF p_direction = 'sell' THEN
    -- Player sells to BM, gets 35% of base.
    v_unit_price := GREATEST(1, FLOOR(v_base_price * 0.35)::integer);
    v_total := v_unit_price * p_quantity;

    SELECT COALESCE(quantity, 0) INTO v_available
    FROM public.inventories WHERE player_id = v_uid AND resource_key = p_resource_key;
    IF v_available IS NULL OR v_available < p_quantity THEN
      RAISE EXCEPTION 'Not enough % (have %, need %)', p_resource_key, COALESCE(v_available, 0), p_quantity;
    END IF;

    UPDATE public.inventories SET quantity = quantity - p_quantity, updated_at = now()
    WHERE player_id = v_uid AND resource_key = p_resource_key;

    UPDATE public.player_profiles SET money = money + v_total WHERE id = v_uid
      RETURNING money INTO v_new_money;

    INSERT INTO public.cash_transactions (player_id, source, amount, context)
    VALUES (v_uid, 'black_market', v_total,
            jsonb_build_object('resource', p_resource_key, 'quantity', p_quantity,
                               'unit_price', v_unit_price, 'direction', 'sell'));
    INSERT INTO public.trade_transactions
      (player_id, trader_key, resource_key, quantity, unit_price, total_price, transaction_type)
    VALUES (v_uid, 'black_market', p_resource_key, p_quantity, v_unit_price, v_total, 'sell');
  ELSE
    -- Player buys from BM at 200% of base.
    v_unit_price := CEIL(v_base_price * 2.0)::integer;
    v_total := v_unit_price * p_quantity;

    SELECT money INTO v_player_money FROM public.player_profiles WHERE id = v_uid;
    IF v_player_money < v_total THEN
      RAISE EXCEPTION 'Not enough money (have $%, need $%)', v_player_money, v_total;
    END IF;

    UPDATE public.player_profiles SET money = money - v_total WHERE id = v_uid
      RETURNING money INTO v_new_money;

    INSERT INTO public.inventories (player_id, resource_key, quantity)
    VALUES (v_uid, p_resource_key, p_quantity)
    ON CONFLICT (player_id, resource_key)
    DO UPDATE SET quantity = inventories.quantity + p_quantity, updated_at = now();

    INSERT INTO public.cash_transactions (player_id, source, amount, context)
    VALUES (v_uid, 'black_market', -v_total,
            jsonb_build_object('resource', p_resource_key, 'quantity', p_quantity,
                               'unit_price', v_unit_price, 'direction', 'buy'));
    INSERT INTO public.trade_transactions
      (player_id, trader_key, resource_key, quantity, unit_price, total_price, transaction_type)
    VALUES (v_uid, 'black_market', p_resource_key, p_quantity, v_unit_price, v_total, 'buy');
  END IF;

  RETURN json_build_object(
    'direction', p_direction, 'resource', p_resource_key,
    'quantity', p_quantity, 'unit_price', v_unit_price,
    'total_price', v_total, 'money', v_new_money,
    'inventory', COALESCE(
      (SELECT json_object_agg(resource_key, quantity) FROM public.inventories WHERE player_id = v_uid),
      '{}'::json));
END;
$function$;
