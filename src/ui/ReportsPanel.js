// Reports panel — quick financial dashboard. Pulls recent
// cash_transactions and shows: 24h income/expense summary, plus a
// chronological list of recent rows. v1 has a more elaborate
// time-series chart; we're starting with the numbers.
import { sb } from '../api/supabase.js';
import { state } from '../state/store.js';

let mounted = false;

export async function openReports() {
  if (mounted) return;
  mounted = true;

  const root = document.getElementById('ui-root');
  const overlay = document.createElement('div');
  overlay.id = 'reports-overlay';
  overlay.innerHTML = `
    <div class="rp-card">
      <div class="rp-header">
        <h2>Treasury</h2>
        <button class="rp-close" aria-label="Close">×</button>
      </div>
      <div class="rp-body" id="rp-body">
        <p class="rp-loading">Loading…</p>
      </div>
    </div>
  `;
  root.appendChild(overlay);

  const close = () => {
    overlay.remove();
    mounted = false;
  };
  overlay.querySelector('.rp-close').addEventListener('click', close);
  overlay.addEventListener('click', (e) => {
    if (e.target === overlay) close();
  });

  // Last 100 transactions, newest first. RLS keeps this scoped to
  // the current player.
  const sinceIso = new Date(Date.now() - 24 * 60 * 60 * 1000).toISOString();
  const { data, error } = await sb
    .from('cash_transactions')
    .select('id, source, amount, context, created_at')
    .gte('created_at', sinceIso)
    .order('created_at', { ascending: false })
    .limit(100);

  if (error) {
    document.getElementById('rp-body').innerHTML =
      `<p class="rp-error">Couldn't load transactions: ${error.message}</p>`;
    return;
  }

  let income = 0, expense = 0;
  for (const row of data) {
    if (row.amount > 0) income += row.amount;
    else expense += -row.amount;
  }

  const bySource = {};
  for (const row of data) {
    bySource[row.source] = (bySource[row.source] || 0) + row.amount;
  }
  const sourceRows = Object.entries(bySource)
    .sort((a, b) => Math.abs(b[1]) - Math.abs(a[1]))
    .map(([src, total]) =>
      `<div class="rp-source">
        <span class="rp-src-name">${friendlySource(src)}</span>
        <span class="rp-src-amt ${total >= 0 ? 'rp-pos' : 'rp-neg'}">${total >= 0 ? '+' : ''}$${total}</span>
      </div>`).join('');

  const txRows = data.slice(0, 25).map((row) => {
    const t = new Date(row.created_at);
    const when = t.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
    return `<div class="rp-tx">
      <span class="rp-tx-when">${when}</span>
      <span class="rp-tx-src">${friendlySource(row.source)}</span>
      <span class="rp-tx-amt ${row.amount >= 0 ? 'rp-pos' : 'rp-neg'}">${row.amount >= 0 ? '+' : ''}$${row.amount}</span>
    </div>`;
  }).join('');

  document.getElementById('rp-body').innerHTML = `
    <div class="rp-summary">
      <div class="rp-stat">
        <span class="rp-stat-label">Cash</span>
        <span class="rp-stat-value">$${Math.floor(state.profile.money || 0)}</span>
      </div>
      <div class="rp-stat">
        <span class="rp-stat-label">Income (24h)</span>
        <span class="rp-stat-value rp-pos">+$${income}</span>
      </div>
      <div class="rp-stat">
        <span class="rp-stat-label">Expense (24h)</span>
        <span class="rp-stat-value rp-neg">-$${expense}</span>
      </div>
    </div>
    <h3 class="rp-section-title">By source (24h)</h3>
    <div class="rp-sources">${sourceRows || '<p class="rp-empty">No activity in the last day.</p>'}</div>
    <h3 class="rp-section-title">Recent transactions</h3>
    <div class="rp-txs">${txRows || '<p class="rp-empty">No transactions.</p>'}</div>
  `;
}

function friendlySource(src) {
  return ({
    tax_revenue: 'Taxes',
    build_cost: 'Building cost',
    expansion_cost: 'District expansion',
    starting_grant: 'Starting grant',
    demolish_refund: 'Demolish refund',
    upkeep: 'Upkeep',
    trade_sale: 'Trade (sell)',
    trade_purchase: 'Trade (buy)',
    black_market: 'Black market'
  })[src] || src;
}
