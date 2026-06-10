-- ── Numeric precision fix for food drain (2026-05-07) ──
-- The proportional food-drain phase does:
--   UPDATE inventories SET quantity = quantity * v_factor
-- where v_factor = 1.0 - (v_drain / v_avail). PostgreSQL `numeric` is
-- unbounded precision and multiplication preserves the SUM of operand
-- scales, so each tick adds ~20 digits to the running quantity. After
-- a few hundred ticks (a half-day of normal play) values balloon to
-- thousands of digits — Jill's bread row was at 16383 digits, the
-- absolute numeric max, before this fix.
--
-- Fix: ROUND the result to 6 decimal places after the multiplication.
-- 6 decimals gives 0.000001 = a millionth of a unit of precision, which
-- is fractions of a second of drain at any tier — well below display
-- granularity and below any rate we'll ever ship. The same fix is
-- applied at the bottom to existing inflated rows so they recover
-- without a player-visible change in apparent quantity.
--
-- Lifestyle drain uses direct subtraction (quantity - v_needed) so it
-- doesn't accumulate digits and doesn't need rounding. Same with the
-- per-resource trader transfers. The food drain's proportional
-- multiply was the only multiplicative inventory update in the system.

CREATE OR REPLACE FUNCTION public._pp_drain_housing_food(p_uid uuid)
 RETURNS numeric
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  v_now timestamptz := now();
  v_elapsed numeric;
  v_minutes numeric;
  v_rate numeric := 0;
  v_needed numeric := 0;
  v_avail numeric := 0;
  v_drain numeric := 0;
  v_factor numeric := 1;
  v_drained numeric := 0;
  v_demand record;
  v_demand_needed numeric;
  v_demand_avail numeric;
BEGIN
  SELECT EXTRACT(EPOCH FROM (v_now - last_food_tick_at)) INTO v_elapsed
  FROM public.player_profiles WHERE id = p_uid;
  IF v_elapsed IS NULL OR v_elapsed < 0 THEN v_elapsed := 0; END IF;
  v_minutes := v_elapsed / 60.0;

  -- ── Food drain ──
  SELECT COALESCE(SUM(htc.food_per_minute), 0) INTO v_rate
  FROM public.buildings b
  JOIN public.building_types bt ON bt.key = b.building_type_key
  JOIN public.housing_tier_config htc ON htc.tier = b.housing_tier
  WHERE b.player_id = p_uid AND b.status = 'active' AND bt.category = 'housing'
    AND htc.food_per_minute > 0;

  v_needed := v_minutes * v_rate;
  IF v_needed > 0 THEN
    SELECT COALESCE(SUM(i.quantity), 0) INTO v_avail
    FROM public.inventories i
    JOIN public.resources r ON r.key = i.resource_key
    WHERE i.player_id = p_uid AND r.is_food;
    IF v_avail > 0 THEN
      v_drain := LEAST(v_needed, v_avail);
      v_factor := 1.0 - (v_drain / v_avail);
      -- ROUND to 6 decimals after every multiply — the bug was that
      -- numeric is unbounded precision and successive multiplications
      -- accumulated thousands of digits per row.
      UPDATE public.inventories i
      SET quantity = ROUND(i.quantity * v_factor, 6)
      FROM public.resources r
      WHERE i.resource_key = r.key AND r.is_food
        AND i.player_id = p_uid;
      v_drained := v_drain;
    END IF;
  END IF;

  -- ── Lifestyle goods drain (direct subtraction — no precision issue) ──
  FOR v_demand IN
    SELECT hld.resource_key, SUM(hld.qty_per_minute) AS total_rate
    FROM public.buildings b
    JOIN public.building_types bt ON bt.key = b.building_type_key
    JOIN public.housing_lifestyle_demands hld ON hld.tier = b.housing_tier
    WHERE b.player_id = p_uid AND b.status = 'active' AND bt.category = 'housing'
    GROUP BY hld.resource_key
  LOOP
    v_demand_needed := v_minutes * v_demand.total_rate;
    IF v_demand_needed <= 0 THEN CONTINUE; END IF;
    SELECT COALESCE(quantity, 0) INTO v_demand_avail
    FROM public.inventories
    WHERE player_id = p_uid AND resource_key = v_demand.resource_key;
    IF v_demand_avail IS NULL OR v_demand_avail <= 0 THEN CONTINUE; END IF;
    UPDATE public.inventories
      SET quantity = GREATEST(0, ROUND(quantity - v_demand_needed, 6)),
          updated_at = now()
      WHERE player_id = p_uid AND resource_key = v_demand.resource_key;
  END LOOP;

  UPDATE public.player_profiles SET last_food_tick_at = v_now WHERE id = p_uid;
  RETURN v_drained;
END;
$function$;

-- ── Clean up existing inflated rows ──
-- Round every inventory row to 6 decimals so the precision-runaway rows
-- get back to a sane width. A row that was 12.589909431...(16383 more
-- digits) becomes 12.589909 — same player-visible value, just stored
-- with sane precision.
UPDATE public.inventories
   SET quantity = ROUND(quantity, 6),
       updated_at = now()
 WHERE length(quantity::text) > 20;
