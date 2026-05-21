// Expansion picker — paint adjacent parcels on the map, let the
// player tap one to claim. No modal list of "(chunk_x, chunk_y)"
// coords; the visualization IS the picker.
//
// Lifecycle:
//   1. Player taps Expand in topbar → openExpansionPanel
//   2. Server returns candidate chunks → MainScene paints pulsing
//      rectangles + tap handlers via showExpansionCandidates
//   3. A thin status bar appears at the bottom: cost + Cancel button
//   4. Tapping a candidate → confirm dialog → expandDistrict RPC
//   5. On success, loadInitialWorld + close + onComplete callback
import { fetchExpansionCandidates, expandDistrict, nextExpansionCost } from '../api/expansion.js';
import { state } from '../state/store.js';
import { loadInitialWorld } from '../state/loader.js';

let onCompleteCallback = null;
let active = false;
let sceneRef = null;
export function bindSceneToExpansion(scene) { sceneRef = scene; }

export async function openExpansionPanel(onComplete) {
  if (active) return;
  onCompleteCallback = onComplete;
  const cost = nextExpansionCost();

  if ((state.profile?.money || 0) < cost) {
    alert(`You need $${cost.toLocaleString()} to claim another parcel. Build a tax office or trade with NPCs to earn more.`);
    return;
  }

  let candidates = [];
  try {
    candidates = await fetchExpansionCandidates();
  } catch (err) {
    alert('Could not load expansion options: ' + (err.message || err));
    return;
  }
  if (!candidates.length) {
    alert('No adjacent parcels available to claim — your district is surrounded.');
    return;
  }

  active = true;
  // Paint pulsing rectangles on the map; the onPick callback fires
  // when a player taps one.
  if (sceneRef?.showExpansionCandidates) {
    sceneRef.showExpansionCandidates(candidates, (c) => onPickCandidate(c, cost));
  }
  // Frame the camera so the candidates + parcel center are all in
  // view (otherwise the player taps Expand on a zoomed-in city and
  // the candidates might be off-screen).
  frameCameraToCandidates(candidates);
  mountBar(cost);
}

let claimInFlight = false;
function onPickCandidate(c, cost) {
  if (claimInFlight) return;   // ignore double-taps mid-RPC
  if (!confirm(`Claim parcel at (${c.chunk_x}, ${c.chunk_y}) for $${cost.toLocaleString()}?`)) return;
  claimInFlight = true;
  expandDistrict(c.chunk_x, c.chunk_y)
    .then(async (result) => {
      if (result?.money !== undefined) state.profile.money = result.money;
      if (result?.chunks_owned !== undefined) state.profile.chunks_owned = result.chunks_owned;
      // If the user hit Cancel between our request and the response,
      // the panel's already torn down — don't re-open it via the
      // success path.
      if (!active) { claimInFlight = false; return; }
      await loadInitialWorld();
      close();
      if (onCompleteCallback) onCompleteCallback();
    })
    .catch((err) => {
      alert('Expansion failed: ' + (err.message || err));
    })
    .finally(() => { claimInFlight = false; });
}

function mountBar(cost) {
  const root = document.getElementById('ui-root');
  const bar = document.createElement('div');
  bar.id = 'expansion-bar';
  bar.innerHTML = `
    <span class="eb-text">
      <strong>Tap a glowing parcel to claim it.</strong>
      <small>Cost $${cost.toLocaleString()} · you have $${Math.floor(state.profile.money || 0).toLocaleString()}</small>
    </span>
    <button class="eb-cancel" id="eb-cancel">Cancel</button>
  `;
  root.appendChild(bar);
  // Animation frame for the "visible" class so the slide-up CSS
  // transition fires.
  requestAnimationFrame(() => bar.classList.add('visible'));
  document.getElementById('eb-cancel').addEventListener('click', close);
}

function close() {
  const el = document.getElementById('expansion-bar');
  if (el) el.remove();
  active = false;
  if (sceneRef?.clearExpansionCandidates) sceneRef.clearExpansionCandidates();
}

// Pan + zoom the camera so every candidate is visible alongside the
// player's parcel. Quick framing — no heavy easing, just snap.
function frameCameraToCandidates(candidates) {
  if (!sceneRef || !sceneRef.cameras) return;
  const CHUNK = 15;     // tile-size of one chunk (server allocate_district_chunk)
  const TILE_PX = 48;   // matches MainScene's TILE_PX
  let minX = Infinity, minY = Infinity, maxX = -Infinity, maxY = -Infinity;
  for (const c of candidates) {
    const x = c.chunk_x * CHUNK;
    const y = c.chunk_y * CHUNK;
    if (x < minX) minX = x;
    if (y < minY) minY = y;
    if (x + CHUNK > maxX) maxX = x + CHUNK;
    if (y + CHUNK > maxY) maxY = y + CHUNK;
  }
  // Include the player's own parcel center so the candidates are
  // shown in context, not floating in isolation.
  const own = state.profile;
  if (own?.home_x != null && own?.home_y != null) {
    if (own.home_x < minX) minX = own.home_x;
    if (own.home_y < minY) minY = own.home_y;
    if (own.home_x > maxX) maxX = own.home_x;
    if (own.home_y > maxY) maxY = own.home_y;
  }
  if (!Number.isFinite(minX)) return;

  const cam = sceneRef.cameras.main;
  const wx = (minX - state.gridMinX) * TILE_PX;
  const wy = (minY - state.gridMinY) * TILE_PX;
  const ww = (maxX - minX) * TILE_PX;
  const wh = (maxY - minY) * TILE_PX;
  // Pad 1 tile on each side so the candidates aren't tight against
  // the viewport edge.
  const pad = TILE_PX * 2;
  // Compute zoom that fits the bounding box, capped between camera
  // zoom limits (0.25 .. 3 in MainScene).
  const zoomX = (cam.width  - pad * 2) / Math.max(1, ww);
  const zoomY = (cam.height - pad * 2) / Math.max(1, wh);
  const zoom = Math.max(0.25, Math.min(1.5, Math.min(zoomX, zoomY)));
  cam.setZoom(zoom);
  cam.centerOn(wx + ww / 2, wy + wh / 2);
  // Save the new view so we don't reset after expansion completes.
  if (sceneRef._saveMapViewSoon) sceneRef._saveMapViewSoon();
}
