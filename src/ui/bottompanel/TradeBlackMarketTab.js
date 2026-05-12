// Trade > Black Market subtab. Same buy/sell logic as the standalone
// modal version, rendered into a passed-in container.
import { sb } from '../../api/supabase.js';
import { state } from '../../state/store.js';

const GROUPS = [
  { label: 'Raw materials', match: (r) => r.kind === 'raw' && !r.is_food },
  { label: 'Raw food',      match: (r) => r.kind === 'raw' && r.is_food },
  { label: 'Processed',     match: (r) => r.kind === 'processed' && !r.is_food && !r.is_luxury_food && !r.is_industrial_luxury },
  { label: 'Cooked food',   match: (r) => r.kind === 'processed' && r.is_food && !r.is_luxury_food },
  { label: 'Industrial luxury', match: (r) => r.is_industrial_luxury },
  { label: 'Luxury food',   match: (r) => r.is_luxury_food }
];

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
  parent.innerHTML = html;

  parent.querySelectorAll('.tp-btn').forEach((btn) => {
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
      }
    });
  });
}
