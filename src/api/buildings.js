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
async function callWithDeadlockRetry(rpcName, args, retries = 1) {
  let lastErr = null;
  for (let attempt = 0; attempt <= retries; attempt++) {
    const { data, error } = await sb.rpc(rpcName, args);
    if (!error) return data;
    lastErr = error;
    const isDeadlock = /deadlock/i.test(error.message || '');
    if (!isDeadlock || attempt === retries) throw error;
    await new Promise((res) => setTimeout(res, 250));
  }
  throw lastErr;
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
