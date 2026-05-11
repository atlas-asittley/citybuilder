// Black market trade panel — the always-available buy/sell window.
// Procedural-trader partners are richer but more involved; this is
// the v2 first cut, matching v1's "black market" tab.
//
// Sell at 35% of base_price, buy at 200%. Server enforces both; the
// UI just renders them so the player sees the rate before paying.
import { sb } from '../api/supabase.js';
import { state } from '../state/store.js';

let mounted = false;

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
    <div class="tp-card">
      <div class="tp-header">
        <h2>Black Market</h2>
        <button class="tp-close" aria-label="Close">×</button>
      </div>
      <p class="tp-warning">Sell anything in your inventory at <strong>35%</strong> of fair value, or buy at <strong>200%</strong>. The emergency option — there's no better rate, but it's always open.</p>
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

  render();
}

function render() {
  const body = document.getElementById('tp-body');
  if (!body) return;
  const resources = Object.values(state.resourceNodes)
    .filter((r) => r.is_active && r.base_price);

  let html = '';
  for (const group of RESOURCE_GROUPS) {
    const items = resources.filter(group.match).sort((a, b) => a.base_price - b.base_price);
    if (!items.length) continue;
    html += `<div class="tp-section">
      <h3 class="tp-section-title">${group.label}</h3>
      <div class="tp-rows">`;
    for (const r of items) {
      const inv = Math.floor(state.inventory[r.key] || 0);
      const sellPrice = Math.max(1, Math.floor(r.base_price * 0.35));
      const buyPrice = Math.max(1, Math.ceil(r.base_price * 2.0));
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
  body.innerHTML = html || '<p class="tp-empty">No resources available.</p>';

  body.querySelectorAll('.tp-btn').forEach((btn) => {
    btn.addEventListener('click', async () => {
      const act = btn.dataset.act;
      const key = btn.dataset.key;
      const price = Number(btn.dataset.price);
      const owned = Math.floor(state.inventory[key] || 0);
      const maxAffordable = act === 'buy' ? Math.floor((state.profile?.money || 0) / price) : owned;

      const qtyStr = prompt(`${act === 'sell' ? 'Sell how many' : 'Buy how many'} ${key} at $${price} each? (max ${maxAffordable})`);
      if (!qtyStr) return;
      const qty = parseInt(qtyStr, 10);
      if (!Number.isFinite(qty) || qty <= 0) {
        alert('Enter a positive number.');
        return;
      }

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
        render();
      } catch (err) {
        alert(act === 'sell' ? 'Sell failed: ' : 'Buy failed: ' + (err.message || err));
        btn.disabled = false;
      }
    });
  });
}
