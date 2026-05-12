// City > Resources subtab. Inventory + per-minute prod/cons/net for
// every active resource, grouped by category. Each row is clickable
// to expand a "Where it's going" drilldown showing every producer,
// consumer, service input, citizen drain, and NPC trade flow for that
// resource.
//
// Per-partner trade activity table is a follow-up (commit 51) so this
// commit stays focused on the flow breakdown.
import { state } from '../../state/store.js';
import { computeResourceProdCons, computeResourceFlow } from '../../scenes/helpers.js';

const GROUPS = [
  { label: 'Raw materials',     match: (r) => r.kind === 'raw' && !r.is_food },
  { label: 'Raw food',          match: (r) => r.kind === 'raw' && r.is_food },
  { label: 'Processed',         match: (r) => r.kind === 'processed' && !r.is_food && !r.is_luxury_food && !r.is_industrial_luxury },
  { label: 'Cooked food',       match: (r) => r.kind === 'processed' && r.is_food && !r.is_luxury_food },
  { label: 'Industrial luxury', match: (r) => r.is_industrial_luxury },
  { label: 'Luxury food',       match: (r) => r.is_luxury_food }
];

// Module-scope expansion state — persists across panel refreshes so
// the drilldown stays open while the tick loop re-renders.
const expanded = new Set();

export function renderCityResources(parent) {
  const { prod, cons } = computeResourceProdCons(
    state.allBuildings, state.buildingTypes, state.currentUser?.id
  );

  const all = Object.values(state.resourceNodes).filter((r) => r.is_active);
  let html = '';
  for (const group of GROUPS) {
    const rows = all.filter(group.match).sort((a, b) => a.name.localeCompare(b.name));
    if (!rows.length) continue;
    html += `<div class="cr-section">
      <h3 class="cr-section-title">${escapeHtml(group.label)}</h3>
      <div class="cr-table">
        <div class="cr-row cr-row-head">
          <span class="cr-cell cr-cell-name">Resource</span>
          <span class="cr-cell cr-cell-inv">Inv</span>
          <span class="cr-cell cr-num">Prod</span>
          <span class="cr-cell cr-num">Cons</span>
          <span class="cr-cell cr-num">Net</span>
        </div>
        ${rows.map((r) => renderRow(r, prod, cons)).join('')}
      </div>
    </div>`;
  }
  parent.innerHTML = html || '<p class="cr-empty">No active resources.</p>';

  parent.querySelectorAll('.cr-row-data[data-resource]').forEach((row) => {
    row.addEventListener('click', () => {
      const rk = row.dataset.resource;
      if (expanded.has(rk)) expanded.delete(rk);
      else expanded.add(rk);
      renderCityResources(parent);
    });
  });
}

function renderRow(r, prod, cons) {
  const inv = Math.floor(Number(state.inventory?.[r.key] || 0));
  const p = Number(prod[r.key] || 0);
  const c = Number(cons[r.key] || 0);
  const net = p - c;
  const netClass = net > 0.05 ? 'cr-pos' : net < -0.05 ? 'cr-neg' : '';
  const isOpen = expanded.has(r.key);
  const chev = isOpen ? '▾' : '▸';

  return `<div class="cr-row cr-row-data ${isOpen ? 'cr-open' : ''}" data-resource="${escapeHtml(r.key)}">
    <span class="cr-cell cr-cell-name"><span class="cr-chev">${chev}</span>${escapeHtml(r.name)}</span>
    <span class="cr-cell cr-cell-inv">${inv.toLocaleString()}</span>
    <span class="cr-cell cr-num cr-pos">${p > 0 ? '+' + p.toFixed(1) : '—'}</span>
    <span class="cr-cell cr-num cr-neg">${c > 0 ? '−' + c.toFixed(1) : '—'}</span>
    <span class="cr-cell cr-num ${netClass}">${net !== 0 ? (net > 0 ? '+' : '') + net.toFixed(1) : '—'}</span>
  </div>
  ${isOpen ? `<div class="cr-detail">${renderFlowHtml(r.key)}</div>` : ''}`;
}

function renderFlowHtml(resourceKey) {
  const ctx = {
    allBuildings: state.allBuildings,
    buildingTypes: state.buildingTypes,
    resources: state.resourceNodes,
    housingTierConfig: state.housingTierConfig,
    housingLifestyleDemands: state.housingLifestyleDemands,
    inventory: state.inventory,
    tradePolicies: state.tradePolicies,
    traders: state.traders,
    allTraderPrices: state.allTraderPrices
  };
  const flow = computeResourceFlow(resourceKey, ctx, state.currentUser?.id);

  let totalIn = 0;
  for (const p of flow.production) totalIn += p.rate;
  for (const i of flow.imports)    totalIn += i.rate;
  let totalOut = flow.citizens || 0;
  for (const p of flow.processing) totalOut += p.rate;
  for (const s of flow.services)   totalOut += s.rate;
  for (const e of flow.exports)    totalOut += e.rate;

  if (totalIn === 0 && totalOut === 0) {
    return `<div class="cr-flow-empty">No production or consumption right now.</div>`;
  }

  let html = '';
  if (flow.production.length > 0 || flow.imports.length > 0) {
    html += `<div class="cr-flow-section">
      <div class="cr-flow-section-title cr-pos">Producing +${(Math.round(totalIn * 10) / 10).toFixed(1)}/min</div>`;
    for (const p of flow.production) {
      html += `<div class="cr-flow-row">
        <span>${p.count}× ${escapeHtml(p.name)}</span>
        <span class="cr-pos">${fmtRate(p.rate)}</span>
      </div>`;
    }
    for (const i of flow.imports) {
      html += `<div class="cr-flow-row">
        <span>${escapeHtml(i.trader)} <small>(buy-to-reserve @ $${i.price})</small></span>
        <span class="cr-pos">${fmtRate(i.rate)} max</span>
      </div>`;
    }
    html += `</div>`;
  }

  if (totalOut > 0) {
    html += `<div class="cr-flow-section">
      <div class="cr-flow-section-title cr-neg">Consuming −${(Math.round(totalOut * 10) / 10).toFixed(1)}/min</div>`;
    for (const p of flow.processing) {
      const out = p.output ? ' → ' + escapeHtml(p.output) : '';
      html += `<div class="cr-flow-row">
        <span>${p.count}× ${escapeHtml(p.name)}${out}</span>
        <span class="cr-neg">−${(Math.round(p.rate * 10) / 10).toFixed(1)}/min</span>
      </div>`;
    }
    for (const s of flow.services) {
      html += `<div class="cr-flow-row">
        <span>${s.count}× ${escapeHtml(s.name)} <small>(service input)</small></span>
        <span class="cr-neg">−${(Math.round(s.rate * 10) / 10).toFixed(1)}/min</span>
      </div>`;
    }
    if (flow.citizens > 0) {
      html += `<div class="cr-flow-row">
        <span>Citizens <small>(eaten by housing)</small></span>
        <span class="cr-neg">−${(Math.round(flow.citizens * 10) / 10).toFixed(1)}/min</span>
      </div>`;
    }
    for (const e of flow.exports) {
      html += `<div class="cr-flow-row">
        <span>${escapeHtml(e.trader)} <small>(sell-surplus @ $${e.price})</small></span>
        <span class="cr-neg">−${(Math.round(e.rate * 10) / 10).toFixed(1)}/min max</span>
      </div>`;
    }
    html += `</div>`;
  }

  const net = totalIn - totalOut;
  const netClass = net > 0.05 ? 'cr-pos' : net < -0.05 ? 'cr-neg' : '';
  html += `<div class="cr-flow-net">Net: <span class="${netClass}">${fmtRate(net)}</span></div>`;
  return html;
}

function fmtRate(rate) {
  const sign = rate >= 0 ? '+' : '';
  return `${sign}${(Math.round(rate * 10) / 10).toFixed(1)}/min`;
}

function escapeHtml(s) {
  return String(s || '').replace(/[&<>"]/g, (c) => ({
    '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;'
  }[c]));
}
