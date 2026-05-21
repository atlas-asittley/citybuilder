// District expansion RPCs. expansion_candidates returns the chunks
// the player is allowed to claim (adjacent + buildable); expand_district
// actually claims one and adds its tiles to the player's parcel.
import { sb } from './supabase.js';
import { state } from '../state/store.js';

export async function fetchExpansionCandidates() {
  const { data, error } = await sb.rpc('expansion_candidates', {
    p_player_id: state.currentUser.id
  });
  if (error) throw error;
  return data || [];
}

export async function expandDistrict(chunkX, chunkY) {
  const { data, error } = await sb.rpc('expand_district', {
    p_chunk_x: chunkX,
    p_chunk_y: chunkY
  });
  if (error) throw error;
  return data;
}

// Mirror the server's expand_district formula: 10_000 * chunks_owned^2.
// The base was bumped 1000 → 10000 server-side; this mirror has to stay
// in lockstep or the player will see a price the server won't honor.
export function nextExpansionCost() {
  const owned = (state.profile && state.profile.chunks_owned) || 1;
  return 10000 * owned * owned;
}
