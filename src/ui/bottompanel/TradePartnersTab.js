// Trade > Partners subtab. Renders the partner cards + per-resource
// trade-policy editor into a passed-in container. Same auto-trader
// mechanics as before; this is just the v1-style placement inside
// the bottom panel rather than a modal overlay.
import { sb } from '../../api/supabase.js';
import { state } from '../../state/store.js';

const RESOURCE_GROUPS = [
  { label: 'Raw materials', match: (r) => r.kind === 'raw' && !r.is_food },
  { label: 'Raw food',      match: (r) => r.kind === 'raw' && r.is_food },
  { label: 'Processed',     match: (r) => r.kind === 'processed' && !r.is_food && !r.is_luxury_food && !r.is_industrial_luxury },
  { label: 'Cooked food',   match: (r) => r.kind === 'processed' && r.is_food && !r.is_luxury_food },
  { label: 'Industrial luxury', match: (r) => r.is_industrial_luxury },
  { label: 'Luxury food',   match: (r) => r.is_luxury_food }
];

export function renderTradePartners(parent) {
  const traderKeys = Object.keys(state.traders || {});
  if (!traderKeys.length) {
    parent.innerHTML = `
      <p class="tp-empty">
        No trade partners yet. Build a transport hub (truck depot, train depot,
        seaport, airport) to unlock procedural traders.
      </p>`;
    return;
  }

  const resourceTraders = {};
  for (const tk of traderKeys) {
    const prices = state.allTraderPrices[tk] || {};
    for (const rk in prices) {
      const p = prices[rk];
      if (!resourceTraders[rk]) resourceTraders[rk] = [];
      if (p.buy_price) resourceTraders[rk].push({ tk, side: 'buys', price: p.buy_price, cap: p.daily_buy_cap });
      if (p.sell_price) resourceTraders[rk].push({ tk, side: 'sells', price: p.sell_price, cap: p.daily_sell_cap });
    }
  }

  const bestDeals = computeBestDeals(resourceTraders);
  const allResources = Object.values(state.resourceNodes).filter((r) => r.is_active);

  let html = `
    <p class="tp-hint">
      <strong style="color:#16c79a;">Auto-trading runs every production tick.</strong>
      Set a policy per resource to tell the auto-trader what to do.
    </p>
    ${bestDeals.length ? `
      <div class="tp-best-deals">
        <h3 class="tp-section-title">Best deals matching your policies</h3>
        ${bestDeals.map((d) => `
          <div class="tp-best-row">
            <span>${escapeHtml(d.resourceName)}</span>
            <span class="tp-best-side ${d.side === 'sell' ? 'tp-best-sell' : 'tp-best-buy'}">${d.side === 'sell' ? 'sells to' : 'buys from'} ${escapeHtml(d.traderName)}</span>
            <span class="tp-best-price">$${d.price}</span>
          </div>`).join('')}
      </div>` : ''}`;

  for (const group of RESOURCE_GROUPS) {
    const rows = allResources
      .filter(group.match)
      .filter((r) => resourceTraders[r.key])
      .sort((a, b) => a.name.localeCompare(b.name));
    if (!rows.length) continue;
    html += `<div class="tp-section">
      <h3 class="tp-section-title">${group.label}</h3>
      ${rows.map((r) => renderResourceRow(r, resourceTraders[r.key])).join('')}
    </div>`;
  }
  html += `<div class="tp-locked-hint">
    🔒 New trade partners appear as you build and expand transport hubs.
  </div>`;
  parent.innerHTML = html;
  wirePolicyHandlers(parent);
}

function renderResourceRow(resource, traderRows) {
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
          <option value="hold"           ${policy.mode === 'hold' ? 'selected' : ''}>Hold</option>
          <option value="sell_surplus"   ${policy.mode === 'sell_surplus' ? 'selected' : ''}>Sell surplus</option>
          <option value="buy_to_reserve" ${policy.mode === 'buy_to_reserve' ? 'selected' : ''}>Buy to reserve</option>
        </select>
        <label class="tp-policy-field">reserve<input class="tp-policy-reserve" type="number" min="0" max="9999" value="${policy.reserve_target || 0}" data-resource="${resource.key}"/></label>
        <label class="tp-policy-field">min sell<input class="tp-policy-minsell" type="number" min="1" max="9999" placeholder="any" value="${policy.min_sell_price || ''}" data-resource="${resource.key}"/></label>
        <label class="tp-policy-field">max buy<input class="tp-policy-maxbuy" type="number" min="1" max="9999" placeholder="any" value="${policy.max_buy_price || ''}" data-resource="${resource.key}"/></label>
        <button class="tp-policy-save" data-resource="${resource.key}">Save</button>
      </div>
      <div class="tp-trader-list">
        ${traderRows.sort((a, b) => b.price - a.price).map((t) => renderTraderRow(t, resource.key, policy)).join('')}
      </div>
    </div>`;
}

// Render one trader-row inside a resource group. Adds gate-meets /
// gate-misses class when the player has set a price gate that this
// trader's price would qualify or fail. Surfaces today's daily-cap
// usage ("5/10 today") instead of just the cap.
function renderTraderRow(t, resourceKey, policy) {
  const quota = state.traderQuotas?.[t.tk]?.[resourceKey];
  let used = null, capLabel = '';
  if (t.side === 'buys') {
    used = quota?.buy_used;
    if (t.cap != null) capLabel = `${used ?? 0}/${t.cap} today`;
  } else {
    used = quota?.sell_used;
    if (t.cap != null) capLabel = `${used ?? 0}/${t.cap} today`;
  }
  const capExhausted = t.cap != null && used != null && used >= t.cap;

  // Gate matching — only applies when the player has set a price gate
  // for this resource AND the trader is on the matching side. Mismatched
  // side stays neutral.
  let gateClass = '';
  let gateNote = '';
  if (policy?.mode === 'sell_surplus' && policy.min_sell_price && t.side === 'buys') {
    if (t.price >= policy.min_sell_price) { gateClass = 'tp-trader-meets'; gateNote = '✓ meets your sell gate'; }
    else { gateClass = 'tp-trader-misses'; gateNote = `× below your $${policy.min_sell_price} sell gate`; }
  } else if (policy?.mode === 'buy_to_reserve' && policy.max_buy_price && t.side === 'sells') {
    if (t.price <= policy.max_buy_price) { gateClass = 'tp-trader-meets'; gateNote = '✓ meets your buy gate'; }
    else { gateClass = 'tp-trader-misses'; gateNote = `× above your $${policy.max_buy_price} buy gate`; }
  }

  return `<div class="tp-trader-row tp-trader-${t.side} ${gateClass}">
    <span class="tp-trader-name">${escapeHtml(state.traders[t.tk]?.name || t.tk)}</span>
    <span class="tp-trader-side">${t.side}</span>
    <span class="tp-trader-price">$${t.price}</span>
    <span class="tp-trader-cap ${capExhausted ? 'tp-cap-exhausted' : ''}">${capLabel}</span>
    ${gateNote ? `<span class="tp-trader-gate">${gateNote}</span>` : ''}
  </div>`;
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
      btn.disabled = true; btn.textContent = 'Saving…';
      try {
        const { error } = await sb.rpc('save_trade_policy', {
          p_resource_key: rk, p_mode: mode,
          p_reserve_target: reserve, p_min_sell_price: minSell, p_max_buy_price: maxBuy
        });
        if (error) throw error;
        state.tradePolicies[rk] = { mode, reserve_target: reserve, min_sell_price: minSell, max_buy_price: maxBuy };
        btn.textContent = 'Saved';
        setTimeout(() => { btn.disabled = false; btn.textContent = 'Save'; }, 1200);
      } catch (err) {
        alert('Policy save failed: ' + (err.message || err));
        btn.disabled = false; btn.textContent = 'Save';
      }
    });
  });
}

function computeBestDeals(resourceTraders) {
  const out = [];
  for (const rk in state.tradePolicies) {
    const policy = state.tradePolicies[rk];
    const resource = state.resourceNodes[rk];
    if (!resource || !resourceTraders[rk]) continue;
    const rows = resourceTraders[rk];
    if (policy.mode === 'sell_surplus' && policy.min_sell_price) {
      const buyers = rows.filter((r) => r.side === 'buys' && r.price >= policy.min_sell_price)
        .sort((a, b) => b.price - a.price);
      if (buyers.length) {
        out.push({ resourceName: resource.name, side: 'sell',
          traderName: state.traders[buyers[0].tk]?.name || buyers[0].tk, price: buyers[0].price });
      }
    }
    if (policy.mode === 'buy_to_reserve' && policy.max_buy_price) {
      const sellers = rows.filter((r) => r.side === 'sells' && r.price <= policy.max_buy_price)
        .sort((a, b) => a.price - b.price);
      if (sellers.length) {
        out.push({ resourceName: resource.name, side: 'buy',
          traderName: state.traders[sellers[0].tk]?.name || sellers[0].tk, price: sellers[0].price });
      }
    }
  }
  return out;
}

function escapeHtml(s) {
  return String(s || '').replace(/[&<>"]/g, (c) => ({
    '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;'
  }[c]));
}
