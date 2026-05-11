// Supabase client — single shared instance used everywhere.
// Re-exports `sb` for back-compat with the old config.js path so I
// don't have to chase every import as the codebase grows.
import { createClient } from '@supabase/supabase-js';

const SUPABASE_URL = 'https://igaulapupbtdcqqjobhs.supabase.co';
const SUPABASE_ANON_KEY = 'sb_publishable_7yi3BNg-J-K5nralw5JSww_c71Pge6e';

export const sb = createClient(SUPABASE_URL, SUPABASE_ANON_KEY);
