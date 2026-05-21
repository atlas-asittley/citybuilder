// Realtime subscription to buildings + tile changes. Listens to
// INSERTS/UPDATES/DELETES on the shared buildings table and keeps
// state.allBuildings in sync so the v2 client sees other players'
// changes as they happen — and sees its own tick-driven changes
// without waiting for the next process_production poll.
//
// Same channel pattern as v1's realtime.js, but with a small
// filter: we only refresh the scene when the change is visually
// meaningful. Per-tick `last_processed_at` updates fire constantly
// and don't need to redraw anything.
import { sb } from '../api/supabase.js';
import { state } from './store.js';

// Was a realtime UPDATE visually meaningful? Per-tick updates touch
// last_processed_at on every building; we don't redraw for those.
// Includes every field the building-render signature reads, so any
// such change flows through to the scene. Exported for unit tests.
export function buildingVisuallyChanged(oldB, newB) {
  return (
    oldB.housing_tier !== newB.housing_tier ||
    oldB.status !== newB.status ||
    oldB.expansion_level !== newB.expansion_level ||
    oldB.is_staffed !== newB.is_staffed ||
    oldB.auto_upgrade !== newB.auto_upgrade ||
    oldB.staffing_priority !== newB.staffing_priority ||
    oldB.last_devolve_reason !== newB.last_devolve_reason ||
    (!!oldB.evolution_eligible_at) !== (!!newB.evolution_eligible_at) ||
    // path_length feeds the inspector's effective-rate display for
    // extractors. Without it here, placing a road that shortens an
    // extractor's path doesn't refresh the inspector until the next
    // 30s tick — the player sees the old path number for up to 30s.
    oldB.path_length !== newB.path_length ||
    oldB.target_x !== newB.target_x || oldB.target_y !== newB.target_y ||
    oldB.x !== newB.x || oldB.y !== newB.y
  );
}

let channel = null;
let onChangeCallback = null;
let onOffersChangedCallback = null;

export function setOffersChangedCallback(cb) { onOffersChangedCallback = cb; }

export function subscribeRealtime(onChange) {
  if (channel) sb.removeChannel(channel);
  onChangeCallback = onChange;

  channel = sb.channel('citybuilder-v2')
    .on('postgres_changes', {
      event: 'INSERT', schema: 'public', table: 'buildings'
    }, async (payload) => {
      const newB = payload.new;
      if (!newB?.id) return;
      // Fetch the full row with the joined display_name for owner
      // attribution — the realtime payload doesn't include joins.
      const { data } = await sb
        .from('buildings')
        .select('*, player_profiles(display_name, color_hex)')
        .eq('id', newB.id)
        .maybeSingle();
      if (!data) return;

      // Skip duplicates — our own RPC handler may have already added
      // an optimistic entry.
      if (!state.allBuildings.some((b) => b.id === data.id)) {
        state.allBuildings.push(data);
        notify();
      }
    })
    .on('postgres_changes', {
      event: 'UPDATE', schema: 'public', table: 'buildings'
    }, (payload) => {
      const newB = payload.new;
      if (!newB?.id) return;

      const idx = state.allBuildings.findIndex((b) => b.id === newB.id);
      if (idx === -1) return;
      const oldB = state.allBuildings[idx];

      const visuallyChanged = buildingVisuallyChanged(oldB, newB);

      // Preserve the joined player_profiles; the realtime payload
      // omits it.
      const pp = oldB.player_profiles;
      state.allBuildings[idx] = newB;
      state.allBuildings[idx].player_profiles = pp;

      if (visuallyChanged) notify();
    })
    .on('postgres_changes', {
      event: 'DELETE', schema: 'public', table: 'buildings'
    }, (payload) => {
      const oldB = payload.old;
      if (!oldB?.id) return;
      const before = state.allBuildings.length;
      state.allBuildings = state.allBuildings.filter((b) => b.id !== oldB.id);
      if (state.allBuildings.length !== before) notify();
    })
    // Trade offers: any change to a row I'm party to bumps the
    // pending-offers count. Caller (main.js) wires this to the
    // refresh pipeline; we don't try to mirror full row state
    // client-side, just signal that something changed.
    .on('postgres_changes', {
      event: '*', schema: 'public', table: 'player_trade_offers'
    }, (payload) => {
      const row = payload.new || payload.old;
      if (!row) return;
      const me = state.currentUser?.id;
      if (row.from_player_id !== me && row.to_player_id !== me) return;
      if (onOffersChangedCallback) onOffersChangedCallback();
    })
    .subscribe();
}

export function unsubscribeRealtime() {
  if (channel) {
    sb.removeChannel(channel);
    channel = null;
  }
}

function notify() {
  if (onChangeCallback) onChangeCallback();
}
