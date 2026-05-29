// Client-side production tick loop. Calls the server's
// process_production RPC every 30s — same cadence as v1. The
// server's pg_cron job advances simulation state every minute, so
// this is really just a "fetch latest snapshot of my profile +
// inventory" poll dressed up as a tick.
//
// On each successful response:
//   - state.profile is updated with money / population / happiness / etc.
//   - state.inventory is refreshed
//   - if evolution_events fired, we refetch buildings
//   - the top bar re-renders with the new numbers
import { sb } from './supabase.js';
import { state } from '../state/store.js';
import { refreshTopBar } from '../ui/TopBar.js';
import { refreshInfoBar } from '../ui/InfoBar.js';
import { pollNotifications } from '../ui/BellLog.js';
import { refreshTutorialBanner } from '../ui/TutorialBanner.js';
import { refreshBottomPanel } from '../ui/BottomPanel.js';

const TICK_INTERVAL_MS = 30000;
let tickTimer = null;
let onBuildingsChangedCallback = null;

export function startTickLoop(onBuildingsChanged) {
  if (tickTimer) clearInterval(tickTimer);
  onBuildingsChangedCallback = onBuildingsChanged || null;
  // Fire one immediately so the UI updates without waiting 30s.
  runTick();
  tickTimer = setInterval(runTick, TICK_INTERVAL_MS);
}

export function stopTickLoop() {
  if (tickTimer) clearInterval(tickTimer);
  tickTimer = null;
}

async function runTick() {
  try {
    const { data, error } = await sb.rpc('process_production');
    if (error) {
      console.warn('process_production error:', error.message);
      return;
    }
    applyTickResponse(data);
    // Pollution + desirability are recomputed every tick on the
    // server; refresh the local tileMap so heatmaps reflect current
    // values. Cheap — single SELECT bounded to this player's tiles.
    refreshTileMetrics();
    // City-wide pollution + desirability for heatmaps that span
    // parcel boundaries. Non-blocking; if it errors the heatmap just
    // shows local data only.
    refreshCityTileMetrics();
    // Trader daily-cap usage so the Partners tab's "5/10 today"
    // indicators stay live as auto-trade runs.
    refreshTraderQuotas();
    // Most-recent trader visit timestamps so the "next visit in Xm"
    // countdowns don't drift stale once auto-trade visits land.
    refreshTraderLastVisits();
    // Per-house pantry buffers so the runway calc + inspector reflect
    // the latest drain/refill state. Without this state.buildingBuffers
    // stays frozen at boot — devolve-risk and lifestyle-runway lie.
    refreshBuildingBuffers();
    // Drain any new notifications (housing-ready, trade-cancel)
    // and bubble them into the bell-log badge.
    pollNotifications();
    // Refresh the pending-offer count so the ⋯ More button can
    // wear a red badge when someone's sent you a trade offer.
    refreshPendingOfferCount();
  } catch (e) {
    console.warn('tick request failed:', e.message || e);
  }
}

async function refreshBuildingBuffers() {
  if (!state.currentUser) return;
  // Paginated to clear the 1000-row server cap — Jill has 60+ houses
  // × 4 buffered resources, so this is well under the cap, but other
  // players can hit it as their cities grow.
  try {
    const all = [];
    const PAGE = 1000;
    let from = 0;
    while (true) {
      const { data, error } = await sb
        .from('building_resource_buffers')
        .select('building_id, resource_key, quantity, capacity')
        .order('building_id')
        .range(from, from + PAGE - 1);
      if (error || !data) return;
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
    state.buildingBuffers = map;
  } catch (e) {
    console.warn('refreshBuildingBuffers error:', e.message || e);
  }
}

async function refreshTraderLastVisits() {
  if (!state.currentUser) return;
  try {
    const { data, error } = await sb
      .from('trader_visits')
      .select('trader_key, visited_at')
      .eq('player_id', state.currentUser.id)
      .order('visited_at', { ascending: false })
      .limit(50);
    if (error || !data) return;
    const out = {};
    for (const row of data) {
      if (!out[row.trader_key]) out[row.trader_key] = row.visited_at;
    }
    state.traderLastVisits = out;
  } catch (e) {
    console.warn('refreshTraderLastVisits error:', e.message || e);
  }
}

async function refreshTraderQuotas() {
  const { data, error } = await sb.rpc('get_trader_daily_quotas');
  if (error || !data) return;
  const out = {};
  for (const row of data) {
    if (!out[row.trader_key]) out[row.trader_key] = {};
    out[row.trader_key][row.resource_key] = {
      buy_cap: row.buy_cap, buy_used: row.buy_used,
      sell_cap: row.sell_cap, sell_used: row.sell_used
    };
  }
  state.traderQuotas = out;
}

async function refreshTileMetrics() {
  if (!state.currentUser) return;
  const { data, error } = await sb
    .from('map_tiles')
    .select('id, x, y, pollution, desirability, noise')
    .eq('owner_player_id', state.currentUser.id);
  if (error) {
    console.warn('refreshTileMetrics error:', error.message);
    return;
  }
  for (const row of data) {
    const t = state.tileMap[row.x + ',' + row.y];
    if (!t) continue;
    t.pollution = row.pollution;
    t.desirability = row.desirability;
    t.noise = row.noise;
  }
  if (onTileMetricsChangedCallback) onTileMetricsChangedCallback();
}

// City-wide pollution + desirability for every tile in the city,
// paginated to clear the 1000-row server cap. Loaded into a separate
// state slot so it stays decoupled from the player's own tile data —
// if this fetch errors out, the heatmap silently falls back to local
// tiles. Called from main.js after the game UI is up + on each tick.
export async function refreshCityTileMetrics() {
  try {
    const out = {};
    const PAGE = 1000;
    let from = 0;
    // eslint-disable-next-line no-constant-condition
    while (true) {
      const { data, error } = await sb
        .from('map_tiles')
        .select('x, y, pollution, desirability, owner_player_id')
        .order('id')
        .range(from, from + PAGE - 1);
      if (error) {
        console.warn('refreshCityTileMetrics error:', error.message);
        return;
      }
      if (!data || data.length === 0) break;
      for (const row of data) {
        // Only carry rows with a real owner — wilderness has nothing
        // to color on the heatmap.
        if (!row.owner_player_id) continue;
        out[row.x + ',' + row.y] = row;
      }
      if (data.length < PAGE) break;
      from += PAGE;
    }
    state.cityTileMetrics = out;
    if (onTileMetricsChangedCallback) onTileMetricsChangedCallback();
  } catch (e) {
    console.warn('refreshCityTileMetrics threw:', e.message || e);
  }
}

let onTileMetricsChangedCallback = null;
export function onTileMetricsChanged(cb) {
  onTileMetricsChangedCallback = cb;
}

let onPopIncreaseCallback = null;
export function onPopIncrease(cb) {
  onPopIncreaseCallback = cb;
}

let onPopDecreaseCallback = null;
export function onPopDecrease(cb) {
  onPopDecreaseCallback = cb;
}

let onOffersChangedCallback = null;
export function onOffersChanged(cb) {
  onOffersChangedCallback = cb;
}

export async function refreshPendingOfferCount() {
  const { count, error } = await sb
    .from('player_trade_offers')
    .select('*', { count: 'exact', head: true })
    .eq('to_player_id', state.currentUser.id)
    .eq('status', 'pending');
  if (error) return;
  const next = count || 0;
  if (next !== state.pendingIncomingOffers) {
    state.pendingIncomingOffers = next;
    if (onOffersChangedCallback) onOffersChangedCallback(next);
  }
}

// Public — call sites that invoke a money-spending RPC (place_building,
// demolish_building, upgrade_house, expand_district, expand_transport_hub,
// black_market_trade, dev_grant_money) should pass the response here.
// Applies money + inventory deltas optimistically so the topbar +
// affordability filters don't lag a 30s tick. Safe to call with any
// subset of fields; missing fields are skipped.
export function applyRpcResponse(data) {
  if (!data || !state.profile) return;
  if (data.money !== undefined) state.profile.money = data.money;
  if (data.inventory) {
    state.inventory = {};
    for (const k in data.inventory) state.inventory[k] = Number(data.inventory[k]);
  }
  if (data.chunks_owned !== undefined) state.profile.chunks_owned = data.chunks_owned;
  if (data.congestion !== undefined) state.profile.congestion = data.congestion;
  refreshTopBar();
  refreshBottomPanel();
}

function applyTickResponse(data) {
  if (!data || !state.profile) return;

  if (data.inventory) {
    state.inventory = {};
    for (const k in data.inventory) state.inventory[k] = Number(data.inventory[k]);
  }
  if (data.money !== undefined) state.profile.money = data.money;

  // Spawn immigrant / emigrant walkers on population change.
  // Cap so a big delta (e.g., first load after a long absence)
  // doesn't flood the map with sprites.
  const prevPopFloor = Math.floor(state.profile.population || 0);
  const newPopFloor = data.population !== undefined ? Math.floor(data.population) : prevPopFloor;
  const popDelta = newPopFloor - prevPopFloor;
  if (popDelta > 0 && onPopIncreaseCallback) {
    onPopIncreaseCallback(Math.min(popDelta, 4));
  } else if (popDelta < 0 && onPopDecreaseCallback) {
    onPopDecreaseCallback(Math.min(-popDelta, 4));
  }

  if (data.population !== undefined) state.profile.population = data.population;
  if (data.happiness !== undefined) state.profile.happiness = data.happiness;
  if (data.crime !== undefined) state.profile.crime = data.crime;
  if (data.workers_used !== undefined) state.profile.workers_used = data.workers_used;
  if (data.worker_capacity !== undefined) state.profile.worker_capacity = data.worker_capacity;
  if (data.workers_needed !== undefined) state.profile.workers_needed = data.workers_needed;
  if (data.labor_shortage !== undefined) state.profile.labor_shortage = data.labor_shortage;
  if (data.productivity !== undefined) state.profile.productivity = data.productivity;
  if (data.migration_rate !== undefined) state.profile.migration_rate = data.migration_rate;
  if (data.tutorial_step !== undefined) state.profile.tutorial_step = data.tutorial_step;
  // trade_unlocked + highest_housing_tier_ever drive build-menu gates;
  // before this they only refreshed on a full page reload, so a
  // player unlocking trade or hitting a new housing tier mid-session
  // wouldn't see the new buildings show up until they reloaded.
  if (data.trade_unlocked !== undefined) state.profile.trade_unlocked = data.trade_unlocked;
  if (data.highest_housing_tier_ever !== undefined) {
    state.profile.highest_housing_tier_ever = data.highest_housing_tier_ever;
  }

  // Mirror into laborInfo so the topbar's workers stat reads from a
  // stable shape regardless of which response field name landed.
  state.laborInfo.workerCapacity = state.profile.worker_capacity || 0;
  state.laborInfo.workersUsed = state.profile.workers_used || 0;
  state.laborInfo.workersNeeded = state.profile.workers_needed || 0;
  state.laborInfo.laborShortage = !!state.profile.labor_shortage;

  refreshTopBar();
  refreshInfoBar();
  refreshTutorialBanner();
  refreshBottomPanel();

  // Evolution events (devolves, upgrade-ready, lost-eligibility)
  // require a buildings refetch — those events imply housing_tier
  // or evolution_eligible_at changed.
  if (data.evolution_events && data.evolution_events.length > 0) {
    refetchBuildings();
  }
}

async function refetchBuildings() {
  const all = [];
  const PAGE = 1000;
  let from = 0;
  while (true) {
    const { data, error } = await sb
      .from('buildings')
      .select('*, player_profiles(display_name, color_hex)')
      .order('id')
      .range(from, from + PAGE - 1);
    if (error) {
      console.warn('refetchBuildings error:', error.message);
      return;
    }
    if (!data || data.length === 0) break;
    all.push(...data);
    if (data.length < PAGE) break;
    from += PAGE;
  }
  state.allBuildings = all;
  if (onBuildingsChangedCallback) onBuildingsChangedCallback();
}
