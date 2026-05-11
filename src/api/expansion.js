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

// Server formula matches v1: 1000 * chunks_owned^2.
export function nextExpansionCost() {
  const owned = (state.profile && state.profile.chunks_owned) || 1;
  return 1000 * owned * owned;
}
