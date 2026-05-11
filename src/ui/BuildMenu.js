// Build menu — collapsible bottom bar with categorized building
// types. Clicking a building enters placement mode (handled by
// MainScene which renders a ghost sprite that follows the cursor).
//
// v2 starting scope: show all building types the player's industry
// has access to, grouped by category. Don't try to predict which
// would succeed (road-adjacency, resource adjacency, cost, etc.) —
// the server's place_building RPC will reject invalid placements
// with a clear error.
import { state } from '../state/store.js';

let mounted = false;
let expanded = false;
let onSelectCallback = null;
let selectedKey = null;

const CATEGORY_ORDER = [
  'housing', 'service', 'police', 'tax',
  'food_extractor', 'extractor', 'processor',
  'booster', 'park',
  'transport_hub', 'transport_connector',
  'road'
];

const CATEGORY_LABELS = {
  housing: 'Housing',
  service: 'Services',
  police: 'Police',
  tax: 'Tax',
  food_extractor: 'Food',
  extractor: 'Extractors',
  processor: 'Processors',
  booster: 'Boosters',
  park: 'Parks',
  transport_hub: 'Transport Hubs',
  transport_connector: 'Connectors',
  road: 'Road'
};

export function mountBuildMenu(onSelect) {
  if (mounted) return;
  onSelectCallback = onSelect;

  const root = document.getElementById('ui-root');
  const menu = document.createElement('div');
  menu.id = 'build-menu';
  menu.innerHTML = `
    <button class="bm-toggle" id="bm-toggle">🔨 Build</button>
    <div class="bm-body" id="bm-body"></div>
  `;
  root.appendChild(menu);
  mounted = true;

  document.getElementById('bm-toggle').addEventListener('click', toggleMenu);
  renderBody();
}

export function unmountBuildMenu() {
  const el = document.getElementById('build-menu');
  if (el) el.remove();
  mounted = false;
}

export function clearSelection() {
  selectedKey = null;
  document.querySelectorAll('.bm-item').forEach((el) => el.classList.remove('selected'));
}

function toggleMenu() {
  expanded = !expanded;
  document.getElementById('build-menu').classList.toggle('expanded', expanded);
  if (expanded) renderBody();
}

function renderBody() {
  if (!mounted) return;
  const body = document.getElementById('bm-body');

  // Group available building types by category, in CATEGORY_ORDER.
  const grouped = {};
  for (const key in state.buildingTypes) {
    const bt = state.buildingTypes[key];
    if (!bt.category) continue;
    if (!grouped[bt.category]) grouped[bt.category] = [];
    grouped[bt.category].push(bt);
  }

  let html = '';
  for (const cat of CATEGORY_ORDER) {
    if (!grouped[cat] || grouped[cat].length === 0) continue;
    grouped[cat].sort((a, b) => (a.tier_required || 0) - (b.tier_required || 0));
    html += `<div class="bm-section">
      <h3 class="bm-section-title">${CATEGORY_LABELS[cat] || cat}</h3>
      <div class="bm-items">`;
    for (const bt of grouped[cat]) {
      const cost = bt.cost_money ? '$' + bt.cost_money : '';
      html += `<button class="bm-item" data-key="${bt.key}">
        <span class="bm-item-name">${bt.name || bt.key}</span>
        ${cost ? `<span class="bm-item-cost">${cost}</span>` : ''}
      </button>`;
    }
    html += '</div></div>';
  }
  body.innerHTML = html;

  body.querySelectorAll('.bm-item').forEach((btn) => {
    btn.addEventListener('click', () => {
      const key = btn.dataset.key;
      document.querySelectorAll('.bm-item').forEach((el) => el.classList.remove('selected'));
      if (selectedKey === key) {
        selectedKey = null;
        if (onSelectCallback) onSelectCallback(null);
        return;
      }
      selectedKey = key;
      btn.classList.add('selected');
      // Collapse the menu so the map is visible for placement.
      expanded = false;
      document.getElementById('build-menu').classList.remove('expanded');
      if (onSelectCallback) onSelectCallback(state.buildingTypes[key]);
    });
  });
}
