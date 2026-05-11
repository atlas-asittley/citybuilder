// Initial data fetch after auth completes. Mirrors v1's enterGame()
// path but trimmed to just the rows the v2 renderer needs.
//
// All queries are read-only — no migrations or mutations. The v1
// client may be running concurrently against the same DB; both
// clients see the same rows.
import { sb } from '../api/supabase.js';
import { state } from './store.js';

// Pull every row from the buildings table for the current city.
// Paginated because PostgREST defaults to a 1000-row cap and a busy
// shared city outgrew that during v1.
async function fetchAllBuildings() {
  const all = [];
  const PAGE = 1000;
  let from = 0;
  while (true) {
    const { data, error } = await sb
      .from('buildings')
      .select('*, player_profiles(display_name, color_hex)')
      .order('id')
      .range(from, from + PAGE - 1);
    if (error) throw error;
    if (!data || data.length === 0) break;
    all.push(...data);
    if (data.length < PAGE) break;
    from += PAGE;
  }
  return all;
}

async function fetchTileMap(playerId) {
  const { data, error } = await sb
    .from('map_tiles')
    .select('x, y, terrain_type, resource_node_key, pollution, desirability, owner_player_id')
    .eq('owner_player_id', playerId);
  if (error) throw error;
  const map = {};
  for (const t of data) map[t.x + ',' + t.y] = t;
  return map;
}

async function fetchBuildingTypes() {
  const { data, error } = await sb.from('building_types').select('*');
  if (error) throw error;
  const map = {};
  for (const bt of data) map[bt.key] = bt;
  return map;
}

async function fetchHousingTiers() {
  const { data, error } = await sb.from('housing_tiers').select('*').order('tier');
  if (error) throw error;
  const map = {};
  for (const t of data) map[t.tier] = t;
  return map;
}

async function fetchResourceNodes() {
  const { data, error } = await sb.from('resource_nodes').select('*');
  if (error) throw error;
  const map = {};
  for (const r of data) map[r.key] = r;
  return map;
}

// Compute grid bounds from the player's owned tiles so the Phaser
// camera knows what world rectangle to constrain to.
function computeGridBounds(tileMap) {
  let minX = Infinity, maxX = -Infinity;
  let minY = Infinity, maxY = -Infinity;
  for (const k in tileMap) {
    const t = tileMap[k];
    if (t.x < minX) minX = t.x;
    if (t.x > maxX) maxX = t.x;
    if (t.y < minY) minY = t.y;
    if (t.y > maxY) maxY = t.y;
  }
  if (!isFinite(minX)) {
    return { minX: 0, minY: 0, cols: 0, rows: 0 };
  }
  return {
    minX, minY,
    cols: maxX - minX + 1,
    rows: maxY - minY + 1
  };
}

export async function loadInitialWorld() {
  if (!state.currentUser) throw new Error('loadInitialWorld called before auth');
  if (!state.profile) throw new Error('loadInitialWorld called before profile fetched');

  const [buildings, tileMap, buildingTypes, housingTiers, resourceNodes] = await Promise.all([
    fetchAllBuildings(),
    fetchTileMap(state.currentUser.id),
    fetchBuildingTypes(),
    fetchHousingTiers(),
    fetchResourceNodes()
  ]);

  state.allBuildings = buildings;
  state.tileMap = tileMap;
  state.buildingTypes = buildingTypes;
  state.housingTierConfig = housingTiers;
  state.resourceNodes = resourceNodes;

  const bounds = computeGridBounds(tileMap);
  state.gridMinX = bounds.minX;
  state.gridMinY = bounds.minY;
  state.gridCols = bounds.cols;
  state.gridRows = bounds.rows;
}
