-- ─────────────────────────────────────────────────────────────────────
-- Pollution crosses parcel boundaries (2026-05-11).
--
-- Atlas: "my neighbor's pollution doesn't come into my parcel.
-- it should."
--
-- _pp_update_pollution previously joined buildings with
-- `b.player_id = p_uid`, meaning each player's tick only counted
-- their OWN buildings as emitters. A neighbor's airport across the
-- property line contributed nothing to your tiles.
--
-- Fix: drop the player_id filter on `b`. The tile filter
-- (mt2.owner_player_id = p_uid) still scopes the UPDATE to this
-- player's tiles, but emissions can come from any active building
-- within manhattan distance. Same applies to negative emitters
-- (parks): a neighbor's park now also helps clean up your tiles.
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
      AND ABS(mt2.x - b.x) + ABS(mt2.y - b.y) <= bt.pollution_radius
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
