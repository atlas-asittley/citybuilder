// City > Resources panel — inventory + per-minute production /
// consumption / net for every active resource. v1 has this as a
// subtab inside the City tab of the bottom panel; v2 surfaces it
// as a standalone modal opened from the More menu.
import { state } from '../state/store.js';

let mounted = false;

const GROUPS = [
  { label: 'Raw materials', match: (r) => r.kind === 'raw' && !r.is_food },
  { label: 'Raw food',      match: (r) => r.kind === 'raw' && r.is_food },
  { label: 'Processed',     match: (r) => r.kind === 'processed' && !r.is_food && !r.is_luxury_food && !r.is_industrial_luxury },
  { label: 'Cooked food',   match: (r) => r.kind === 'processed' && r.is_food && !r.is_luxury_food },
  { label: 'Industrial luxury', match: (r) => r.is_industrial_luxury },
  { label: 'Luxury food',   match: (r) => r.is_luxury_food }
];

export function openCityResources() {
  if (mounted) return;
  mounted = true;

  const root = document.getElementById('ui-root');
  const overlay = document.createElement('div');
  overlay.id = 'city-res-overlay';
  overlay.innerHTML = `
    <div class="cr-card">
      <div class="cr-header">
        <h2>City resources</h2>
        <button class="cr-close" aria-label="Close">×</button>
      </div>
      <p class="cr-hint">
        Inventory + per-minute production / consumption from your staffed,
        active buildings. Numbers below already exclude unstaffed and
        paused buildings.
      </p>
      <div class="cr-body" id="cr-body"></div>
    </div>
  `;
  root.appendChild(overlay);

  const close = () => { overlay.remove(); mounted = false; };
  overlay.querySelector('.cr-close').addEventListener('click', close);
  overlay.addEventListener('click', (e) => { if (e.target === overlay) close(); });

  render();
}

function render() {
  const body = document.getElementById('cr-body');
  if (!body) return;

  // Compute per-resource production / consumption from the active
  // staffed unpaused buildings the player owns. Building i/o rates
  // are per-minute; recipes with cycle periods would need scaling
  // (deferred — v1's reports.js handles that detail).
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
          <span>Resource</span>
          <span>Inventory</span>
          <span class="cr-num">Prod</span>
          <span class="cr-num">Cons</span>
          <span class="cr-num">Net</span>
        </div>
        ${rows.map((r) => {
          const inv = Math.floor(state.inventory[r.key] || 0);
          const p = prod[r.key] || 0;
          const c = cons[r.key] || 0;
          const net = p - c;
          const netClass = net > 0 ? 'cr-pos' : net < 0 ? 'cr-neg' : '';
          return `<div class="cr-row">
            <span class="cr-name">${escapeHtml(r.name)}</span>
            <span>${inv.toLocaleString()}</span>
            <span class="cr-num cr-pos">${p > 0 ? '+' + p.toFixed(1) : '—'}</span>
            <span class="cr-num cr-neg">${c > 0 ? '−' + c.toFixed(1) : '—'}</span>
            <span class="cr-num ${netClass}">${net !== 0 ? (net > 0 ? '+' : '') + net.toFixed(1) : '—'}</span>
          </div>`;
        }).join('')}
      </div>
    </div>`;
  }
  body.innerHTML = html || '<p class="cr-empty">No active resources.</p>';
}

function escapeHtml(s) {
  return String(s || '').replace(/[&<>"]/g, (c) => ({
    '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;'
  }[c]));
}
