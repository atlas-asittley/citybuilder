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

let channel = null;
let onChangeCallback = null;

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

      // Was this a visually-meaningful change? Per-tick updates touch
      // last_processed_at on every building; we don't redraw for those.
      const visuallyChanged = (
        oldB.housing_tier !== newB.housing_tier ||
        oldB.status !== newB.status ||
        oldB.expansion_level !== newB.expansion_level ||
        oldB.is_staffed !== newB.is_staffed
      );

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
