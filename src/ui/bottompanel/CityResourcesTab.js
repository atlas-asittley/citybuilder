// City > Resources subtab. Same content as the standalone
// CityResourcesPanel modal, just rendered into a passed-in container
// instead of mounting an overlay. Inventory + per-minute prod / cons
// / net for every active resource.
import { state } from '../../state/store.js';

const GROUPS = [
  { label: 'Raw materials', match: (r) => r.kind === 'raw' && !r.is_food },
  { label: 'Raw food',      match: (r) => r.kind === 'raw' && r.is_food },
  { label: 'Processed',     match: (r) => r.kind === 'processed' && !r.is_food && !r.is_luxury_food && !r.is_industrial_luxury },
  { label: 'Cooked food',   match: (r) => r.kind === 'processed' && r.is_food && !r.is_luxury_food },
  { label: 'Industrial luxury', match: (r) => r.is_industrial_luxury },
  { label: 'Luxury food',   match: (r) => r.is_luxury_food }
];

export function renderCityResources(parent) {
  const myId = state.currentUser?.id;
  const prod = {};
  const cons = {};
  for (const b of state.allBuildings) {
    if (b.player_id !== myId) continue;
    if (b.status !== 'active' || !b.is_staffed || b.paused) continue;
    const bt = state.buildingTypes[b.building_type_key];
    if (!bt) continue;
    if (bt.output_resource_key && bt.output_rate > 0 && bt.category !== 'tax') {
      prod[bt.output_resource_key] = (prod[bt.output_resource_key] || 0) + Number(bt.output_rate);
    }
    if (bt.input_resource_key && bt.input_rate > 0) {
      cons[bt.input_resource_key] = (cons[bt.input_resource_key] || 0) + Number(bt.input_rate);
    }
    if (bt.input_resource_key_2 && bt.input_rate_2 > 0) {
      cons[bt.input_resource_key_2] = (cons[bt.input_resource_key_2] || 0) + Number(bt.input_rate_2);
    }
  }

  const all = Object.values(state.resourceNodes).filter((r) => r.is_active);
  let html = '';
  for (const group of GROUPS) {
    const rows = all.filter(group.match).sort((a, b) => a.name.localeCompare(b.name));
    if (!rows.length) continue;
    html += `<div class="cr-section">
      <h3 class="cr-section-title">${group.label}</h3>
      <div class="cr-table">
        <div class="cr-row cr-row-head">
          <span>Resource</span><span>Inv</span>
          <span class="cr-num">Prod</span><span class="cr-num">Cons</span><span class="cr-num">Net</span>
        </div>
        ${rows.map((r) => {
          const inv = Math.floor(state.inventory[r.key] || 0);
          const p = prod[r.key] || 0;
          const c = cons[r.key] || 0;
          const net = p - c;
          const netClass = net > 0 ? 'cr-pos' : net < 0 ? 'cr-neg' : '';
          return `<div class="cr-row">
            <span class="cr-name">${r.name}</span>
            <span>${inv.toLocaleString()}</span>
            <span class="cr-num cr-pos">${p > 0 ? '+' + p.toFixed(1) : '—'}</span>
            <span class="cr-num cr-neg">${c > 0 ? '−' + c.toFixed(1) : '—'}</span>
            <span class="cr-num ${netClass}">${net !== 0 ? (net > 0 ? '+' : '') + net.toFixed(1) : '—'}</span>
          </div>`;
        }).join('')}
      </div>
    </div>`;
  }
  parent.innerHTML = html || '<p class="cr-empty">No active resources.</p>';
}
