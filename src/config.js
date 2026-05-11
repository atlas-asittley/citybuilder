// Supabase config — identical to the v1 game so both clients share
// the same backend, accounts, and live world state during the
// migration. When the v2 cutover happens the v1 deploy gets deleted
// from the site repo but the DB underneath doesn't move.
import { createClient } from '@supabase/supabase-js';

const SUPABASE_URL = 'https://igaulapupbtdcqqjobhs.supabase.co';
const SUPABASE_ANON_KEY = 'sb_publishable_7yi3BNg-J-K5nralw5JSww_c71Pge6e';

export const sb = createClient(SUPABASE_URL, SUPABASE_ANON_KEY);
