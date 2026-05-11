// Expansion picker — small modal listing the adjacent chunks the
// player can claim, with the cost. Triggered from the top bar
// "Expand" button. After a successful claim the world reloads and
// the new tiles appear in the parcel.
import { fetchExpansionCandidates, expandDistrict, nextExpansionCost } from '../api/expansion.js';
import { state } from '../state/store.js';
import { loadInitialWorld } from '../state/loader.js';

let onCompleteCallback = null;
let mounted = false;

export async function openExpansionPanel(onComplete) {
  if (mounted) return;       // already showing — second click is a no-op
  // Defensive: clear any orphan overlay (e.g., from a prior session
  // that didn't tear down cleanly).
  const orphan = document.getElementById('expansion-overlay');
  if (orphan) orphan.remove();
  onCompleteCallback = onComplete;
  const cost = nextExpansionCost();

  if ((state.profile?.money || 0) < cost) {
    alert(`You need $${cost} to claim another parcel.`);
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
    alert('No adjacent parcels available to claim.');
    return;
  }

  mount(candidates, cost);
}

function mount(candidates, cost) {
  mounted = true;
  // Tell the MainScene to draw outline rectangles around each
  // candidate chunk so the player can SEE which patches of land
  // they're choosing between, not just (chunk_x, chunk_y) numbers.
  if (sceneRef?.showExpansionCandidates) {
    sceneRef.showExpansionCandidates(candidates);
  }
  const root = document.getElementById('ui-root');
  const overlay = document.createElement('div');
  overlay.id = 'expansion-overlay';
  overlay.innerHTML = `
    <div class="ep-card">
      <div class="ep-header">
        <h2>Claim a new parcel</h2>
        <button class="ep-close" aria-label="Close">×</button>
      </div>
      <p class="ep-cost">Cost: <strong>$${cost}</strong>  ·  You have $${Math.floor(state.profile.money || 0)}</p>
      <p class="ep-hint">Tap a parcel to claim it. Each claim grows your district by one chunk.</p>
      <div class="ep-grid">
        ${candidates.map((c, i) => `
          <button class="ep-candidate" data-cx="${c.chunk_x}" data-cy="${c.chunk_y}">
            <span class="ep-num">#${i + 1}</span>
            <span class="ep-coords">chunk (${c.chunk_x}, ${c.chunk_y})</span>
          </button>
        `).join('')}
      </div>
    </div>
  `;
  root.appendChild(overlay);

  overlay.querySelector('.ep-close').addEventListener('click', close);
  overlay.addEventListener('click', (e) => {
    if (e.target === overlay) close();
  });

  overlay.querySelectorAll('.ep-candidate').forEach((btn) => {
    btn.addEventListener('click', async () => {
      const cx = Number(btn.dataset.cx);
      const cy = Number(btn.dataset.cy);
      btn.disabled = true;
      btn.textContent = 'Claiming…';
      try {
        const result = await expandDistrict(cx, cy);
        if (result?.money !== undefined) state.profile.money = result.money;
        if (result?.chunks_owned !== undefined) state.profile.chunks_owned = result.chunks_owned;
        // Refetch tile map + buildings so the new chunk appears.
        await loadInitialWorld();
        close();
        if (onCompleteCallback) onCompleteCallback();
      } catch (err) {
        alert('Expansion failed: ' + (err.message || err));
        btn.disabled = false;
      }
    });
  });
}

function close() {
  const el = document.getElementById('expansion-overlay');
  if (el) el.remove();
  mounted = false;
  if (sceneRef?.clearExpansionCandidates) sceneRef.clearExpansionCandidates();
}

let sceneRef = null;
export function bindSceneToExpansion(scene) { sceneRef = scene; }
