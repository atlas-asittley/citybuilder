-- Split recompute_extractor_paths into public (auth-checked)
-- and _recompute_extractor_paths (internal). Triggers like
-- handle_building_change run in the original caller's
-- transaction context — auth.uid() is whoever did the
-- DELETE, not necessarily OLD.player_id. The auth check on
-- the public version was rejecting those legitimate trigger
-- cascades. Move the trigger to call _recompute_extractor_paths
-- which has no auth check; PostgREST callers still hit the
-- public version with the auth guard.

CREATE OR REPLACE FUNCTION public._recompute_extractor_paths(p_player_id uuid)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  v_extractor record;
  v_path record;
  v_verify integer;
  v_recomputed integer := 0;
  v_idle integer := 0;
BEGIN
  FOR v_extractor IN
    SELECT b.id, b.x, b.y, b.target_x, b.target_y
    FROM public.buildings b
    JOIN public.building_types bt ON bt.key = b.building_type_key
    WHERE b.player_id = p_player_id
      AND bt.category = 'extractor'
      AND b.status = 'active'
  LOOP
    IF v_extractor.target_x IS NOT NULL THEN
      -- Verify current path
      v_verify := public.verify_extractor_path(
        p_player_id, v_extractor.x, v_extractor.y,
        v_extractor.target_x, v_extractor.target_y
      );
      IF v_verify IS NOT NULL THEN
        -- Path still valid; refresh path_length in case roads were optimized
        UPDATE public.buildings SET path_length = v_verify WHERE id = v_extractor.id;
        v_recomputed := v_recomputed + 1;
        CONTINUE;
      END IF;
      -- Path broken — release claim
      UPDATE public.map_tiles
      SET claimed_by_building_id = NULL
      WHERE claimed_by_building_id = v_extractor.id;
      UPDATE public.buildings
      SET target_x = NULL, target_y = NULL, path_length = NULL
      WHERE id = v_extractor.id;
    END IF;

    -- Try to find a new target
    SELECT * INTO v_path
    FROM public.find_nearest_unclaimed_resource(
      p_player_id, v_extractor.x, v_extractor.y
    );
    IF v_path IS NOT NULL AND v_path.path_length IS NOT NULL THEN
      UPDATE public.buildings
      SET target_x = v_path.target_x,
          target_y = v_path.target_y,
          path_length = v_path.path_length
      WHERE id = v_extractor.id;
      UPDATE public.map_tiles
      SET claimed_by_building_id = v_extractor.id
      WHERE x = v_path.target_x AND y = v_path.target_y;
      v_recomputed := v_recomputed + 1;
    ELSE
      v_idle := v_idle + 1;
    END IF;
  END LOOP;

  RETURN json_build_object('recomputed', v_recomputed, 'idle', v_idle);
END;
$function$
;


CREATE OR REPLACE FUNCTION public.handle_building_change()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
DECLARE
  v_bt record;
BEGIN
  IF TG_OP = 'DELETE' THEN
    SELECT * INTO v_bt FROM public.building_types WHERE key = OLD.building_type_key;
    IF v_bt.category = 'road' THEN
      PERFORM public._recompute_extractor_paths(OLD.player_id);
    END IF;
    RETURN OLD;
  END IF;
  RETURN NEW;
END;
$function$;
