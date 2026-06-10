-- ─────────────────────────────────────────────────────────────────────
-- Transport hubs pollute regardless of is_staffed (2026-05-11 hotfix).
--
-- Atlas: "I don't see the pollution on the heat map."
--
-- Root cause: _pp_staff_buildings only assigns is_staffed=true to
-- categories extractor/food_extractor/booster/processor/tax/service/police.
-- Transport categories (transport_hub, transport_connector) are skipped
-- — they're pure infrastructure, no production gated on staffing — so
-- is_staffed stays FALSE forever even though worker_cost is set.
--
-- _pp_update_pollution was previously gating positive emitters with
-- `b.is_staffed OR bt.pollution_emit < 0`, which silently dropped
-- every transport-hub emission to zero.
--
-- Fix: include transport categories in the "always emits" branch.
-- Thematically right: a hub pollutes from the traffic it attracts,
-- not from internal workers.
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
      ON b.player_id = p_uid AND b.status = 'active'
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
