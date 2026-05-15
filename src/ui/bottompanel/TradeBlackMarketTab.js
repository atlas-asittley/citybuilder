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
    const sellBtn  = rowEl.querySelector('.tp-btn-sell');
    const buyBtn   = rowEl.querySelector('.tp-btn-buy');
    const decBtn   = rowEl.querySelector('.bm-step[data-act="dec"]');
    const incBtn   = rowEl.querySelector('.bm-step[data-act="inc"]');
    const maxSellBtn = rowEl.querySelector('.bm-step[data-act="max-sell"]');
    const maxBuyBtn  = rowEl.querySelector('.bm-step[data-act="max-buy"]');

    // Recompute everything that depends on quantity + repaint the
    // row's buttons/totals in place. NO DOM replacement — so the
    // qty input keeps focus + cursor mid-typing. Empty / NaN inputs
    // are treated as 0 (disabling commit) so the user can clear and
    // retype without the field snapping back to 1 between keystrokes.
    function refreshTotals() {
      const r = state.resourceNodes[key];
      const inv = Math.floor(state.inventory[key] || 0);
      const sellPrice = Math.max(1, Math.floor(r.base_price * 0.35));
      const buyPrice  = Math.max(1, Math.ceil(r.base_price * 2.0));
      const money = state.profile?.money || 0;
      const maxSell = inv;
      const maxBuy  = Math.floor(money / buyPrice);
      const rawVal  = qtyInput.value;
      const qty = rawVal === '' ? 0 : Math.max(0, Math.min(9999, parseInt(rawVal, 10) || 0));
      const canSell = qty > 0 && qty <= maxSell;
      const canBuy  = qty > 0 && qty <= maxBuy;
      sellBtn.disabled = !canSell;
      buyBtn.disabled  = !canBuy;
      sellBtn.innerHTML = `Sell ${qty} @ $${sellPrice} = <strong>+$${(qty * sellPrice).toLocaleString()}</strong>`;
      buyBtn.innerHTML  = `Buy ${qty} @ $${buyPrice} = <strong>−$${(qty * buyPrice).toLocaleString()}</strong>`;
      maxSellBtn.textContent = `max sell (${maxSell})`;
      maxBuyBtn.textContent  = `max buy (${maxBuy})`;
    }
    // Live update on every keystroke. Don't write back to qtyMap on
    // intermediate empty values — only persist a real, parsed number
    // so the panel-tick re-render uses the typed value, not blank.
    function commitQty() {
      const v = parseInt(qtyInput.value, 10);
      if (Number.isFinite(v) && v >= 1) qtyMap[key] = Math.min(9999, v);
    }
    function setQty(v) {
      const clamped = Math.max(1, Math.min(9999, Math.floor(v) || 1));
      qtyMap[key] = clamped;
      qtyInput.value = clamped;
      refreshTotals();
    }

    qtyInput.addEventListener('input', () => { commitQty(); refreshTotals(); });
    // On blur, snap an empty / invalid input back to 1 so the next
    // commit doesn't try to send qty=0.
    qtyInput.addEventListener('blur', () => {
      const v = parseInt(qtyInput.value, 10);
      if (!Number.isFinite(v) || v < 1) setQty(1);
    });

    decBtn.addEventListener('click', () => setQty((qtyMap[key] || 1) - 1));
    incBtn.addEventListener('click', () => setQty((qtyMap[key] || 1) + 1));
    maxSellBtn.addEventListener('click', () => {
      const inv = Math.floor(state.inventory[key] || 0);
      setQty(Math.max(1, inv));
    });
    maxBuyBtn.addEventListener('click', () => {
      const money = state.profile?.money || 0;
      const buyPrice = Math.max(1, Math.ceil(state.resourceNodes[key].base_price * 2.0));
      setQty(Math.max(1, Math.floor(money / buyPrice)));
    });

    rowEl.querySelectorAll('.tp-btn').forEach((btn) => {
      btn.addEventListener('click', async () => {
        const act = btn.dataset.act;
        // Commit whatever's currently in the field before sending —
        // a click can land before blur in some browsers, so don't
        // trust qtyMap alone.
        commitQty();
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
