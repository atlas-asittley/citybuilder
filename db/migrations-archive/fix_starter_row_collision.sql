-- next_starter_row picks max(reserved_row) + 1, which doesn't account for
-- chunks already claimed by another player's expansion. After Atlas expanded
-- his district into chunk (0, 1), every new player tried to claim row 1 and
-- got "Chunk (0, 1) is already allocated" — including tests.
--
-- Fix: walk forward from the candidate row until we find a row whose starter
-- chunk (0, row) is unoccupied.
--
-- Apply: psql "$DB_URL" -f fix_starter_row_collision.sql

CREATE OR REPLACE FUNCTION public.next_starter_row()
 RETURNS integer
 LANGUAGE plpgsql
AS $function$
DECLARE
  v_row integer;
  v_max_row integer;
BEGIN
  SELECT max(pp.reserved_row) INTO v_max_row
  FROM public.player_profiles pp
  WHERE pp.reserved_row IS NOT NULL;
  v_row := COALESCE(v_max_row + 1, 0);
  -- Skip rows whose starter chunk (0, row) is already claimed by another
  -- player's expansion. Walk forward until we find a free starter slot.
  WHILE EXISTS (
    SELECT 1 FROM public.district_chunks WHERE chunk_x = 0 AND chunk_y = v_row
  ) LOOP
    v_row := v_row + 1;
  END LOOP;
  RETURN v_row;
END;
$function$;
