-- ─────────────────────────────────────────────────────────────────────
-- Tax-office desirability penalty: drop the -15 cap (2026-05-20).
--
-- Atlas: "shouldn't tax collectors cost extra desirability?" The
-- previous formula was `-LEAST(15, v_tax_count * 3)` — a hard ceiling
-- at five tax offices. Past five, every extra tax office was free.
-- Jill currently has ten; the 6th-10th cost her nothing in
-- desirability, which makes the desirability-vs-tax-revenue trade-off
-- vanish at the point it ought to be biting hardest.
--
-- New formula: `-v_tax_count * 3` (no cap). The per-tile clamp to
-- [0, 100] still bounds the overall metric, so there's no runaway
-- math. The other capped terms (food variety +10, crime -20) stay as
-- they are — those represent inherent city dynamics, not player
-- spam-able decisions.
--
-- Balance impact: only Jill has > 5 tax offices today (others have
-- 0-1). For her: city_base drops 15 (from 45 to 30), so most tiles
-- lose 15 desirability. Existing housing stays put thanks to the
-- 30-point devolve hysteresis, but high-tier upgrades become harder
-- — which is the intended effect.
-- ─────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public._pp_update_desirability(p_uid uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
DECLARE
  v_food_variety integer;
  v_crime numeric;
  v_tax_count integer;
  v_city_base integer;
BEGIN
  -- District-wide terms (apply equally to every tile in this district)
  SELECT COUNT(DISTINCT i.resource_key) INTO v_food_variety
  FROM public.inventories i
  JOIN public.resources r ON r.key = i.resource_key
  WHERE i.player_id = p_uid AND r.is_food AND i.quantity > 0;

  SELECT COALESCE(crime, 0) INTO v_crime
  FROM public.player_profiles WHERE id = p_uid;

  SELECT COUNT(*) INTO v_tax_count
  FROM public.buildings b
  JOIN public.building_types bt ON bt.key = b.building_type_key
  WHERE b.player_id = p_uid AND b.status = 'active' AND bt.category = 'tax';

  -- Tax-office penalty has no cap: each tax office costs 3
  -- desirability, so the trade-off keeps biting as you spam more.
  -- The per-tile clamp to [0, 100] handles bounding.
  v_city_base := 50
    + LEAST(10, v_food_variety * 2)
    - LEAST(20, GREATEST(0, FLOOR((v_crime - 30) / 10)::integer * 2))
    - v_tax_count * 3;

  -- Per-tile: city_base + service coverage − pollution penalty.
  -- Service coverage uses Chebyshev (king's-move) distance to match
  -- the housing upgrade gate.
  UPDATE public.map_tiles mt SET desirability = LEAST(100, GREATEST(0,
    v_city_base
    - LEAST(30, mt.pollution::integer)
    + COALESCE((
        SELECT SUM(CASE bt.key
          WHEN 'well'      THEN 5
          WHEN 'school'    THEN 5
          WHEN 'temple'    THEN 5
          WHEN 'bathhouse' THEN 5
          WHEN 'tavern'    THEN 3
          ELSE 0 END)
        FROM public.buildings b
        JOIN public.building_types bt ON bt.key = b.building_type_key
        WHERE b.player_id = p_uid AND b.status = 'active' AND b.is_staffed
          AND bt.category = 'service'
          AND GREATEST(ABS(b.x - mt.x), ABS(b.y - mt.y)) <=
              CASE bt.key
                WHEN 'well'      THEN 4
                WHEN 'school'    THEN 5
                WHEN 'temple'    THEN 6
                WHEN 'bathhouse' THEN 4
                WHEN 'tavern'    THEN 4
                ELSE 0 END
      ), 0)
  )) WHERE mt.owner_player_id = p_uid;
END;
$function$;
