// Wrappers around the building-related RPCs. v2 uses the same
// server contract as v1 — these are thin so the call sites can
// stay clean.
import { sb } from './supabase.js';

export async function placeBuilding(tileId, buildingTypeKey) {
  const { data, error } = await sb.rpc('place_building', {
    p_tile_id: tileId,
    p_building_type_key: buildingTypeKey
  });
  if (error) throw error;
  return data;
}
