-- Patch: add a DELETE RLS policy to public.buildings
-- The original schema enabled RLS on buildings but only defined SELECT/
-- INSERT/UPDATE policies. Without a DELETE policy, RLS silently rejects
-- every DELETE request — the demolish button "succeeded" client-side
-- but the row stayed in the DB and reappeared on the next reload.

DROP POLICY IF EXISTS buildings_delete_self ON public.buildings;

CREATE POLICY buildings_delete_self
  ON public.buildings FOR DELETE
  USING (auth.uid() = player_id);
