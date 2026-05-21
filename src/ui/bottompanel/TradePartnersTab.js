// Trade > Partners subtab. Renders the partner cards + per-resource
// trade-policy editor into a passed-in container. Same auto-trader
// mechanics as before; this is just the v1-style placement inside
// the bottom panel rather than a modal overlay.
import { sb } from '../../api/supabase.js';
import { state } from '../../state/store.js';
import { escapeHtml } from '../util.js';

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
    ${renderTraderDirectory()}
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
  wireTraderCardCollapse(parent);
}

// Per-trader collapse state lives in localStorage so it survives
// panel re-renders + reloads. Schema: { [traderKey]: 'collapsed' }
// — only collapsed entries are stored, default is open.
const TRADER_COLLAPSE_KEY = 'cb-trader-card-collapsed';
function readCollapseMap() {
  try { return JSON.parse(localStorage.getItem(TRADER_COLLAPSE_KEY) || '{}'); }
  catch { return {}; }
}
function isTraderCollapsed(tk) {
  return readCollapseMap()[tk] === true;
}
function setTraderCollapsed(tk, collapsed) {
  const m = readCollapseMap();
  if (collapsed) m[tk] = true;
  else delete m[tk];
  try { localStorage.setItem(TRADER_COLLAPSE_KEY, JSON.stringify(m)); }
  catch { /* private mode / quota — ignore, state degrades to per-session */ }
}
function wireTraderCardCollapse(root) {
  root.querySelectorAll('details.tp-trader-card').forEach((el) => {
    el.addEventListener('toggle', () => {
      const tk = el.dataset.trader;
      if (tk) setTraderCollapsed(tk, !el.open);
    });
  });
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

// Trader directory at the top of the Partners tab. Lists every known
// trader with lock state + name + transport-mode badge + description +
// next-visit countdown. Gives the player a "who's in town" snapshot
// AND tells them why some traders are locked out (the missing piece
// that v2 was previously hiding entirely).
function renderTraderDirectory() {
  const traders = Object.values(state.traders || {});
  if (traders.length === 0) return '';
  const unlocks = computeTraderUnlocks();
  const now = Date.now();
  const rows = traders.map((t) => {
    const lastIso = state.traderLastVisits?.[t.key];
    const intervalMs = (t.visit_interval_minutes || 0) * 60 * 1000;
    let countdown = '—';
    if (intervalMs > 0) {
      const last = lastIso ? new Date(lastIso).getTime() : (state.profile?.created_at ? new Date(state.profile.created_at).getTime() : now);
      const next = last + intervalMs;
      const diff = next - now;
      if (diff <= 0) countdown = 'visiting now';
      else if (diff < 60 * 1000) countdown = '<1m';
      else if (diff < 60 * 60 * 1000) countdown = `${Math.ceil(diff / 60000)}m`;
      else countdown = `${Math.floor(diff / 3600000)}h ${Math.ceil((diff % 3600000) / 60000)}m`;
    }
    const mode = t.mode || t.transport_mode || 'starter';
    const unlock = unlocks[t.key] || { unlocked: true, hint: '' };
    // Unlocked traders render as <details> so the body collapses;
    // locked traders stay as <div> since their hint is the whole point.
    // Open/closed state persists per-trader in localStorage via
    // wireTraderCardCollapse() — toggle survives panel re-renders +
    // page reloads. Default to open so first-time players see the
    // goods table without hunting.
    if (!unlock.unlocked) {
      return `<div class="tp-trader-card tp-trader-locked">
        <div class="tp-trader-card-head">
          <span class="tp-trader-lock">🔒</span>
          <span class="tp-trader-card-name">${escapeHtml(t.name)}</span>
          <span class="tp-mode-badge tp-mode-${mode}">${escapeHtml(mode)}</span>
        </div>
        <div class="tp-trader-card-hint">${escapeHtml(unlock.hint || 'Locked.')}</div>
      </div>`;
    }
    const collapsed = isTraderCollapsed(t.key);
    return `<details class="tp-trader-card" data-trader="${escapeHtml(t.key)}" ${collapsed ? '' : 'open'}>
      <summary class="tp-trader-card-head">
        <span class="tp-trader-card-caret" aria-hidden="true">▸</span>
        <span class="tp-trader-card-name">${escapeHtml(t.name)}</span>
        <span class="tp-mode-badge tp-mode-${mode}">${escapeHtml(mode)}</span>
        <span class="tp-trader-card-next">next visit · ${escapeHtml(countdown)}</span>
      </summary>
      ${t.description ? `<div class="tp-trader-card-desc">${escapeHtml(t.description)}</div>` : ''}
      ${renderTraderGoods(t.key)}
    </details>`;
  }).join('');
  const lockedCount = traders.filter((t) => !(unlocks[t.key]?.unlocked ?? true)).length;
  const totalLabel = lockedCount > 0
    ? `${traders.length} <small>(${lockedCount} locked)</small>`
    : String(traders.length);
  return `<details class="tp-directory" open>
    <summary>Traders in this city ${totalLabel}</summary>
    ${rows}
  </details>`;
}

// What this trader buys + sells, with daily-cap usage. Mirrors v1's
// renderPartnerGoodsCompact (panels.js). Shown inside each unlocked
// trader card so the player can scan "this caravan sells me flour
// at $4 and buys my surplus pottery at $9" without having to scroll
// through every per-resource section to learn it.
//
// Buy/sell cells get tp-tg-meets / tp-tg-misses tinting when the
// player has set a policy gate that this row matches or fails. Same
// visual signal v1 uses, and it carries over the player's policy
// reasoning without forcing them to re-think every price.
function renderTraderGoods(traderKey) {
  const prices = state.allTraderPrices?.[traderKey] || {};
  const resourceKeys = Object.keys(prices);
  if (resourceKeys.length === 0) return '';
  const quotas = state.traderQuotas?.[traderKey] || {};
  resourceKeys.sort((a, b) => {
    const an = state.resourceNodes?.[a]?.name || a;
    const bn = state.resourceNodes?.[b]?.name || b;
    return an.localeCompare(bn);
  });
  const rows = resourceKeys.map((rk) => {
    const p = prices[rk];
    const q = quotas[rk] || {};
    const resName = state.resourceNodes?.[rk]?.name || rk;
    const todayParts = [];
    if (p.buy_price && q.buy_cap != null) {
      const used = q.buy_used || 0;
      const full = used >= q.buy_cap;
      todayParts.push(`<span class="tp-tg-cap${full ? ' tp-tg-cap-full' : ''}" title="Bought from you today">b ${used}/${q.buy_cap}</span>`);
    }
    if (p.sell_price && q.sell_cap != null) {
      const used = q.sell_used || 0;
      const full = used >= q.sell_cap;
      todayParts.push(`<span class="tp-tg-cap${full ? ' tp-tg-cap-full' : ''}" title="Sold to you today">s ${used}/${q.sell_cap}</span>`);
    }
    const policy = state.tradePolicies?.[rk];
    let buyHL = '', sellHL = '';
    if (policy) {
      if (policy.mode === 'sell_surplus' && policy.min_sell_price != null && p.buy_price) {
        buyHL = (p.buy_price >= policy.min_sell_price) ? ' tp-tg-meets' : ' tp-tg-misses';
      }
      if (policy.mode === 'buy_to_reserve' && policy.max_buy_price != null && p.sell_price) {
        sellHL = (p.sell_price <= policy.max_buy_price) ? ' tp-tg-meets' : ' tp-tg-misses';
      }
    }
    return `<tr>
      <td class="tp-tg-res">${escapeHtml(resName)}</td>
      <td class="tp-tg-buy${buyHL}">${p.buy_price ? '$' + p.buy_price : '—'}</td>
      <td class="tp-tg-sell${sellHL}">${p.sell_price ? '$' + p.sell_price : '—'}</td>
      <td class="tp-tg-today">${todayParts.join(' ')}</td>
    </tr>`;
  }).join('');
  return `<table class="tp-trader-goods">
    <thead><tr>
      <th>Resource</th><th title="Trader buys from you">Buys at</th><th title="Trader sells to you">Sells at</th><th>Today</th>
    </tr></thead>
    <tbody>${rows}</tbody>
  </table>`;
}

// Compute unlock state per trader. Mirrors v1's state.js
// computeTraderUnlocks model (auto-port from 2026-05-10):
//   - river_traders ("Neighboring City"): always on
//   - desert_caravan / mountain_folk: legacy, retired
//   - transport_mode traders: unlocked when this player has access
//     to that mode (owns matching hub on a road, OR owns a road-
//     connected truck_depot AND the city has any road-connected hub
//     of that mode)
function computeTraderUnlocks() {
  const out = {};
  const traders = state.traders || {};
  const my = state.allBuildings.filter((b) => b.player_id === state.currentUser?.id);
  const city = state.allBuildings;

  const isRoadConnected = (b) => {
    const bt = state.buildingTypes[b.building_type_key];
    if (!bt) return false;
    const fw = bt.footprint_w || 1, fh = bt.footprint_h || 1;
    for (let dx = 0; dx < fw; dx++) {
      if (hasRoad(b.x + dx, b.y - 1)) return true;
      if (hasRoad(b.x + dx, b.y + fh)) return true;
    }
    for (let dy = 0; dy < fh; dy++) {
      if (hasRoad(b.x - 1, b.y + dy)) return true;
      if (hasRoad(b.x + fw, b.y + dy)) return true;
    }
    return false;
  };
  const roadSet = new Set();
  for (const b of state.allBuildings) {
    if (state.buildingTypes[b.building_type_key]?.category === 'road') {
      roadSet.add(b.x + ',' + b.y);
    }
  }
  function hasRoad(x, y) { return roadSet.has(x + ',' + y); }

  const modeHubKey = (mode) => mode === 'airport' ? 'airport'
    : mode === 'seaport' ? 'seaport'
    : mode === 'train' ? 'train_depot' : null;

  const hubMatches = (b, mode) => {
    const bt = state.buildingTypes[b.building_type_key];
    if (!bt || bt.category !== 'transport_hub') return false;
    if (b.status !== 'active') return false;
    return b.building_type_key === modeHubKey(mode) && isRoadConnected(b);
  };
  const isTruckDepot = (b) =>
    b.building_type_key === 'truck_depot' && b.status === 'active' && isRoadConnected(b);

  const playerHasAccess = (mode) => {
    if (mode === 'truck') return my.some(isTruckDepot);
    if (my.some((b) => hubMatches(b, mode))) return true;
    if (!my.some(isTruckDepot)) return false;
    return city.some((b) => hubMatches(b, mode));
  };

  for (const tk in traders) {
    const t = traders[tk];
    if (tk === 'river_traders') {
      out[tk] = { unlocked: true, hint: '' };
    } else if (tk === 'desert_caravan' || tk === 'mountain_folk') {
      out[tk] = { unlocked: false, hint: 'Retired — collapsed into Neighboring City.' };
    } else if (t.transport_mode) {
      const has = playerHasAccess(t.transport_mode);
      const hint = has ? '' : (t.transport_mode === 'truck'
        ? 'Build a Truck Depot (with road access) to unlock this trader.'
        : `Build a ${t.transport_mode} hub or a Truck Depot to plug into the city's ${t.transport_mode} network.`);
      out[tk] = { unlocked: has, hint };
    } else {
      out[tk] = { unlocked: true, hint: '' };
    }
  }
  return out;
}

