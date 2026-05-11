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
  } catch (e) {
    console.warn('tick request failed:', e.message || e);
  }
}

function applyTickResponse(data) {
  if (!data || !state.profile) return;

  if (data.money !== undefined) state.profile.money = data.money;
  if (data.population !== undefined) state.profile.population = data.population;
  if (data.happiness !== undefined) state.profile.happiness = data.happiness;
  if (data.crime !== undefined) state.profile.crime = data.crime;
  if (data.workers_used !== undefined) state.profile.workers_used = data.workers_used;
  if (data.worker_capacity !== undefined) state.profile.worker_capacity = data.worker_capacity;
  if (data.productivity !== undefined) state.profile.productivity = data.productivity;

  refreshTopBar();

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
