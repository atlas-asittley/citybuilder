-- ─────────────────────────────────────────────────────────────────────
-- Pollution radius from footprint, not anchor (2026-05-11).
--
-- Atlas: "the pollution isn't centered around the center of my airport."
--
-- _pp_update_pollution was using ABS(mt.x - b.x) + ABS(mt.y - b.y),
-- i.e. manhattan distance from the building's anchor tile. For 1x1
-- buildings that's fine; for a 3x3 airport with anchor at (8,46) the
-- footprint extends to (10,48), so emissions skewed toward the NW.
--
-- Fix: compute distance to the nearest footprint tile using the
-- closed-form for distance from a point to an axis-aligned rectangle:
--
--   dx = max(0, b.x - mt.x, mt.x - (b.x + fw - 1))
--   dy = max(0, b.y - mt.y, mt.y - (b.y + fh - 1))
--   distance = dx + dy
--
-- (Inside the footprint both terms are 0, so the tile itself plus all
-- tiles within `radius` of any footprint tile are covered.)
-- ─────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public._pp_update_pollution(p_uid uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
BEGIN
  UPDATE public.map_tiles
  SET pollution = 0
  WHERE owner_player_id = p_uid AND pollution <> 0;

  UPDATE public.map_tiles mt
  SET pollution = GREATEST(0, agg.total)
  FROM (
    SELECT mt2.id AS tile_id, SUM(bt.pollution_emit) AS total
    FROM public.map_tiles mt2
    JOIN public.buildings b
      ON b.status = 'active'
    JOIN public.building_types bt
      ON bt.key = b.building_type_key
     AND bt.pollution_emit <> 0
    WHERE mt2.owner_player_id = p_uid
      AND (
        GREATEST(0, b.x - mt2.x, mt2.x - (b.x + COALESCE(bt.footprint_w, 1) - 1))
        + GREATEST(0, b.y - mt2.y, mt2.y - (b.y + COALESCE(bt.footprint_h, 1) - 1))
      ) <= bt.pollution_radius
      AND (
        b.is_staffed
        OR bt.pollution_emit < 0
        OR bt.category IN ('transport_hub', 'transport_connector')
      )
    GROUP BY mt2.id
  ) agg
  WHERE mt.id = agg.tile_id;
END;
$function$;
