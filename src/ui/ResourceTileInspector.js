// Resource Tile Inspector — opens when the player taps an unbuilt
// tile that has a resource_node_key. Shows what can be built on it,
// what extractor harvests it, what processor consumes the harvested
// material (and what comes next in the chain), plus a Demolish
// button that calls clear_resource_tile.
//
// Reuses the building inspector's DOM (same #inspector-panel) so
// the chrome is consistent.
import { sb } from '../api/supabase.js';
import { state } from '../state/store.js';
import { closeInspector } from './InspectorPanel.js';
import { showToast } from './Toast.js';

let activeTile = null;

export function openResourceTileInspector(tile) {
  if (!tile?.resource_node_key) return;
  activeTile = tile;
  // Reuse the same inspector DOM the building inspector uses.
  if (!document.getElementById('inspector-panel')) {
    // Force inspector mount via a no-op openInspector won't work
    // since we want different content; just inject the panel here.
    mountIfMissing();
  }
  renderTileInspector();
  document.getElementById('inspector-panel').classList.add('open');
}

function mountIfMissing() {
  const root = document.getElementById('ui-root');
  if (document.getElementById('inspector-panel')) return;
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
    <div class="ip-actions" id="ip-actions"></div>
    <div class="ip-hint">tap outside to close</div>
  `;
  root.appendChild(panel);
  document.getElementById('ip-close').addEventListener('click', () => {
    panel.classList.remove('open');
    activeTile = null;
    closeInspector();
  });
}

function renderTileInspector() {
  const t = activeTile;
  if (!t) return;
  const res = state.resourceNodes[t.resource_node_key] || {};
  const rName = res.name || t.resource_node_key;
  const isTerrain = res.kind === 'terrain';

  document.getElementById('ip-title').textContent = isTerrain ? rName : rName + ' deposit';
  document.getElementById('ip-subtitle').textContent =
    `(${t.x}, ${t.y}) · ${res.industry_key || 'common'}`;

  // Find related buildings: extractor that targets this resource,
  // processor that consumes the extractor's output, etc.
  const builder = findBuilderRequiringTile(t.resource_node_key);
  const extractor = findExtractorFor(t.resource_node_key);
  const processor = extractor ? findProcessorConsuming(extractor.output_resource_key) : null;
  const processor2 = processor ? findProcessorConsuming(processor.output_resource_key) : null;

  const rows = [];
  rows.push(infoRow(isTerrain ? 'Terrain' : 'Resource', rName));
  if (builder) rows.push(infoRow('Build here', `${builder.name} → ${resName(builder.output_resource_key)}`));
  if (extractor) rows.push(infoRow('Harvested by', `${extractor.name} → ${resName(extractor.output_resource_key)}`));
  if (processor) rows.push(infoRow('Processed by', `${processor.name} → ${resName(processor.output_resource_key)}`));
  if (processor2) rows.push(infoRow('Then', `${processor2.name} → ${resName(processor2.output_resource_key)}`));

  document.getElementById('ip-body').innerHTML = rows.join('');

  const claimed = !!t.claimed_by_building_id;
  const actionsHtml = claimed
    ? `<p class="ip-row" style="color:#e0b070;">An extractor is targeting this tile — demolish that first.</p>`
    : `<button class="ip-btn ip-btn-danger" id="ip-clear-tile">Clear ${isTerrain ? 'terrain' : 'deposit'}</button>`;
  document.getElementById('ip-actions').innerHTML = actionsHtml;

  if (!claimed) {
    document.getElementById('ip-clear-tile').addEventListener('click', clearTile);
  }
}

async function clearTile() {
  const t = activeTile;
  if (!t) return;
  const btn = document.getElementById('ip-clear-tile');
  btn.disabled = true; btn.textContent = 'Clearing…';
  try {
    const { error } = await sb.rpc('clear_resource_tile', { p_tile_id: t.id });
    if (error) throw error;
    showToast(`${resName(t.resource_node_key)} cleared.`, 'success');
    // Refresh local tile data so the resource icon disappears.
    t.resource_node_key = null;
    const panel = document.getElementById('inspector-panel');
    panel?.classList.remove('open');
    activeTile = null;
  } catch (err) {
    showToast(err.message || 'Clear failed.', 'error');
    btn.disabled = false; btn.textContent = 'Clear';
  }
}

function findBuilderRequiringTile(resourceKey) {
  for (const k in state.buildingTypes) {
    const bt = state.buildingTypes[k];
    if (bt.placement_resource_node_key === resourceKey) return bt;
  }
  return null;
}
function findExtractorFor(resourceKey) {
  for (const k in state.buildingTypes) {
    const bt = state.buildingTypes[k];
    if ((bt.category === 'extractor' || bt.category === 'food_extractor')
        && bt.placement_resource_node_key === resourceKey) return bt;
  }
  return null;
}
function findProcessorConsuming(resourceKey) {
  if (!resourceKey) return null;
  for (const k in state.buildingTypes) {
    const bt = state.buildingTypes[k];
    if (bt.category !== 'processor') continue;
    if (bt.input_resource_key === resourceKey || bt.input_resource_key_2 === resourceKey) return bt;
  }
  return null;
}
function resName(key) {
  return state.resourceNodes[key]?.name || key;
}
function infoRow(label, value) {
  return `<div class="ip-row"><span class="ip-label">${label}</span><span class="ip-value">${escapeHtml(value)}</span></div>`;
}
function escapeHtml(s) {
  return String(s).replace(/[&<>"]/g, (c) => ({
    '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;'
  }[c]));
}
