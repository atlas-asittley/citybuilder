// City > Treasury subtab. Renders the 24h summary + 7d chart +
// recent transactions list into a passed-in container. Same data
// path as the standalone ReportsPanel modal.
import { sb } from '../../api/supabase.js';
import { state } from '../../state/store.js';

export async function renderCityTreasury(parent) {
  parent.innerHTML = '<p class="rp-loading">Loading…</p>';
  const sinceIso = new Date(Date.now() - 24 * 60 * 60 * 1000).toISOString();
  const [seriesRes, txRes] = await Promise.all([
    sb.rpc('get_treasury_daily_series', { p_days: 7 }),
    sb.from('cash_transactions')
      .select('id, source, amount, context, created_at')
      .gte('created_at', sinceIso)
      .order('created_at', { ascending: false })
      .limit(100)
  ]);

  const data = txRes.data;
  if (txRes.error) {
    parent.innerHTML = `<p class="rp-error">Couldn't load transactions: ${txRes.error.message}</p>`;
    return;
  }
  const series = seriesRes.error ? [] : (seriesRes.data || []);

  let income = 0, expense = 0;
  for (const row of data) {
    if (row.amount > 0) income += row.amount;
    else expense += -row.amount;
  }
  const bySource = {};
  for (const row of data) bySource[row.source] = (bySource[row.source] || 0) + row.amount;
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

  parent.innerHTML = `
    <div class="rp-summary">
      <div class="rp-stat"><span class="rp-stat-label">Cash</span><span class="rp-stat-value">$${Math.floor(state.profile.money || 0)}</span></div>
      <div class="rp-stat"><span class="rp-stat-label">Income (24h)</span><span class="rp-stat-value rp-pos">+$${income}</span></div>
      <div class="rp-stat"><span class="rp-stat-label">Expense (24h)</span><span class="rp-stat-value rp-neg">-$${expense}</span></div>
    </div>
    ${series.length > 0 ? `
      <h3 class="rp-section-title">7-day income vs expense</h3>
      <canvas id="bp-rp-chart" width="420" height="140" class="rp-chart"></canvas>
      <div class="rp-chart-legend">
        <span class="rp-legend-dot" style="background:#16c79a;"></span> income
        <span class="rp-legend-dot" style="background:#e94560;"></span> expense
      </div>
    ` : ''}
    <h3 class="rp-section-title">By source (24h)</h3>
    <div class="rp-sources">${sourceRows || '<p class="rp-empty">No activity in the last day.</p>'}</div>
    <h3 class="rp-section-title">Recent transactions</h3>
    <div class="rp-txs">${txRows || '<p class="rp-empty">No transactions.</p>'}</div>
  `;
  if (series.length > 0) drawChart(document.getElementById('bp-rp-chart'), series);
}

function friendlySource(src) {
  return ({
    tax_revenue: 'Taxes', build_cost: 'Building cost',
    expansion_cost: 'District expansion', starting_grant: 'Starting grant',
    demolish_refund: 'Demolish refund', upkeep: 'Upkeep',
    trade_sale: 'Trade (sell)', trade_purchase: 'Trade (buy)', black_market: 'Black market'
  })[src] || src;
}

function drawChart(canvas, series) {
  if (!canvas) return;
  const ctx = canvas.getContext('2d');
  const W = canvas.width, H = canvas.height;
  const pad = { top: 8, right: 10, bottom: 18, left: 36 };
  const plotW = W - pad.left - pad.right;
  const plotH = H - pad.top - pad.bottom;
  const points = series.slice().reverse().map((row) => ({
    day: row.day || row.date,
    earned: Number(row.earned ?? row.income ?? 0),
    spent:  Number(row.spent  ?? row.expense ?? 0)
  }));
  const maxY = Math.max(1, ...points.map((p) => Math.max(p.earned, p.spent)));
  const stepY = niceStep(maxY, 4);
  const top = Math.ceil(maxY / stepY) * stepY;
  ctx.clearRect(0, 0, W, H);
  ctx.strokeStyle = 'rgba(15, 52, 96, 0.5)';
  ctx.fillStyle = '#888';
  ctx.font = '10px system-ui, sans-serif';
  ctx.textAlign = 'right'; ctx.textBaseline = 'middle';
  for (let v = 0; v <= top; v += stepY) {
    const y = pad.top + plotH - (v / top) * plotH;
    ctx.beginPath(); ctx.moveTo(pad.left, y); ctx.lineTo(W - pad.right, y); ctx.stroke();
    ctx.fillText('$' + v, pad.left - 4, y);
  }
  ctx.textAlign = 'center'; ctx.textBaseline = 'top';
  points.forEach((p, i) => {
    const x = pad.left + (plotW * i) / Math.max(1, points.length - 1);
    const d = new Date(p.day);
    const label = Number.isFinite(d.getDate()) ? `${d.getMonth() + 1}/${d.getDate()}` : '';
    ctx.fillText(label, x, pad.top + plotH + 4);
  });
  drawSeries(ctx, points.map((p) => p.earned), top, pad, plotW, plotH, '#16c79a');
  drawSeries(ctx, points.map((p) => p.spent),  top, pad, plotW, plotH, '#e94560');
}
function drawSeries(ctx, values, top, pad, plotW, plotH, color) {
  ctx.strokeStyle = color; ctx.lineWidth = 2; ctx.beginPath();
  values.forEach((v, i) => {
    const x = pad.left + (plotW * i) / Math.max(1, values.length - 1);
    const y = pad.top + plotH - (v / top) * plotH;
    if (i === 0) ctx.moveTo(x, y); else ctx.lineTo(x, y);
  });
  ctx.stroke();
  ctx.fillStyle = color;
  values.forEach((v, i) => {
    const x = pad.left + (plotW * i) / Math.max(1, values.length - 1);
    const y = pad.top + plotH - (v / top) * plotH;
    ctx.beginPath(); ctx.arc(x, y, 3, 0, Math.PI * 2); ctx.fill();
  });
}
function niceStep(maxY, targetTicks) {
  const rough = maxY / targetTicks;
  const mag = Math.pow(10, Math.floor(Math.log10(rough)));
  const norm = rough / mag;
  if (norm < 1.5) return mag;
  if (norm < 3)   return 2 * mag;
  if (norm < 7)   return 5 * mag;
  return 10 * mag;
}
