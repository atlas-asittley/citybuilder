-- ─────────────────────────────────────────────────────────────────────
-- Bread always on the NPC menu, 25% off.
--
-- Atlas: "set it so that all NPC trading partners always sell bread,
-- along with whatever other things they sell. also, the cost of bread
-- should be 25% less."
--
-- (1) Patches _spawn_random_trader so every future procedural partner
--     gets a bread row in addition to its 3-6 random resources. Bread
--     is removed from the random pool so it can't end up duplicated
--     or roll the un-discounted price.
--
-- (2) Backfills: knocks 25% off existing bread sell_prices, and
--     inserts a discounted bread row for every active trader that
--     doesn't already sell bread.
--
-- buy_price (trader pays player) is untouched — "cost" in Atlas's
-- ask is what the player pays to buy bread, i.e. sell_price.
-- ─────────────────────────────────────────────────────────────────────

-- (1) Spawn function: always include bread.
CREATE OR REPLACE FUNCTION public._spawn_random_trader(p_mode text)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_key text;
  v_name text;
  v_capacity int;
  v_interval int;
  v_n_resources int;
  v_resource record;
  v_buy_price int;
  v_sell_price int;
  v_buy_cap int;
  v_sell_cap int;
  v_bread_base int;
BEGIN
  IF p_mode NOT IN ('airport', 'seaport', 'train', 'truck') THEN
    RAISE EXCEPTION 'Invalid transport_mode for procedural trader: %', p_mode;
  END IF;

  v_name := public._pick_trader_name();
  v_key := 'proc_' || substr(replace(gen_random_uuid()::text, '-', ''), 1, 12);
  v_capacity := 500 + floor(random() * 4501)::int;
  v_interval := 8 + floor(random() * 23)::int;
  v_n_resources := 3 + floor(random() * 4)::int;

  INSERT INTO public.traders (
    key, name, transport_mode, visit_capacity, visit_interval_minutes,
    is_active, tier, description
  ) VALUES (
    v_key, v_name, p_mode, v_capacity, v_interval, true, 1,
    'Procedural ' || p_mode || ' partner.'
  );

  -- Random 3-6 resources — exclude bread so the always-on row below
  -- isn't duplicated or overwritten by a non-discounted roll.
  FOR v_resource IN
    SELECT key, base_price
    FROM public.resources
    WHERE is_active AND base_price > 0 AND key <> 'bread'
    ORDER BY random()
    LIMIT v_n_resources
  LOOP
    v_buy_price  := GREATEST(1, FLOOR(v_resource.base_price * (0.6 + random() * 0.35))::int);
    v_sell_price := GREATEST(v_buy_price + 1,
                             FLOOR(v_resource.base_price * (1.05 + random() * 0.45))::int);
    v_buy_cap  := 5000 + floor(random() * 45001)::int;
    v_sell_cap := 5000 + floor(random() * 45001)::int;

    INSERT INTO public.trader_prices (
      trader_key, resource_key, buy_price, sell_price,
      daily_buy_cap, daily_sell_cap, is_active
    ) VALUES (
      v_key, v_resource.key, v_buy_price, v_sell_price,
      v_buy_cap, v_sell_cap, true
    );
  END LOOP;

  -- Bread, every time. sell_price discounted 25% off the normal
  -- 1.05-1.5× base range. buy_price uses the same range as everyone
  -- else so player-side bread sales aren't penalised.
  SELECT base_price INTO v_bread_base FROM public.resources WHERE key = 'bread';
  IF v_bread_base IS NOT NULL THEN
    v_buy_price  := GREATEST(1, FLOOR(v_bread_base * (0.6 + random() * 0.35))::int);
    v_sell_price := GREATEST(v_buy_price + 1,
                             FLOOR(v_bread_base * (1.05 + random() * 0.45) * 0.75)::int);
    v_buy_cap  := 5000 + floor(random() * 45001)::int;
    v_sell_cap := 5000 + floor(random() * 45001)::int;

    INSERT INTO public.trader_prices (
      trader_key, resource_key, buy_price, sell_price,
      daily_buy_cap, daily_sell_cap, is_active
    ) VALUES (
      v_key, 'bread', v_buy_price, v_sell_price,
      v_buy_cap, v_sell_cap, true
    );
  END IF;

  RETURN v_key;
END;
$$;


-- (2) Backfill — knock 25% off every existing bread sell_price.
UPDATE public.trader_prices
SET sell_price = GREATEST(1, FLOOR(sell_price * 0.75)::int)
WHERE resource_key = 'bread'
  AND sell_price IS NOT NULL;


-- (3) Backfill — insert a discounted global bread row for every
-- active trader that doesn't already have one. base_price is the
-- live resources.bread.base_price (15 today; the math reruns from
-- the row at apply time so it follows future rebalances).
INSERT INTO public.trader_prices
  (trader_key, resource_key, buy_price, sell_price,
   daily_buy_cap, daily_sell_cap, is_active)
SELECT
  t.key,
  'bread',
  GREATEST(1, FLOOR(r.base_price * 0.7)::int),
  GREATEST(2, FLOOR(r.base_price * 1.3 * 0.75)::int),
  3000, 3000, true
FROM public.traders t
CROSS JOIN (SELECT base_price FROM public.resources WHERE key = 'bread') r
WHERE t.is_active
  AND NOT EXISTS (
    SELECT 1 FROM public.trader_prices tp
    WHERE tp.trader_key = t.key
      AND tp.resource_key = 'bread'
      AND tp.city_id IS NULL
  );


-- (4) Changelog entry.
INSERT INTO public.changelog_entries (slug, title, body)
VALUES (
  '2026-05-15-bread-always-on-npcs',
  'Every NPC partner now sells bread',
  E'Every active NPC trading partner — Neighboring City, every procedural hub partner, and every future one spawned by a new transport hub — now stocks bread. Bread sell prices are also 25% cheaper across the board, so importing it as a stopgap while you build out bakeries is a real option.\n\nThis only affects the price you pay to buy bread from a partner. The price they''ll pay you for surplus bread is unchanged.'
)
ON CONFLICT (slug) DO NOTHING;
