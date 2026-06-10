-- Patch: re-create verify_extractor_path
-- Likely missed during the M2 paste on mobile. Run as a standalone query.

CREATE OR REPLACE FUNCTION public.verify_extractor_path(
  p_player_id uuid,
  p_ex integer,
  p_ey integer,
  p_tx integer,
  p_ty integer
)
RETURNS integer LANGUAGE plpgsql STABLE AS $$
DECLARE
  v_visited jsonb := '{}'::jsonb;
  v_queue jsonb := '[]'::jsonb;
  v_cur jsonb;
  v_rx integer;
  v_ry integer;
  v_dist integer;
  v_neighbor_key text;
  v_neighbor record;
  v_iters integer := 0;
  v_max_iters integer := 1000;
BEGIN
  FOR v_neighbor IN
    SELECT b.x AS rx, b.y AS ry
    FROM public.buildings b
    JOIN public.building_types bt ON bt.key = b.building_type_key
    WHERE bt.category = 'road' AND b.status = 'active' AND b.player_id = p_player_id
      AND (
        (b.x = p_ex - 1 AND b.y = p_ey)
        OR (b.x = p_ex + 1 AND b.y = p_ey)
        OR (b.x = p_ex AND b.y = p_ey - 1)
        OR (b.x = p_ex AND b.y = p_ey + 1)
      )
  LOOP
    v_neighbor_key := v_neighbor.rx || ',' || v_neighbor.ry;
    IF NOT (v_visited ? v_neighbor_key) THEN
      v_visited := v_visited || jsonb_build_object(v_neighbor_key, true);
      v_queue := v_queue || jsonb_build_array(jsonb_build_object(
        'x', v_neighbor.rx, 'y', v_neighbor.ry, 'd', 1
      ));
    END IF;
  END LOOP;

  WHILE jsonb_array_length(v_queue) > 0 AND v_iters < v_max_iters LOOP
    v_iters := v_iters + 1;
    v_cur := v_queue->0;
    v_queue := v_queue - 0;
    v_rx := (v_cur->>'x')::integer;
    v_ry := (v_cur->>'y')::integer;
    v_dist := (v_cur->>'d')::integer;

    IF (ABS(v_rx - p_tx) + ABS(v_ry - p_ty)) = 1 THEN
      RETURN v_dist;
    END IF;

    FOR v_neighbor IN
      SELECT b.x AS rx, b.y AS ry
      FROM public.buildings b
      JOIN public.building_types bt ON bt.key = b.building_type_key
      WHERE bt.category = 'road' AND b.status = 'active' AND b.player_id = p_player_id
        AND (
          (b.x = v_rx - 1 AND b.y = v_ry)
          OR (b.x = v_rx + 1 AND b.y = v_ry)
          OR (b.x = v_rx AND b.y = v_ry - 1)
          OR (b.x = v_rx AND b.y = v_ry + 1)
        )
    LOOP
      v_neighbor_key := v_neighbor.rx || ',' || v_neighbor.ry;
      IF NOT (v_visited ? v_neighbor_key) THEN
        v_visited := v_visited || jsonb_build_object(v_neighbor_key, true);
        v_queue := v_queue || jsonb_build_array(jsonb_build_object(
          'x', v_neighbor.rx, 'y', v_neighbor.ry, 'd', v_dist + 1
        ));
      END IF;
    END LOOP;
  END LOOP;

  RETURN NULL;
END;
$$;
