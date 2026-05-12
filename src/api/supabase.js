// Supabase client — single shared instance used everywhere.
// Re-exports `sb` for back-compat with the old config.js path so I
// don't have to chase every import as the codebase grows.
import { createClient } from '@supabase/supabase-js';

const SUPABASE_URL = 'https://igaulapupbtdcqqjobhs.supabase.co';
const SUPABASE_ANON_KEY = 'sb_publishable_7yi3BNg-J-K5nralw5JSww_c71Pge6e';

export const sb = createClient(SUPABASE_URL, SUPABASE_ANON_KEY);

// Paginated fetcher that loops over Supabase's server-side
// `db-max-rows=1000` cap. Any client `.range(0, big)` is silently
// trimmed to the first 1000 rows, so we loop in 1000-row chunks
// until a short page comes back.
//
// Pass a *factory* function that builds a fresh query each call —
// PostgREST builders accumulate state, so reusing one is unsafe.
//
//   const rows = await fetchAllPaged(() =>
//     sb.from('trade_transactions').select('*').eq('player_id', uid));
export async function fetchAllPaged(buildQuery, pageSize = 1000) {
  const rows = [];
  let start = 0;
  // eslint-disable-next-line no-constant-condition
  while (true) {
    const { data, error } = await buildQuery().range(start, start + pageSize - 1);
    if (error) throw error;
    const batch = data || [];
    rows.push(...batch);
    if (batch.length < pageSize) break;
    start += pageSize;
  }
  return rows;
}
