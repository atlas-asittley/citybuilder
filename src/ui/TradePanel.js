// Trade panel — two tabs:
//
//   Partners: per-resource trade policy editor. Each row shows the
//             traders that buy or sell this resource + their prices,
//             plus controls for your auto-trade policy (mode, reserve
//             target, optional min/max price gates). The server-side
//             auto-trader fires every tick and matches policies
//             against trader prices — these controls are how you
//             tell it what to do.
//
//   Black market: always-available 35%/200% emergency buy/sell.
//                 Same surface as before this rewrite; bypasses the
//                 policy system entirely (you click, you commit).
//
// Procedural traders feed in here through state.traders +
// state.allTraderPrices, populated by loader.js. v1 had a richer
// version with "best deals" banner, unlock states, visit cadence —
// deferring those polish items for the first cut.
import { sb } from '../api/supabase.js';
import { state } from '../state/store.js';

let mounted = false;
let activeTab = 'partners';

const RESOURCE_GROUPS = [
  { label: 'Raw materials', match: (r) => r.kind === 'raw' && !r.is_food },
  { label: 'Raw food',      match: (r) => r.kind === 'raw' && r.is_food },
  { label: 'Processed',     match: (r) => r.kind === 'processed' && !r.is_food && !r.is_luxury_food && !r.is_industrial_luxury },
  { label: 'Cooked food',   match: (r) => r.kind === 'processed' && r.is_food && !r.is_luxury_food },
  { label: 'Industrial luxury', match: (r) => r.is_industrial_luxury },
  { label: 'Luxury food',   match: (r) => r.is_luxury_food }
];

export function openTrade() {
  if (mounted) return;
  mounted = true;

  const root = document.getElementById('ui-root');
  const overlay = document.createElement('div');
  overlay.id = 'trade-overlay';
  overlay.innerHTML = `
    <div class="tp-card tp-card-wide">
      <div class="tp-header">
        <div class="tp-tabs">
          <button class="tp-tab ${activeTab === 'partners' ? 'active' : ''}" data-tab="partners">Partners</button>
          <button class="tp-tab ${activeTab === 'blackmarket' ? 'active' : ''}" data-tab="blackmarket">Black Market</button>
        </div>
        <button class="tp-close" aria-label="Close">×</button>
      </div>
      <div class="tp-body" id="tp-body"></div>
    </div>
  `;
  root.appendChild(overlay);

  const close = () => {
    overlay.remove();
    mounted = false;
  };
  overlay.querySelector('.tp-close').addEventListener('click', close);
  overlay.addEventListener('click', (e) => {
    if (e.target === overlay) close();
  });

  overlay.querySelectorAll('.tp-tab').forEach((btn) => {
    btn.addEventListener('click', () => {
      activeTab = btn.dataset.tab;
      overlay.querySelectorAll('.tp-tab').forEach((t) =>
        t.classList.toggle('active', t === btn));
      renderBody();
    });
  });

  renderBody();
}

function renderBody() {
  if (activeTab === 'partners') renderPartners();
  else renderBlackMarket();
}

// ── Partners tab ──

function renderPartners() {
  const body = document.getElementById('tp-body');
  if (!body) return;

  const traderKeys = Object.keys(state.traders || {});
  if (traderKeys.length === 0) {
    body.innerHTML = `
      <p class="tp-empty">
        No trade partners yet. Build a transport hub (truck depot, train depot, seaport, airport)
        to unlock procedural traders.
      </p>`;
    return;
  }

  // Pivot: for each resource, which traders deal in it, at what prices.
  const resourceTraders = {};   // resource_key → [{trader_key, side, price, cap}]
  for (const tk of traderKeys) {
    const prices = state.allTraderPrices[tk] || {};
    for (const rk in prices) {
      const p = prices[rk];
      if (!resourceTraders[rk]) resourceTraders[rk] = [];
      if (p.buy_price)  resourceTraders[rk].push({ tk, side: 'buys',  price: p.buy_price,  cap: p.daily_buy_cap });
      if (p.sell_price) resourceTraders[rk].push({ tk, side: 'sells', price: p.sell_price, cap: p.daily_sell_cap });
    }
  }

  // Render in group order so related resources cluster.
  let html = `
    <p class="tp-hint">
      Auto-trading runs every production tick. Set a policy per resource
      to tell the auto-trader what to do.
    </p>`;

  const allResources = Object.values(state.resourceNodes).filter((r) => r.is_active);
  for (const group of RESOURCE_GROUPS) {
    const rows = allResources
      .filter(group.match)
      .filter((r) => resourceTraders[r.key])
      .sort((a, b) => a.name.localeCompare(b.name));
    if (!rows.length) continue;
    html += `<div class="tp-section">
      <h3 class="tp-section-title">${group.label}</h3>
      ${rows.map((r) => renderPartnerResourceRow(r, resourceTraders[r.key])).join('')}
    </div>`;
  }

  body.innerHTML = html;
  wirePolicyHandlers(body);
}

function renderPartnerResourceRow(resource, traderRows) {
  const policy = state.tradePolicies[resource.key] || { mode: 'hold' };
  const inv = Math.floor(state.inventory[resource.key] || 0);
  const buyers  = traderRows.filter((t) => t.side === 'buys');
  const sellers = traderRows.filter((t) => t.side === 'sells');

  const bestBuy  = buyers.length  ? Math.max(...buyers.map((t) => t.price))  : null;
  const bestSell = sellers.length ? Math.min(...sellers.map((t) => t.price)) : null;

  return `
    <div class="tp-resource" data-resource="${resource.key}">
      <div class="tp-resource-head">
        <span class="tp-resource-name">${resource.name}</span>
        <span class="tp-resource-meta">
          have ${inv}
          ${bestBuy  !== null ? ` · top buy $${bestBuy}` : ''}
          ${bestSell !== null ? ` · low sell $${bestSell}` : ''}
        </span>
      </div>
      <div class="tp-policy-row">
        <select class="tp-policy-mode" data-resource="${resource.key}">
          <option value="hold"          ${policy.mode === 'hold' ? 'selected' : ''}>Hold</option>
          <option value="sell_surplus"  ${policy.mode === 'sell_surplus' ? 'selected' : ''}>Sell surplus</option>
          <option value="buy_to_reserve"${policy.mode === 'buy_to_reserve' ? 'selected' : ''}>Buy to reserve</option>
        </select>
        <label class="tp-policy-field">
          reserve
          <input class="tp-policy-reserve" type="number" min="0" max="9999"
                 value="${policy.reserve_target || 0}" data-resource="${resource.key}" />
        </label>
        <label class="tp-policy-field">
          min sell
          <input class="tp-policy-minsell" type="number" min="1" max="9999"
                 placeholder="any"
                 value="${policy.min_sell_price || ''}" data-resource="${resource.key}" />
        </label>
        <label class="tp-policy-field">
          max buy
          <input class="tp-policy-maxbuy" type="number" min="1" max="9999"
                 placeholder="any"
                 value="${policy.max_buy_price || ''}" data-resource="${resource.key}" />
        </label>
        <button class="tp-policy-save" data-resource="${resource.key}">Save</button>
      </div>
      <div class="tp-trader-list">
        ${traderRows.sort((a, b) => b.price - a.price).map((t) => `
          <div class="tp-trader-row tp-trader-${t.side}">
            <span class="tp-trader-name">${escapeHtml(state.traders[t.tk]?.name || t.tk)}</span>
            <span class="tp-trader-side">${t.side}</span>
            <span class="tp-trader-price">$${t.price}</span>
            <span class="tp-trader-cap">${t.cap ? '/day ' + t.cap : ''}</span>
          </div>
        `).join('')}
      </div>
    </div>
  `;
}

function wirePolicyHandlers(root) {
  root.querySelectorAll('.tp-policy-save').forEach((btn) => {
    btn.addEventListener('click', async () => {
      const rk = btn.dataset.resource;
      const row = root.querySelector(`.tp-resource[data-resource="${rk}"]`);
      const mode = row.querySelector('.tp-policy-mode').value;
      const reserve = parseInt(row.querySelector('.tp-policy-reserve').value, 10) || 0;
      const minSellRaw = row.querySelector('.tp-policy-minsell').value;
      const maxBuyRaw  = row.querySelector('.tp-policy-maxbuy').value;
      const minSell = minSellRaw === '' ? null : parseInt(minSellRaw, 10);
      const maxBuy  = maxBuyRaw  === '' ? null : parseInt(maxBuyRaw,  10);

      btn.disabled = true;
      btn.textContent = 'Saving…';
      try {
        const { error } = await sb.rpc('save_trade_policy', {
          p_resource_key: rk,
          p_mode: mode,
          p_reserve_target: reserve,
          p_min_sell_price: minSell,
          p_max_buy_price: maxBuy
        });
        if (error) throw error;
        state.tradePolicies[rk] = {
          mode, reserve_target: reserve,
          min_sell_price: minSell, max_buy_price: maxBuy
        };
        btn.textContent = 'Saved';
        setTimeout(() => { btn.disabled = false; btn.textContent = 'Save'; }, 1200);
      } catch (err) {
        alert('Policy save failed: ' + (err.message || err));
        btn.disabled = false;
        btn.textContent = 'Save';
      }
    });
  });
}

// ── Black market tab (unchanged in shape, slightly smaller after the
//   refactor — the buttons and prompts are the same flow as before). ──

function renderBlackMarket() {
  const body = document.getElementById('tp-body');
  if (!body) return;
  const resources = Object.values(state.resourceNodes)
    .filter((r) => r.is_active && r.base_price);

  let html = `
    <p class="tp-warning">
      Sell anything at <strong>35%</strong> of fair value, or buy at <strong>200%</strong>.
      The emergency option — there's no better rate, but it's always open.
    </p>`;
  for (const group of RESOURCE_GROUPS) {
    const items = resources.filter(group.match).sort((a, b) => a.base_price - b.base_price);
    if (!items.length) continue;
    html += `<div class="tp-section">
      <h3 class="tp-section-title">${group.label}</h3>
      <div class="tp-rows">`;
    for (const r of items) {
      const inv = Math.floor(state.inventory[r.key] || 0);
      const sellPrice = Math.max(1, Math.floor(r.base_price * 0.35));
      const buyPrice  = Math.max(1, Math.ceil(r.base_price * 2.0));
      html += `<div class="tp-row">
        <div class="tp-row-name">${r.name}<small>have ${inv}</small></div>
        <div class="tp-row-actions">
          <button class="tp-btn tp-btn-sell" data-act="sell" data-key="${r.key}" data-price="${sellPrice}" ${inv > 0 ? '' : 'disabled'}>Sell @ $${sellPrice}</button>
          <button class="tp-btn tp-btn-buy"  data-act="buy"  data-key="${r.key}" data-price="${buyPrice}">Buy @ $${buyPrice}</button>
        </div>
      </div>`;
    }
    html += '</div></div>';
  }
  body.innerHTML = html;

  body.querySelectorAll('.tp-btn').forEach((btn) => {
    btn.addEventListener('click', async () => {
      const act = btn.dataset.act;
      const key = btn.dataset.key;
      const price = Number(btn.dataset.price);
      const owned = Math.floor(state.inventory[key] || 0);
      const max = act === 'buy' ? Math.floor((state.profile?.money || 0) / price) : owned;

      const qtyStr = prompt(`${act === 'sell' ? 'Sell' : 'Buy'} how many ${key} at $${price} each? (max ${max})`);
      if (!qtyStr) return;
      const qty = parseInt(qtyStr, 10);
      if (!Number.isFinite(qty) || qty <= 0) { alert('Enter a positive number.'); return; }

      btn.disabled = true;
      try {
        const { data, error } = await sb.rpc('black_market_trade', {
          p_resource_key: key,
          p_quantity: qty,
          p_direction: act
        });
        if (error) throw error;
        if (data?.money !== undefined) state.profile.money = data.money;
        if (data?.inventory) {
          state.inventory = {};
          for (const k in data.inventory) state.inventory[k] = Number(data.inventory[k]);
        }
        renderBlackMarket();
      } catch (err) {
        alert((act === 'sell' ? 'Sell' : 'Buy') + ' failed: ' + (err.message || err));
        btn.disabled = false;
      }
    });
  });
}

function escapeHtml(s) {
  return String(s).replace(/[&<>"]/g, (c) => ({
    '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;'
  }[c]));
}
