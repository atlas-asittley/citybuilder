// Trade > Black Market subtab. Sell anything at 35% / buy at 200%.
// Inline quantity stepper per resource: − [qty] + buttons + live
// "$total" preview + Sell/Buy commit button. No prompt() dialogs.
import { sb } from '../../api/supabase.js';
import { state } from '../../state/store.js';

const GROUPS = [
  { label: 'Raw materials',     match: (r) => r.kind === 'raw' && !r.is_food },
  { label: 'Raw food',          match: (r) => r.kind === 'raw' && r.is_food },
  { label: 'Processed',         match: (r) => r.kind === 'processed' && !r.is_food && !r.is_luxury_food && !r.is_industrial_luxury },
  { label: 'Cooked food',       match: (r) => r.kind === 'processed' && r.is_food && !r.is_luxury_food },
  { label: 'Industrial luxury', match: (r) => r.is_industrial_luxury },
  { label: 'Luxury food',       match: (r) => r.is_luxury_food }
];

// Per-resource quantity state, persisted across re-renders so the
// number doesn't reset when the tick loop refreshes the panel mid-
// stepper. Keyed by resource_key.
const qtyMap = {};

export function renderTradeBlackMarket(parent) {
  const resources = Object.values(state.resourceNodes)
    .filter((r) => r.is_active && r.base_price);
  let html = `
    <p class="tp-warning">
      Sell anything at <strong>35%</strong> of fair value, or buy at <strong>200%</strong>.
      The emergency option — always open.
    </p>`;
  for (const group of GROUPS) {
    const items = resources.filter(group.match).sort((a, b) => a.base_price - b.base_price);
    if (!items.length) continue;
    html += `<div class="tp-section">
      <h3 class="tp-section-title">${group.label}</h3>
      <div class="tp-rows">`;
    for (const r of items) {
      html += renderRow(r);
    }
    html += `</div></div>`;
  }
  parent.innerHTML = html;
  wireHandlers(parent);
}

function renderRow(r) {
  const inv = Math.floor(state.inventory[r.key] || 0);
  const sellPrice = Math.max(1, Math.floor(r.base_price * 0.35));
  const buyPrice  = Math.max(1, Math.ceil(r.base_price * 2.0));
  const qty = Math.max(1, qtyMap[r.key] || 1);
  const money = state.profile?.money || 0;
  const maxBuy = Math.floor(money / buyPrice);
  const maxSell = inv;
  const sellTotal = qty * sellPrice;
  const buyTotal  = qty * buyPrice;
  const canSell = qty <= maxSell && qty > 0;
  const canBuy  = qty <= maxBuy  && qty > 0;
  return `<div class="bm-row" data-key="${r.key}">
    <div class="bm-row-head">
      <span class="bm-name">${r.name}</span>
      <small class="bm-have">have ${inv}</small>
    </div>
    <div class="bm-stepper">
      <button class="bm-step" data-act="dec">−</button>
      <input class="bm-qty" type="number" min="1" max="9999" value="${qty}" />
      <button class="bm-step" data-act="inc">+</button>
      <button class="bm-step bm-step-max" data-act="max-sell" title="Set qty to max sellable">max sell (${maxSell})</button>
      <button class="bm-step bm-step-max" data-act="max-buy"  title="Set qty to max buyable">max buy (${maxBuy})</button>
    </div>
    <div class="bm-actions">
      <button class="tp-btn tp-btn-sell" data-act="sell" ${canSell ? '' : 'disabled'}>
        Sell ${qty} @ $${sellPrice} = <strong>+$${sellTotal.toLocaleString()}</strong>
      </button>
      <button class="tp-btn tp-btn-buy" data-act="buy" ${canBuy ? '' : 'disabled'}>
        Buy ${qty} @ $${buyPrice} = <strong>−$${buyTotal.toLocaleString()}</strong>
      </button>
    </div>
  </div>`;
}

function wireHandlers(parent) {
  parent.querySelectorAll('.bm-row').forEach((rowEl) => {
    const key = rowEl.dataset.key;
    const qtyInput = rowEl.querySelector('.bm-qty');
    const updateQty = (q) => {
      const v = Math.max(1, Math.min(9999, Math.floor(q) || 1));
      qtyMap[key] = v;
      // Rerender just this row so the totals + disabled-state update.
      const fresh = renderRow(state.resourceNodes[key]);
      const tmp = document.createElement('div');
      tmp.innerHTML = fresh;
      rowEl.replaceWith(tmp.firstElementChild);
      // Re-attach handlers for the new row.
      wireHandlers(parent);
    };
    qtyInput.addEventListener('input', () => updateQty(parseInt(qtyInput.value, 10) || 1));
    rowEl.querySelectorAll('.bm-step').forEach((btn) => {
      btn.addEventListener('click', () => {
        const act = btn.dataset.act;
        const cur = qtyMap[key] || 1;
        const inv = Math.floor(state.inventory[key] || 0);
        const money = state.profile?.money || 0;
        const buyPrice = Math.max(1, Math.ceil(state.resourceNodes[key].base_price * 2.0));
        if (act === 'dec') updateQty(cur - 1);
        else if (act === 'inc') updateQty(cur + 1);
        else if (act === 'max-sell') updateQty(Math.max(1, inv));
        else if (act === 'max-buy')  updateQty(Math.max(1, Math.floor(money / buyPrice)));
      });
    });
    rowEl.querySelectorAll('.tp-btn').forEach((btn) => {
      btn.addEventListener('click', async () => {
        const act = btn.dataset.act;
        const qty = qtyMap[key] || 1;
        btn.disabled = true;
        const origText = btn.textContent;
        btn.textContent = act === 'sell' ? 'Selling…' : 'Buying…';
        try {
          const { data, error } = await sb.rpc('black_market_trade', {
            p_resource_key: key, p_quantity: qty, p_direction: act
          });
          if (error) throw error;
          if (data?.money !== undefined) state.profile.money = data.money;
          if (data?.inventory) {
            state.inventory = {};
            for (const k in data.inventory) state.inventory[k] = Number(data.inventory[k]);
          }
          renderTradeBlackMarket(parent);
        } catch (err) {
          alert((act === 'sell' ? 'Sell' : 'Buy') + ' failed: ' + (err.message || err));
          btn.disabled = false;
          btn.textContent = origText;
        }
      });
    });
  });
}
