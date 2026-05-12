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
import { pollNotifications } from '../ui/BellLog.js';
import { refreshTutorialBanner } from '../ui/TutorialBanner.js';

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
    // Drain any new notifications (housing-ready, trade-cancel)
    // and bubble them into the bell-log badge.
    pollNotifications();
  } catch (e) {
    console.warn('tick request failed:', e.message || e);
  }
}

async function refreshTileMetrics() {
  if (!state.currentUser) return;
  const { data, error } = await sb
    .from('map_tiles')
    .select('id, x, y, pollution, desirability')
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
  }
  if (onTileMetricsChangedCallback) onTileMetricsChangedCallback();
}

let onTileMetricsChangedCallback = null;
export function onTileMetricsChanged(cb) {
  onTileMetricsChangedCallback = cb;
}

let onPopIncreaseCallback = null;
export function onPopIncrease(cb) {
  onPopIncreaseCallback = cb;
}

function applyTickResponse(data) {
  if (!data || !state.profile) return;

  if (data.inventory) {
    state.inventory = {};
    for (const k in data.inventory) state.inventory[k] = Number(data.inventory[k]);
  }
  if (data.money !== undefined) state.profile.money = data.money;

  // Spawn immigrant walkers when population rises. Cap so a big
  // immigration spike (e.g., first load after a long absence)
  // doesn't flood the map with sprites.
  const prevPopFloor = Math.floor(state.profile.population || 0);
  const newPopFloor = data.population !== undefined ? Math.floor(data.population) : prevPopFloor;
  const popDelta = newPopFloor - prevPopFloor;
  if (popDelta > 0 && onPopIncreaseCallback) {
    onPopIncreaseCallback(Math.min(popDelta, 4));
  }

  if (data.population !== undefined) state.profile.population = data.population;
  if (data.happiness !== undefined) state.profile.happiness = data.happiness;
  if (data.crime !== undefined) state.profile.crime = data.crime;
  if (data.workers_used !== undefined) state.profile.workers_used = data.workers_used;
  if (data.worker_capacity !== undefined) state.profile.worker_capacity = data.worker_capacity;
  if (data.productivity !== undefined) state.profile.productivity = data.productivity;
  if (data.tutorial_step !== undefined) state.profile.tutorial_step = data.tutorial_step;

  refreshTopBar();
  refreshTutorialBanner();

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
