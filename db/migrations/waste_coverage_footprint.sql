-- ─────────────────────────────────────────────────────────────────────
-- waste_coverage_footprint.sql  (2026-06-04)
--
-- Bug: compute_waste uses anchor-to-anchor Manhattan distance for
-- sanitation-to-housing coverage checks. Recycling centers and
-- incinerators are 2×2, so their bottom-right tiles were never counted.
-- A house near the right/bottom edge of a recycling center appears
-- covered visually but the check measured from the anchor only,
-- under-counting covered houses by up to 2 Manhattan tiles.
--
-- Reported by Jill: citywide waste shows 100 despite recycling centers
-- covering her houses.
--
-- Fix: replace ABS(s.x-h.x)+ABS(s.y-h.y) with the footprint-perimeter
-- Manhattan formula (same pattern as pollution_footprint_distance.sql):
--
--   GREATEST(0, s.x - h.x, h.x - (s.x + fw - 1))
--   + GREATEST(0, s.y - h.y, h.y - (s.y + fh - 1))
--
-- For 1×1 buildings (dump) this reduces identically to the old formula.
-- For 2×2 buildings (recycling_center, incinerator) it measures from
-- the nearest cell in the footprint, matching visual intuition.
--
-- Note: waste=100 for heavy-industry cities is dominated by the
-- industrial-emission floor (waste_emit per processor); that is a
-- balance issue deferred to Atlas.
-- ─────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.compute_waste(p_uid uuid)
 RETURNS numeric
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
AS $function$
DECLARE
  v_population numeric;
  v_uncovered integer;
  v_industry numeric;
  v_score numeric;
BEGIN
  SELECT population INTO v_population FROM public.player_profiles WHERE id = p_uid;
  IF v_population IS NULL THEN v_population := 5; END IF;

  -- Active houses NOT within coverage_radius of a staffed sanitation building.
  -- Uses footprint-perimeter Manhattan distance so multi-tile buildings
  -- (recycling_center, incinerator) measure from their nearest cell, not anchor.
  SELECT COUNT(*) INTO v_uncovered
  FROM public.buildings h
  JOIN public.building_types bt ON bt.key = h.building_type_key
  WHERE h.player_id = p_uid AND h.status = 'active' AND bt.category = 'housing'
    AND NOT EXISTS (
      SELECT 1 FROM public.buildings s
      JOIN public.building_types st ON st.key = s.building_type_key
      WHERE s.player_id = p_uid AND s.status = 'active' AND st.category = 'sanitation'
        AND s.is_staffed
        AND (
          GREATEST(0, s.x - h.x, h.x - (s.x + COALESCE(st.footprint_w, 1) - 1))
          + GREATEST(0, s.y - h.y, h.y - (s.y + COALESCE(st.footprint_h, 1) - 1))
        ) <= st.coverage_radius
    );

  -- Industrial byproduct floor from staffed buildings that emit waste.
  SELECT COALESCE(SUM(bt.waste_emit), 0) INTO v_industry
  FROM public.buildings b
  JOIN public.building_types bt ON bt.key = b.building_type_key
  WHERE b.player_id = p_uid AND b.status = 'active' AND b.is_staffed
    AND bt.waste_emit > 0;

  v_score := 3
    + 3 * v_uncovered
    + LEAST(15, FLOOR(v_population / 10))
    + v_industry;

  RETURN LEAST(100, GREATEST(0, v_score));
END;
$function$;
