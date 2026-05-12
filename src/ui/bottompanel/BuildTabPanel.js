// Build tab — categorized list of available building types.
// Tap one to enter placement mode (caller's onSelect receives the
// building_type row). Selected building stays highlighted; tapping
// it again deselects.
import { state } from '../../state/store.js';

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

export function renderBuildTab(parent, onSelect) {
  const grouped = {};
  for (const key in state.buildingTypes) {
    const bt = state.buildingTypes[key];
    if (!bt.category || !bt.is_active) continue;
    (grouped[bt.category] = grouped[bt.category] || []).push(bt);
  }

  let html = '';
  for (const cat of CATEGORY_ORDER) {
    if (!grouped[cat] || !grouped[cat].length) continue;
    grouped[cat].sort((a, b) =>
      (a.tier_required || 0) - (b.tier_required || 0) ||
      a.name.localeCompare(b.name));
    html += `<div class="btp-section">
      <h3 class="btp-section-title">${CATEGORY_LABELS[cat] || cat}</h3>
      <div class="btp-items">`;
    for (const bt of grouped[cat]) {
      const isSelected = selectedKey === bt.key;
      const cost = bt.build_cost ? '$' + bt.build_cost : '';
      html += `<button class="btp-item${isSelected ? ' selected' : ''}" data-key="${bt.key}">
        <span class="btp-name">${bt.name || bt.key}</span>
        ${cost ? `<span class="btp-cost">${cost}</span>` : ''}
      </button>`;
    }
    html += `</div></div>`;
  }
  parent.innerHTML = html || '<p class="btp-empty">No buildings available.</p>';

  parent.querySelectorAll('.btp-item').forEach((btn) => {
    btn.addEventListener('click', () => {
      const key = btn.dataset.key;
      if (selectedKey === key) {
        selectedKey = null;
        btn.classList.remove('selected');
        onSelect(null);
      } else {
        selectedKey = key;
        parent.querySelectorAll('.btp-item').forEach((b) =>
          b.classList.toggle('selected', b === btn));
        onSelect(state.buildingTypes[key]);
      }
    });
  });
}

export function clearBuildTabSelection() {
  selectedKey = null;
  const root = document.getElementById('bp-content');
  if (root) root.querySelectorAll('.btp-item.selected').forEach((b) => b.classList.remove('selected'));
}
