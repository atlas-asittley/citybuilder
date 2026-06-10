-- ─────────────────────────────────────────────────────────────────────
-- Fix: has_road_access only checked the 4 tiles orthogonal to the
-- anchor (b.x, b.y). For multi-tile buildings, that misses any road
-- that touches the right or bottom edge of the footprint, because
-- those neighbors are off the *interior* cells, not the anchor.
--
-- Concretely: a 2x2 truck_depot at (3,36) (footprint covers 3,36 / 4,36
-- / 3,37 / 4,37) reads "no road" if the only adjacent road is at
-- (5,36), (5,37), (3,38), or (4,38) — none are within 1 of the anchor.
--
-- Fix: look up the footprint of the building at (p_x, p_y) and check
-- the full perimeter. Cells inside the footprint are skipped (a road
-- inside your own footprint isn't "adjacent"). If no building exists
-- yet at the anchor (placement preview), default to 1x1.
-- ─────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.has_road_access(p_player_id uuid, p_x integer, p_y integer)
RETURNS boolean
LANGUAGE sql
STABLE
AS $function$
  WITH anchor AS (
    SELECT COALESCE(bt.footprint_w, 1) AS fw, COALESCE(bt.footprint_h, 1) AS fh
    FROM public.buildings b
    JOIN public.building_types bt ON bt.key = b.building_type_key
    WHERE b.player_id = p_player_id AND b.x = p_x AND b.y = p_y
    LIMIT 1
  ), dims AS (
    SELECT COALESCE((SELECT fw FROM anchor), 1) AS fw,
           COALESCE((SELECT fh FROM anchor), 1) AS fh
  )
  SELECT EXISTS (
    SELECT 1
    FROM public.buildings r
    JOIN public.building_types rbt ON rbt.key = r.building_type_key
    CROSS JOIN dims
    WHERE rbt.category = 'road' AND r.status = 'active'
      AND r.player_id = p_player_id
      AND (
        -- Perimeter strips around the [p_x..p_x+fw-1] × [p_y..p_y+fh-1] rect:
        -- left (x = p_x-1, y in [p_y..p_y+fh-1])
        (r.x = p_x - 1   AND r.y BETWEEN p_y AND p_y + dims.fh - 1) OR
        -- right (x = p_x+fw, y in [p_y..p_y+fh-1])
        (r.x = p_x + dims.fw AND r.y BETWEEN p_y AND p_y + dims.fh - 1) OR
        -- top (y = p_y-1, x in [p_x..p_x+fw-1])
        (r.y = p_y - 1   AND r.x BETWEEN p_x AND p_x + dims.fw - 1) OR
        -- bottom (y = p_y+fh, x in [p_x..p_x+fw-1])
        (r.y = p_y + dims.fh AND r.x BETWEEN p_x AND p_x + dims.fw - 1)
      )
  );
$function$;

-- The single-arg variant (no player) is only used by legacy paths.
-- Keep the 4-orthogonal behavior for that one for now — none of the
-- multi-tile buildings rely on it.
