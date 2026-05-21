// Trade > Contracts subtab. Players pool money into per-(trader,
// resource, direction) supply contracts. When a pool hits its
// threshold, that trader's city-wide daily cap on that resource
// permanently bumps up. Server contract lives in
// city-builder-mvp/migration_patches/trader_supply_contracts.sql.
import { state } from '../../state/store.js';
import { escapeHtml, resName } from '../util.js';
import {
  listSupplyContracts,
  contributeToSupplyContract,
  withdrawFromSupplyContract
} from '../../api/contracts.js';
import { applyRpcResponse } from '../../api/tick.js';

// Module-level expansion state — which trader sections are open. Open
// by default; clicking the header toggles. Doesn't persist.
const collapsed = new Set();

let cachedContracts = null;
let pendingFetch = null;
let cacheFetchedAt = 0;
// Short TTL because contracts are a cooperative artifact — Drew needs
// to see Jill's $50k pledge land within seconds of her making it, not
// after a 30s tick. Bug b67a936c (2026-05-21): Drew's cached view
// stayed pinned at Jill's first $25 pledge for hours after she'd
// pushed it past $60k.
const CACHE_TTL_MS = 5000;

async function loadContracts(parent) {
  if (pendingFetch) return;
  pendingFetch = (async () => {
    try {
      cachedContracts = await listSupplyContracts();
      cacheFetchedAt = Date.now();
      if (parent.isConnected) renderSupplyContracts(parent);
    } finally {
      pendingFetch = null;
    }
  })();
}

export function renderSupplyContracts(parent) {
  const cacheStale = cachedContracts === null
    || (Date.now() - cacheFetchedAt) > CACHE_TTL_MS;
  if (cacheStale && !pendingFetch) {
    if (cachedContracts === null) {
      parent.innerHTML = '<p class="rp-loading">Loading…</p>';
    }
    loadContracts(parent);
    if (cachedContracts === null) return;
    // Otherwise: render the stale data immediately, the refresh
    // re-renders when it lands.
  }

  parent.innerHTML = `
    <div class="sc-intro">
      <p>
        Pool money with other players to permanently raise a trader's
        daily cap on a specific resource. Each bump is one-time and
        +25%; the threshold grows with each bump and with the city's
        population. Pledges are refundable until the pool fills.
      </p>
    </div>
    <div class="sc-new">
      <div class="sc-new-title">Start a new contract</div>
      <div class="sc-new-row">
        <select id="sc-new-trader"></select>
        <select id="sc-new-resource"></select>
        <select id="sc-new-direction">
          <option value="sell">trader sells to us</option>
          <option value="buy">trader buys from us</option>
        </select>
        <input id="sc-new-amount" type="number" placeholder="$ to pledge" min="1" />
        <button class="ip-btn ip-btn-primary" id="sc-new-go">Pledge</button>
      </div>
      <p class="sc-new-status" id="sc-new-status"></p>
    </div>
    <div class="sc-body" id="sc-body">${renderContractList()}</div>
  `;

  populateNewContractDropdowns();
  wireNewContractForm(parent);
  wireContractActions(parent);
}

function renderContractList() {
  if (!cachedContracts.length) {
    return '<p class="rp-empty">No supply contracts yet. Start one above.</p>';
  }
  // Group by trader for readability.
  const byTrader = {};
  for (const c of cachedContracts) {
    if (!byTrader[c.trader_key]) byTrader[c.trader_key] = [];
    byTrader[c.trader_key].push(c);
  }
  return Object.keys(byTrader)
    .sort()
    .map((tk) => renderTraderSection(tk, byTrader[tk]))
    .join('');
}

function renderTraderSection(traderKey, contracts) {
  const traderName = state.traders?.[traderKey]?.name || traderKey;
  const isCollapsed = collapsed.has(traderKey);
  const chev = isCollapsed ? '▸' : '▾';
  return `
    <div class="sc-trader" data-trader="${escapeHtml(traderKey)}">
      <button class="sc-trader-head" data-toggle="${escapeHtml(traderKey)}">
        <span class="sc-chev">${chev}</span>
        ${escapeHtml(traderName)}
        <small class="sc-trader-count">${contracts.length}</small>
      </button>
      ${isCollapsed ? '' : `<div class="sc-trader-body">${contracts.map(renderContractCard).join('')}</div>`}
    </div>
  `;
}

function renderContractCard(c) {
  const rn = resName(c.resource_key);
  const dirLabel = c.direction === 'sell' ? 'sells to us' : 'buys from us';
  const pct = Math.min(100, Math.round((c.pool_money / Math.max(1, c.threshold_money)) * 100));
  const capStr = c.current_cap == null ? '—' : c.current_cap.toLocaleString();
  const bumpStr = c.bumps_funded > 0 ? ` · ${c.bumps_funded} bump${c.bumps_funded === 1 ? '' : 's'} funded` : '';
  const contributors = Array.isArray(c.contributors) ? c.contributors : [];
  const contribList = contributors.length
    ? contributors.map((co) =>
        `<span class="sc-contrib">${escapeHtml(co.display_name || 'Player')} $${co.amount.toLocaleString()}</span>`
      ).join(' · ')
    : '<span class="sc-empty">No pledges yet this round.</span>';
  const withdrawBtn = c.my_pledge > 0
    ? `<button class="ip-btn sc-withdraw" data-id="${c.id}">Withdraw your $${c.my_pledge.toLocaleString()}</button>`
    : '';
  return `
    <div class="sc-card" data-trader="${escapeHtml(c.trader_key)}"
         data-resource="${escapeHtml(c.resource_key)}"
         data-direction="${escapeHtml(c.direction)}">
      <div class="sc-card-head">
        <span class="sc-card-name">${escapeHtml(rn)} <small>(${dirLabel})</small></span>
        <span class="sc-card-cap">cap ${capStr}/day${bumpStr}</span>
      </div>
      <div class="sc-progress" title="$${c.pool_money.toLocaleString()} of $${c.threshold_money.toLocaleString()}">
        <div class="sc-progress-fill" style="width:${pct}%"></div>
        <span class="sc-progress-label">$${c.pool_money.toLocaleString()} / $${c.threshold_money.toLocaleString()}</span>
      </div>
      <div class="sc-contribs">${contribList}</div>
      <div class="sc-actions">
        <input class="sc-amount" type="number" placeholder="$ to pledge" min="1" />
        <button class="ip-btn sc-contribute">Contribute</button>
        ${withdrawBtn}
      </div>
      <p class="sc-card-status"></p>
    </div>
  `;
}

function populateNewContractDropdowns() {
  const traderSel = document.getElementById('sc-new-trader');
  const resSel = document.getElementById('sc-new-resource');
  if (!traderSel || !resSel) return;
  const traders = Object.values(state.traders || {})
    .filter((t) => t.is_active)
    .sort((a, b) => (a.name || a.key).localeCompare(b.name || b.key));
  traderSel.innerHTML = traders
    .map((t) => `<option value="${escapeHtml(t.key)}">${escapeHtml(t.name || t.key)}</option>`)
    .join('');
  const resources = Object.values(state.resourceNodes || {})
    .filter((r) => r.is_active !== false && r.kind !== 'terrain')
    .sort((a, b) => (a.name || a.key).localeCompare(b.name || b.key));
  resSel.innerHTML = resources
    .map((r) => `<option value="${escapeHtml(r.key)}">${escapeHtml(r.name || r.key)}</option>`)
    .join('');
}

function wireNewContractForm(parent) {
  const go = parent.querySelector('#sc-new-go');
  if (!go) return;
  go.addEventListener('click', async () => {
    const traderKey = parent.querySelector('#sc-new-trader').value;
    const resourceKey = parent.querySelector('#sc-new-resource').value;
    const direction = parent.querySelector('#sc-new-direction').value;
    const amount = parseInt(parent.querySelector('#sc-new-amount').value, 10);
    const statusEl = parent.querySelector('#sc-new-status');
    if (!amount || amount <= 0) {
      statusEl.textContent = 'Enter an amount > 0.';
      return;
    }
    await doContribute(traderKey, resourceKey, direction, amount, statusEl, parent);
  });
}

function wireContractActions(parent) {
  parent.querySelectorAll('.sc-trader-head').forEach((btn) => {
    btn.addEventListener('click', () => {
      const k = btn.dataset.toggle;
      if (collapsed.has(k)) collapsed.delete(k);
      else collapsed.add(k);
      renderSupplyContracts(parent);
    });
  });
  parent.querySelectorAll('.sc-contribute').forEach((btn) => {
    btn.addEventListener('click', async () => {
      const card = btn.closest('.sc-card');
      const traderKey = card.dataset.trader;
      const resourceKey = card.dataset.resource;
      const direction = card.dataset.direction;
      const amount = parseInt(card.querySelector('.sc-amount').value, 10);
      const statusEl = card.querySelector('.sc-card-status');
      if (!amount || amount <= 0) {
        statusEl.textContent = 'Enter an amount > 0.';
        return;
      }
      await doContribute(traderKey, resourceKey, direction, amount, statusEl, parent);
    });
  });
  parent.querySelectorAll('.sc-withdraw').forEach((btn) => {
    btn.addEventListener('click', async () => {
      const id = btn.dataset.id;
      const card = btn.closest('.sc-card');
      const statusEl = card.querySelector('.sc-card-status');
      btn.disabled = true;
      try {
        const res = await withdrawFromSupplyContract(id);
        applyRpcResponse({ money: res.money });
        statusEl.textContent = `✓ Refunded $${res.refunded.toLocaleString()}.`;
        cachedContracts = null;
        setTimeout(() => renderSupplyContracts(parent), 600);
      } catch (err) {
        statusEl.textContent = 'Withdraw failed: ' + (err.message || err);
        btn.disabled = false;
      }
    });
  });
}

async function doContribute(traderKey, resourceKey, direction, amount, statusEl, parent) {
  statusEl.textContent = '';
  try {
    const res = await contributeToSupplyContract(traderKey, resourceKey, direction, amount);
    applyRpcResponse({ money: res.money });
    if (res.settled) {
      statusEl.textContent = `✓ Bump #${(res.new_cap != null && res.old_cap != null) ? '' : ''} landed — cap rose from ${res.old_cap?.toLocaleString() || '0'} to ${res.new_cap?.toLocaleString() || '?'}/day.`;
    } else {
      statusEl.textContent = `✓ Pledged $${amount.toLocaleString()}. Pool now $${res.pool_money.toLocaleString()} / $${res.threshold_money.toLocaleString()}.`;
    }
    cachedContracts = null;
    setTimeout(() => renderSupplyContracts(parent), 600);
  } catch (err) {
    statusEl.textContent = 'Pledge failed: ' + (err.message || err);
  }
}

// Stale-cache invalidation: external code can call this if it knows
// the contracts list might have changed (e.g., after a bell-log
// notification of a bump). Not currently wired, but exported so the
// tick layer can hook it later.
export function invalidateContractsCache() {
  cachedContracts = null;
}
