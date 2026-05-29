// Wrappers around the building-related RPCs. v2 uses the same
// server contract as v1 — these are thin so the call sites can
// stay clean.
import { sb } from './supabase.js';

// Some RPCs collide with the pg_cron tick worker if they fire at the
// exact second the minute-boundary tick starts (both lock overlapping
// building rows). Postgres surfaces this as
// "deadlock detected". Atlas hit this 2026-05-11 on demolish. A single
// 250ms retry resolves it >99% of the time without surfacing the
// scary error to the user.
//
// Exported as `_callWithDeadlockRetry` for unit tests — pass an
// alternative rpcCaller via `_rpcOverride` to mock supabase.
export async function _callWithDeadlockRetry(rpcName, args, retries = 1, opts = {}) {
  return callWithDeadlockRetryInner(rpcName, args, retries, opts);
}

async function callWithDeadlockRetryInner(rpcName, args, retries = 1, opts = {}) {
  const rpcCaller = opts._rpcOverride || ((n, a) => sb.rpc(n, a));
  const sleep = opts._sleepOverride || ((ms) => new Promise((res) => setTimeout(res, ms)));
  let lastErr = null;
  for (let attempt = 0; attempt <= retries; attempt++) {
    const { data, error } = await rpcCaller(rpcName, args);
    if (!error) return data;
    lastErr = error;
    const isDeadlock = /deadlock/i.test(error.message || '');
    if (!isDeadlock || attempt === retries) throw error;
    await sleep(250);
  }
  throw lastErr;
}

async function callWithDeadlockRetry(rpcName, args, retries = 1) {
  return callWithDeadlockRetryInner(rpcName, args, retries);
}

export function placeBuilding(tileId, buildingTypeKey) {
  return callWithDeadlockRetry('place_building', {
    p_tile_id: tileId,
    p_building_type_key: buildingTypeKey
  });
}

export function demolishBuilding(buildingId) {
  return callWithDeadlockRetry('demolish_building', { p_building_id: buildingId });
}

export function upgradeHouse(buildingId) {
  return callWithDeadlockRetry('upgrade_house', { p_building_id: buildingId });
}

export function upgradeRoad(buildingId, targetKey) {
  return callWithDeadlockRetry('upgrade_road', {
    p_building_id: buildingId,
    p_target_key: targetKey
  });
}

export function setHouseAutoUpgrade(buildingId, enabled) {
  return callWithDeadlockRetry('set_house_auto_upgrade', {
    p_building_id: buildingId,
    p_enabled: enabled
  });
}

export function setBuildingPaused(buildingId, paused) {
  return callWithDeadlockRetry('set_building_paused', {
    p_building_id: buildingId,
    p_paused: paused
  });
}

export function setBuildingPriority(buildingId, priority) {
  return callWithDeadlockRetry('set_building_priority', {
    p_building_id: buildingId,
    p_priority: priority
  });
}

export function expandTransportHub(buildingId) {
  return callWithDeadlockRetry('expand_transport_hub', {
    p_building_id: buildingId
  });
}
