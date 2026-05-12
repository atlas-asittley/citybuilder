// Placement bar — bottom-of-screen strip that appears whenever a
// building is selected for placement. Shows the building name and a
// Cancel button so the player can back out without finding the
// build menu again. Matches v1's `.placement-bar` element.
//
// Drag-cost counter is a sibling concept: during a road drag-paint
// it shows "N roads — $C" so the player knows what they're spending
// before lifting the finger. v1 has it; v2 didn't.
let placementMounted = false;
let dragMounted = false;
let onCancelCallback = null;

export function showPlacementBar(buildingType, onCancel) {
  onCancelCallback = onCancel || null;
  if (!placementMounted) {
    const root = document.getElementById('ui-root');
    const bar = document.createElement('div');
    bar.id = 'placement-bar';
    bar.innerHTML = `
      <span class="pb-text" id="pb-text"></span>
      <button class="pb-cancel" id="pb-cancel">Cancel</button>
    `;
    root.appendChild(bar);
    placementMounted = true;
    document.getElementById('pb-cancel').addEventListener('click', () => {
      if (onCancelCallback) onCancelCallback();
    });
  }
  const cost = buildingType.build_cost ? ` — $${buildingType.build_cost}` : '';
  document.getElementById('pb-text').textContent =
    `Tap a tile to place ${buildingType.name || buildingType.key}${cost}`;
  document.getElementById('placement-bar').classList.add('visible');
}

export function hidePlacementBar() {
  const el = document.getElementById('placement-bar');
  if (el) el.classList.remove('visible');
  onCancelCallback = null;
}

// ── Drag-cost counter ──
//
// Updated each time a tile is added to the in-flight drag-paint set.
// pass count + cost; show in a small floating chip near the cursor.
export function showDragCost(count, totalCost) {
  if (!dragMounted) {
    const root = document.getElementById('ui-root');
    const el = document.createElement('div');
    el.id = 'drag-cost';
    root.appendChild(el);
    dragMounted = true;
  }
  const el = document.getElementById('drag-cost');
  el.textContent = count + ' road' + (count !== 1 ? 's' : '') + ' — $' + totalCost;
  el.classList.add('visible');
}

export function hideDragCost() {
  const el = document.getElementById('drag-cost');
  if (el) el.classList.remove('visible');
}
