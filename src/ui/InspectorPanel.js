// Building inspector — DOM panel that slides up from the bottom
// when the player taps a building. Shows name, type, status,
// staffing, owner. v1's inspector is elaborate (devolve reasons,
// AoE highlights, manage-tab); we start with the minimum useful
// surface and grow from there.
import { state } from '../state/store.js';

let mounted = false;
let activeBuilding = null;
let onCloseCallback = null;

export function openInspector(building, onClose) {
  activeBuilding = building;
  onCloseCallback = onClose || null;
  if (!mounted) mountInspector();
  renderInspector();
}

export function closeInspector() {
  if (!mounted) return;
  const panel = document.getElementById('inspector-panel');
  if (panel) panel.classList.remove('open');
  activeBuilding = null;
  if (onCloseCallback) {
    onCloseCallback();
    onCloseCallback = null;
  }
}

function mountInspector() {
  const root = document.getElementById('ui-root');
  const panel = document.createElement('div');
  panel.id = 'inspector-panel';
  panel.innerHTML = `
    <div class="ip-header">
      <div class="ip-title-row">
        <h2 class="ip-title" id="ip-title"></h2>
        <button class="ip-close" id="ip-close" aria-label="Close">×</button>
      </div>
      <p class="ip-subtitle" id="ip-subtitle"></p>
    </div>
    <div class="ip-body" id="ip-body"></div>
  `;
  root.appendChild(panel);
  mounted = true;

  document.getElementById('ip-close').addEventListener('click', closeInspector);
}

function renderInspector() {
  const panel = document.getElementById('inspector-panel');
  const b = activeBuilding;
  if (!b) return;

  const bt = state.buildingTypes[b.building_type_key] || {};
  const owner = b.player_profiles?.display_name || 'unknown';
  const isMine = b.player_id === state.currentUser?.id;

  document.getElementById('ip-title').textContent = bt.name || b.building_type_key;
  document.getElementById('ip-subtitle').textContent =
    `${bt.category || 'building'} · owned by ${isMine ? 'you' : owner}`;

  const rows = [];
  rows.push(row('Status', formatStatus(b)));
  if (bt.worker_cost > 0) rows.push(row('Workers', b.is_staffed ? `${bt.worker_cost} (staffed)` : `${bt.worker_cost} (unstaffed)`));
  if (b.housing_tier) {
    const tier = state.housingTierConfig[b.housing_tier];
    rows.push(row('Housing tier', tier ? `${tier.name} (tier ${b.housing_tier})` : `tier ${b.housing_tier}`));
    if (b.population) rows.push(row('Residents', b.population));
  }
  rows.push(row('Location', `(${b.x}, ${b.y})`));
  rows.push(row('Footprint', `${bt.footprint_w || 1} × ${bt.footprint_h || 1}`));
  if (bt.pollution_emit > 0) rows.push(row('Pollution', `${bt.pollution_emit} emit, radius ${bt.pollution_radius}`));
  if (bt.description) rows.push(row('About', bt.description, true));

  document.getElementById('ip-body').innerHTML = rows.join('');
  panel.classList.add('open');
}

function row(label, value, wide) {
  return `<div class="ip-row ${wide ? 'ip-row-wide' : ''}">
    <span class="ip-label">${label}</span>
    <span class="ip-value">${escapeHtml(String(value))}</span>
  </div>`;
}

function formatStatus(b) {
  if (b.status === 'idle') return 'idle (no input or no output capacity)';
  if (b.status === 'active') return b.is_staffed ? 'active' : 'active (unstaffed)';
  return b.status || '—';
}

function escapeHtml(s) {
  return s.replace(/[&<>"]/g, (c) => ({
    '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;'
  }[c]));
}

export function isInspectorOpen() {
  return activeBuilding !== null;
}
