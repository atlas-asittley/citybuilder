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
  // Load EVERY owned tile in the shared city (any player's), so the
  // pollution + desirability heatmaps work across parcel boundaries
  // — pollution from a neighbor's smelter visibly spills onto your
  // tiles. Paginated since multi-player cities may have >1000 tiles.
  void playerId;   // kept in the signature for callsites; no longer filtered
  const all = [];
  const PAGE = 1000;
  let from = 0;
  while (true) {
    const { data, error } = await sb
      .from('map_tiles')
      .select('id, x, y, terrain_type, resource_node_key, pollution, desirability, owner_player_id')
      .not('owner_player_id', 'is', null)
      .order('id')
      .range(from, from + PAGE - 1);
    if (error) throw error;
    if (!data || data.length === 0) break;
    all.push(...data);
    if (data.length < PAGE) break;
    from += PAGE;
  }
  const map = {};
  for (const t of all) map[t.x + ',' + t.y] = t;
  return map;
}

async function fetchBuildingTypes() {
  const { data, error } = await sb.from('building_types').select('*');
  if (error) throw error;
  const map = {};
  for (const bt of data) map[bt.key] = bt;
  return map;
}

// Per-house pantry buffers. Each row = one resource's buffer on one
// building (food + lifestyle goods on housing). Indexed in state as
// state.buildingBuffers[building_id][resource_key] = { quantity, capacity }.
// Used by:
//   - runway calc (lifestyle drain reads buffer fill, not city stock)
//   - inspector pantry display (per-resource %)
//   - housing devolve-risk gate (per-house, not global)
async function fetchBuildingBuffers() {
  const all = [];
  const PAGE = 1000;
  let from = 0;
  while (true) {
    const { data, error } = await sb
      .from('building_resource_buffers')
      .select('building_id, resource_key, quantity, capacity')
      .order('building_id')
      .range(from, from + PAGE - 1);
    if (error || !data) break;
    if (data.length === 0) break;
    all.push(...data);
    if (data.length < PAGE) break;
    from += PAGE;
  }
  const map = {};
  for (const b of all) {
    if (!map[b.building_id]) map[b.building_id] = {};
    map[b.building_id][b.resource_key] = {
      quantity: Number(b.quantity),
      capacity: Number(b.capacity)
    };
  }
  return map;
}

async function fetchBuildingResourceCosts() {
  // Some buildings cost not just $money but also raw resources to
  // place. The server enforces in place_building; UI surfaces in the
  // build card so the player can see why a button is disabled.
  const { data, error } = await sb.from('building_type_resource_costs').select('*');
  if (error || !data) return {};
  const map = {};
  for (const c of data) {
    if (!map[c.building_type_key]) map[c.building_type_key] = [];
    map[c.building_type_key].push({ resource_key: c.resource_key, quantity: c.quantity });
  }
  return map;
}

async function fetchHousingLifestyleDemands() {
  // Each row: { tier, resource_key, qty_per_minute }. Lifestyle goods
  // (pottery, bread, furniture, statuary) consumed by housing at the
  // given tier and above. Per-house demand × house count × tier
  // multiplier drives the city's drain rate, which is what makes the
  // runway calc useful.
  const { data, error } = await sb.from('housing_lifestyle_demands').select('*');
  if (error || !data) return {};
  const map = {};   // tier → [{ resource_key, qty_per_minute }]
  for (const d of data) {
    if (!map[d.tier]) map[d.tier] = [];
    map[d.tier].push({ resource_key: d.resource_key, qty_per_minute: Number(d.qty_per_minute) });
  }
  return map;
}

async function fetchHousingTiers() {
  // Table is housing_tier_config (not housing_tiers, which would be
  // the natural pluralization). v1's in-state map was called
  // housingTierConfig — matches the table name there.
  const { data, error } = await sb.from('housing_tier_config').select('*').order('tier');
  if (error) throw error;
  const map = {};
  for (const t of data) map[t.tier] = t;
  return map;
}

async function fetchResources() {
  // Resource catalog (timber, stone, etc.) — keyed by resource.key,
  // which matches map_tiles.resource_node_key. v1 unhelpfully called
  // the in-state map `resourceNodes`; the actual table is `resources`.
  const { data, error } = await sb.from('resources').select('*');
  if (error) throw error;
  const map = {};
  for (const r of data) map[r.key] = r;
  return map;
}

async function fetchTraders() {
  const { data, error } = await sb.from('traders').select('*').eq('is_active', true);
  if (error) return {};   // table absent in some envs — graceful empty
  const map = {};
  if (data) for (const t of data) map[t.key] = t;
  return map;
}

async function fetchTraderPrices() {
  // trader_prices has both global rows (city_id IS NULL) and per-
  // city rows. Per-city rows shadow globals for that trader — v1
  // implements this in JS and we mirror it here so the partner
  // panel shows the prices actually in effect for this city.
  const cityId = state.profile?.city_id || null;
  const { data, error } = await sb.from('trader_prices').select('*');
  if (error || !data) return {};

  const out = {};
  // Pass 1: global prices
  for (const tp of data) {
    if (tp.city_id) continue;
    if (!out[tp.trader_key]) out[tp.trader_key] = {};
    out[tp.trader_key][tp.resource_key] = {
      buy_price: tp.buy_price, sell_price: tp.sell_price,
      daily_buy_cap: tp.daily_buy_cap, daily_sell_cap: tp.daily_sell_cap
    };
  }
  // Pass 2: any trader with a city-specific row gets its catalog
  // completely rebuilt from those rows (matches server-side _trader_catalog).
  const cityTraders = new Set();
  for (const tp of data) {
    if (tp.city_id === cityId) cityTraders.add(tp.trader_key);
  }
  for (const tk of cityTraders) out[tk] = {};
  for (const tp of data) {
    if (tp.city_id !== cityId) continue;
    out[tp.trader_key][tp.resource_key] = {
      buy_price: tp.buy_price, sell_price: tp.sell_price,
      daily_buy_cap: tp.daily_buy_cap, daily_sell_cap: tp.daily_sell_cap
    };
  }
  return out;
}

// Most-recent visit timestamp per trader. Drives the "next visit in
// Xm" countdown on the Partners trader directory. Bounded fetch (50
// rows is more than enough to cover one row per active trader).
async function fetchTraderLastVisits() {
  const { data, error } = await sb
    .from('trader_visits')
    .select('trader_key, visited_at')
    .eq('player_id', state.currentUser.id)
    .order('visited_at', { ascending: false })
    .limit(50);
  if (error || !data) return {};
  const out = {};
  for (const row of data) {
    // First (most recent) row for each trader wins; subsequent ones skip.
    if (!out[row.trader_key]) out[row.trader_key] = row.visited_at;
  }
  return out;
}

// Today's per-trader-per-resource buy/sell usage vs caps. Drives the
// "5/10 today" indicators on the Partners tab so the player can see
// at a glance how much of each daily cap they've already burned.
// Cheap RPC — one row per (trader, resource) pair.
async function fetchTraderQuotas() {
  const { data, error } = await sb.rpc('get_trader_daily_quotas');
  if (error || !data) return {};
  const out = {};
  for (const row of data) {
    if (!out[row.trader_key]) out[row.trader_key] = {};
    out[row.trader_key][row.resource_key] = {
      buy_cap: row.buy_cap, buy_used: row.buy_used,
      sell_cap: row.sell_cap, sell_used: row.sell_used
    };
  }
  return out;
}

async function fetchTradePolicies() {
  const { data, error } = await sb.from('trade_policies').select('*');
  if (error || !data) return {};
  const map = {};
  for (const p of data) {
    map[p.resource_key] = {
      mode: p.mode,
      reserve_target: p.reserve_target,
      min_sell_price: p.min_sell_price,
      max_buy_price: p.max_buy_price
    };
  }
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

  const [buildings, tileMap, buildingTypes, housingTiers, resources, traders, traderPrices, tradePolicies, housingDemands, resourceCosts, buffers, traderQuotas, lastVisits] = await Promise.all([
    fetchAllBuildings(),
    fetchTileMap(state.currentUser.id),
    fetchBuildingTypes(),
    fetchHousingTiers(),
    fetchResources(),
    fetchTraders(),
    fetchTraderPrices(),
    fetchTradePolicies(),
    fetchHousingLifestyleDemands(),
    fetchBuildingResourceCosts(),
    fetchBuildingBuffers(),
    fetchTraderQuotas(),
    fetchTraderLastVisits()
  ]);

  state.allBuildings = buildings;
  state.tileMap = tileMap;
  state.buildingTypes = buildingTypes;
  state.housingTierConfig = housingTiers;
  state.resourceNodes = resources;   // keep store field name for back-compat
  state.traders = traders;
  state.allTraderPrices = traderPrices;
  state.tradePolicies = tradePolicies;
  state.housingLifestyleDemands = housingDemands;
  state.buildingResourceCosts = resourceCosts;
  state.buildingBuffers = buffers;
  state.traderQuotas = traderQuotas;
  state.traderLastVisits = lastVisits;

  const bounds = computeGridBounds(tileMap);
  state.gridMinX = bounds.minX;
  state.gridMinY = bounds.minY;
  state.gridCols = bounds.cols;
  state.gridRows = bounds.rows;
}
