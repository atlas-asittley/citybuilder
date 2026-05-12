// City > Resources subtab. Inventory + per-minute prod/cons/net for
// every active resource, grouped by category. Each row is clickable
// to expand a "Where it's going" drilldown showing every producer,
// consumer, service input, citizen drain, and NPC trade flow for that
// resource.
//
// Per-partner trade activity table is a follow-up (commit 51) so this
// commit stays focused on the flow breakdown.
import { state } from '../../state/store.js';
import { sb, fetchAllPaged } from '../../api/supabase.js';
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

// Category collapse state — persisted to localStorage so the user's
// preference survives reloads. Default: every category open.
const COLLAPSE_KEY = 'city_resources_collapsed_v2';
const collapsed = new Set(loadCollapsed());
function loadCollapsed() {
  try {
    const raw = localStorage.getItem(COLLAPSE_KEY);
    if (!raw) return [];
    return JSON.parse(raw) || [];
  } catch (_e) { return []; }
}
function persistCollapsed() {
  try { localStorage.setItem(COLLAPSE_KEY, JSON.stringify([...collapsed])); } catch (_e) { /* no-op */ }
}

// Search filter — prefix-match on resource name. Cleared between
// mounts to avoid stale state; not persisted, since this is an
// in-the-moment "find pottery" affordance.
let filterText = '';

// Cached per-partner trade flows for the trailing 7 days. Async-loaded
// on first render; re-fetched after CACHE_MS. The drilldown renders
// the per-partner table from `cachedFlows.byPartner` when available,
// silently skipping it otherwise (so the flow-breakdown stays useful
// even before trade data arrives).
let cachedFlows = null;
let cacheFetchedAt = 0;
let pendingFlowsFetch = null;
const CACHE_MS = 60 * 1000;

function loadTradeFlows(parent) {
  const now = Date.now();
  if (cachedFlows && now - cacheFetchedAt < CACHE_MS) return;
  if (pendingFlowsFetch) return;
  const uid = state.currentUser?.id;
  if (!uid) return;
  const since = new Date(now - 7 * 24 * 60 * 60 * 1000).toISOString();
  pendingFlowsFetch = (async () => {
    try {
      const [tx, offers] = await Promise.all([
        fetchAllPaged(() => sb.from('trade_transactions')
          .select('*').eq('player_id', uid).gte('created_at', since)
          .order('created_at', { ascending: false })),
        fetchAllPaged(() => sb.from('player_trade_offers')
          .select('*').eq('status', 'accepted').gte('resolved_at', since)
          .or(`from_player_id.eq.${uid},to_player_id.eq.${uid}`)
          .order('resolved_at', { ascending: false }))
      ]);
      const ids = new Set();
      for (const o of offers) {
        if (o.from_player_id && o.from_player_id !== uid) ids.add(o.from_player_id);
        if (o.to_player_id && o.to_player_id !== uid) ids.add(o.to_player_id);
      }
      let nameMap = {};
      if (ids.size > 0) {
        const { data } = await sb.from('player_profiles')
          .select('id, display_name').in('id', Array.from(ids));
        for (const p of (data || [])) nameMap[p.id] = p.display_name;
      }
      cachedFlows = aggregateTradeFlows(uid, tx, offers, nameMap);
      cacheFetchedAt = Date.now();
      // Re-render so the drilldown picks up the new data.
      if (parent && parent.isConnected) renderCityResources(parent);
    } catch (_e) {
      // Trade flow fetch failed — leave cachedFlows alone so the
      // drilldown stays usable; just no per-partner table.
    } finally {
      pendingFlowsFetch = null;
    }
  })();
}

// Roll up trade_transactions (NPC) + accepted player_trade_offers
// (P2P) into per-resource per-partner buckets. Each partner entry
// carries export_qty/export_money + import_qty/import_money so the
// table can show "you sent N (+$M)" / "you got N (-$M)" side by side.
function aggregateTradeFlows(uid, transactions, offers, nameMap) {
  const byPartner = {};

  const bump = (rk, partnerKey, name, kind, playerId, dir, qty, money) => {
    if (!byPartner[rk]) byPartner[rk] = [];
    let entry = byPartner[rk].find((p) => p.partnerKey === partnerKey);
    if (!entry) {
      entry = { partnerKey, name, kind, player_id: playerId,
        export_qty: 0, export_money: 0, import_qty: 0, import_money: 0 };
      byPartner[rk].push(entry);
    }
    if (dir === 'export') { entry.export_qty += qty; entry.export_money += money; }
    else                  { entry.import_qty += qty; entry.import_money += money; }
  };

  for (const t of transactions) {
    const dir = t.transaction_type === 'sell' ? 'export' : 'import';
    const traderName = state.traders?.[t.trader_key]?.name || t.trader_key;
    bump(t.resource_key, t.trader_key, traderName, 'npc', null, dir,
      Number(t.quantity || 0), Number(t.total_price || 0));
  }

  for (const o of offers) {
    const iAmSender = o.from_player_id === uid;
    const otherId = iAmSender ? o.to_player_id : o.from_player_id;
    const partnerKey = 'player:' + otherId;
    const partnerName = nameMap[otherId] || 'Player';
    const giveRes = o.give_resources || {};
    const recvRes = o.receive_resources || {};
    const myExports = iAmSender ? giveRes : recvRes;
    const myImports = iAmSender ? recvRes : giveRes;
    for (const rk in myExports) {
      const qty = parseInt(myExports[rk], 10) || 0;
      if (qty > 0) bump(rk, partnerKey, partnerName, 'player', otherId, 'export', qty, 0);
    }
    for (const rk in myImports) {
      const qty = parseInt(myImports[rk], 10) || 0;
      if (qty > 0) bump(rk, partnerKey, partnerName, 'player', otherId, 'import', qty, 0);
    }
  }

  return { byPartner };
}

export function renderCityResources(parent) {
  // Kick off the trade-flow fetch in the background — first render
  // misses it, second render after fetch lands picks it up.
  loadTradeFlows(parent);

  const { prod, cons } = computeResourceProdCons(
    state.allBuildings, state.buildingTypes, state.currentUser?.id
  );

  const all = Object.values(state.resourceNodes).filter((r) => r.is_active);
  const lowFilter = filterText.trim().toLowerCase();
  let html = `
    <div class="cr-filter-row">
      <input type="search" class="cr-filter" placeholder="Filter resources…" value="${escapeHtml(filterText)}" />
    </div>
  `;
  for (const group of GROUPS) {
    let rows = all.filter(group.match).sort((a, b) => a.name.localeCompare(b.name));
    if (lowFilter) rows = rows.filter((r) => r.name.toLowerCase().includes(lowFilter));
    if (!rows.length) continue;
    const isCollapsed = collapsed.has(group.label);
    const totalStock = rows.reduce((s, r) => s + Math.floor(Number(state.inventory?.[r.key] || 0)), 0);
    html += `<div class="cr-section ${isCollapsed ? 'cr-collapsed' : ''}" data-group="${escapeHtml(group.label)}">
      <h3 class="cr-section-title cr-section-toggle">
        <span class="cr-section-chev">${isCollapsed ? '▸' : '▾'}</span>
        ${escapeHtml(group.label)}
        <small class="cr-section-summary">${rows.length} · ${totalStock.toLocaleString()} total</small>
      </h3>
      ${isCollapsed ? '' : `<div class="cr-table">
        <div class="cr-row cr-row-head">
          <span class="cr-cell cr-cell-name">Resource</span>
          <span class="cr-cell cr-cell-inv">Inv</span>
          <span class="cr-cell cr-num">Prod</span>
          <span class="cr-cell cr-num">Cons</span>
          <span class="cr-cell cr-num">Net</span>
        </div>
        ${rows.map((r) => renderRow(r, prod, cons)).join('')}
      </div>`}
    </div>`;
  }
  parent.innerHTML = html || '<p class="cr-empty">No active resources.</p>';

  // Filter input
  const filterEl = parent.querySelector('.cr-filter');
  if (filterEl) {
    filterEl.addEventListener('input', (e) => {
      filterText = e.target.value || '';
      renderCityResources(parent);
      // Re-focus the input + restore caret position after re-render.
      const fresh = parent.querySelector('.cr-filter');
      if (fresh) {
        fresh.focus();
        fresh.setSelectionRange(filterText.length, filterText.length);
      }
    });
  }

  // Category collapse toggles
  parent.querySelectorAll('.cr-section-toggle').forEach((header) => {
    header.addEventListener('click', () => {
      const label = header.parentElement.dataset.group;
      if (collapsed.has(label)) collapsed.delete(label);
      else collapsed.add(label);
      persistCollapsed();
      renderCityResources(parent);
    });
  });

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

  // Per-partner trade activity (last 7 days). Renders only when the
  // flow data has been fetched; silently skipped pre-load.
  html += renderPartnerTable(resourceKey);
  return html;
}

function renderPartnerTable(resourceKey) {
  if (!cachedFlows) return '';
  const partners = (cachedFlows.byPartner[resourceKey] || []).slice();
  partners.sort((a, b) => (b.export_qty + b.import_qty) - (a.export_qty + a.import_qty));
  if (partners.length === 0) {
    return `<div class="cr-partner-empty">No trade activity for this resource in the last 7 days.</div>`;
  }
  const rows = partners.map((p) => {
    const sent = p.export_qty > 0
      ? `${p.export_qty}${p.export_money ? ' (+$' + Math.round(p.export_money) + ')' : ''}`
      : '—';
    const got = p.import_qty > 0
      ? `${p.import_qty}${p.import_money ? ' (−$' + Math.round(p.import_money) + ')' : ''}`
      : '—';
    return `<div class="cr-partner-row">
      <span class="cr-partner-name">${escapeHtml(p.name)}<small class="cr-partner-kind">${p.kind}</small></span>
      <span class="cr-pos">${escapeHtml(sent)}</span>
      <span class="cr-neg">${escapeHtml(got)}</span>
    </div>`;
  }).join('');
  return `<div class="cr-partners">
    <div class="cr-partners-title">Recent trade activity (7d)</div>
    <div class="cr-partner-row cr-partner-head">
      <span>Partner</span><span>You sent</span><span>You got</span>
    </div>
    ${rows}
  </div>`;
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
