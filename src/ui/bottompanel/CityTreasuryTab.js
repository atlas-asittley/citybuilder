// City > Treasury subtab.
//
// Four-component dashboard at the top:
//   1. Burn rate + runway projection ("-$340/day · cash runs out in ~12 days")
//   2. Top income source + top expense sink chips
//   3. Daily-net 7-bar inline SVG chart (green up / red down)
//   4. Cumulative-balance sparkline (color picks up trend direction)
//
// Followed by 24h income / expense summary, proportional-bar breakdown
// by source, and a recent-transactions list. Mirrors v1's reports.js
// Treasury panel.
import { sb } from '../../api/supabase.js';
import { state } from '../../state/store.js';

// Period toggle state. Day / Week / Month selector — corresponds to
// the daily-series p_days arg + the recent-transactions time window.
// Persisted in localStorage so the choice survives reloads.
const PERIODS = [
  { key: '1',  label: 'Today', days: 1 },
  { key: '7',  label: 'Week',  days: 7 },
  { key: '30', label: 'Month', days: 30 }
];
const PERIOD_KEY = 'city_treasury_period_v2';
let activePeriod = loadActivePeriod();
function loadActivePeriod() {
  try { return localStorage.getItem(PERIOD_KEY) || '7'; }
  catch (_e) { return '7'; }
}
function setActivePeriod(key) {
  activePeriod = key;
  try { localStorage.setItem(PERIOD_KEY, key); } catch (_e) { /* no-op */ }
}

const SOURCE_LABELS = {
  tax_revenue:      'Taxes',
  trade_sale:       'Trade (sell)',
  trade_purchase:   'Trade (buy)',
  black_market:     'Black market',
  build_cost:       'Building cost',
  demolish_refund:  'Demolish refund',
  expansion_cost:   'District expansion',
  starting_grant:   'Starting grant',
  upkeep:           'Upkeep',
  river_traders:    'River Traders',
  ledger_adjustment: 'Ledger adjustment',
  trade_offer:      'Player trade offer',
  trade_agreement:  'Player trade agreement'
};

export async function renderCityTreasury(parent) {
  parent.innerHTML = '<p class="rp-loading">Loading…</p>';
  const period = PERIODS.find((p) => p.key === activePeriod) || PERIODS[1];
  const sinceIso = new Date(Date.now() - period.days * 24 * 60 * 60 * 1000).toISOString();
  const [seriesRes, txRes] = await Promise.all([
    sb.rpc('get_treasury_daily_series', { p_days: period.days }),
    sb.from('cash_transactions')
      .select('id, source, amount, context, created_at')
      .gte('created_at', sinceIso)
      .order('created_at', { ascending: false })
      .limit(200)
  ]);
  if (txRes.error) {
    parent.innerHTML = `<p class="rp-error">Couldn't load transactions: ${txRes.error.message}</p>`;
    return;
  }

  const txs = txRes.data || [];
  const series = (seriesRes.error ? [] : seriesRes.data || []).map((row) => ({
    date: row.day || row.date,
    earned: Number(row.earned ?? row.income ?? 0),
    spent:  Number(row.spent  ?? row.expense ?? 0),
    net:    Number(row.net ?? ((row.earned || 0) - (row.spent || 0))),
    sources: row.sources || {},
    sinks:   row.sinks || {}
  }));

  // 24h totals + per-source proportional breakdown.
  let income = 0, expense = 0;
  const sources24h = {};   // positive amounts
  const sinks24h = {};     // negative amounts (stored as positive magnitudes)
  for (const t of txs) {
    if (t.amount > 0) {
      income += t.amount;
      sources24h[t.source] = (sources24h[t.source] || 0) + t.amount;
    } else if (t.amount < 0) {
      expense += -t.amount;
      sinks24h[t.source] = (sinks24h[t.source] || 0) + -t.amount;
    }
  }

  const periodLabel = period.label.toLowerCase();
  parent.innerHTML = `
    ${renderPeriodToggle(period.key)}
    ${renderTreasuryAdvisor(series, period)}
    <div class="rp-summary">
      <div class="rp-stat"><span class="rp-stat-label">Cash</span><span class="rp-stat-value">$${Math.floor(state.profile.money || 0).toLocaleString()}</span></div>
      <div class="rp-stat"><span class="rp-stat-label">Income (${periodLabel})</span><span class="rp-stat-value rp-pos">+$${income.toLocaleString()}</span></div>
      <div class="rp-stat"><span class="rp-stat-label">Expense (${periodLabel})</span><span class="rp-stat-value rp-neg">-$${expense.toLocaleString()}</span></div>
    </div>
    <h3 class="rp-section-title">Income sources (${periodLabel})</h3>
    ${renderFlowBars(sources24h, 'pos') || '<p class="rp-empty">No income yet.</p>'}
    <h3 class="rp-section-title">Spending (${periodLabel})</h3>
    ${renderFlowBars(sinks24h, 'neg') || '<p class="rp-empty">No spending yet.</p>'}
    <h3 class="rp-section-title">Recent transactions</h3>
    <div class="rp-txs">${renderTxList(txs)}</div>
  `;

  parent.querySelectorAll('.rp-period-btn').forEach((btn) => {
    btn.addEventListener('click', () => {
      setActivePeriod(btn.dataset.period);
      renderCityTreasury(parent);
    });
  });
}

function renderPeriodToggle(activeKey) {
  return `<div class="rp-period">
    ${PERIODS.map((p) => `
      <button class="rp-period-btn ${p.key === activeKey ? 'rp-period-active' : ''}" data-period="${p.key}">${p.label}</button>
    `).join('')}
  </div>`;
}

// ── Treasury Advisor — 4-component dashboard ──
//
// Skipped entirely when the 7-day window has no activity (no chart =
// no insight). Otherwise: burn rate text + projection, top source +
// sink chips, daily-net bars, cumulative-balance sparkline.
function renderTreasuryAdvisor(days, period) {
  const hasActivity = days.some((d) => d.earned > 0 || d.spent > 0);
  if (!hasActivity) return '';

  const money = Number(state.profile?.money || 0);
  const totalNet = days.reduce((s, d) => s + d.net, 0);
  const avgDailyNet = totalNet / Math.max(1, days.length);
  const headerSuffix = period ? ` — last ${period.label.toLowerCase()}` : ' — last 7 days';

  let rateText, projText, rateClass;
  if (avgDailyNet > 0.5) {
    rateText = `+$${Math.round(avgDailyNet)}/day`;
    projText = '';
    rateClass = 'good';
  } else if (avgDailyNet < -0.5) {
    const burn = -avgDailyNet;
    rateText = `-$${Math.round(burn)}/day`;
    rateClass = 'bad';
    if (money > 0) {
      const runway = Math.floor(money / burn);
      projText = `cash runs out in ~${runway} day${runway === 1 ? '' : 's'} at this rate`;
    } else {
      projText = 'currently in deficit';
    }
  } else {
    rateText = 'break-even';
    projText = '';
    rateClass = 'neutral';
  }

  // Aggregate sources + sinks across the week for the chip selection.
  const sources = {}, sinks = {};
  for (const d of days) {
    for (const k in (d.sources || {})) sources[k] = (sources[k] || 0) + d.sources[k];
    for (const k in (d.sinks   || {})) sinks[k]   = (sinks[k]   || 0) + d.sinks[k];
  }
  const topSource = Object.keys(sources).sort((a, b) => sources[b] - sources[a])[0];
  const topSink   = Object.keys(sinks).sort((a, b) => sinks[b] - sinks[a])[0];

  return `
    <div class="rp-advisor">
      <div class="rp-advisor-title">Treasury Advisor${headerSuffix}</div>
      <div class="rp-burn-row">
        <span class="rp-burn-value rp-${rateClass}">${rateText}</span>
        ${projText ? `<span class="rp-burn-proj">· ${escapeHtml(projText)}</span>` : ''}
      </div>
      ${topSource || topSink ? `
        <div class="rp-chips">
          ${topSource ? `<span class="rp-chip rp-chip-good">↑ ${escapeHtml(friendlySource(topSource))} $${Math.round(sources[topSource]).toLocaleString()}</span>` : ''}
          ${topSink   ? `<span class="rp-chip rp-chip-bad">↓ ${escapeHtml(friendlySource(topSink))} $${Math.round(sinks[topSink]).toLocaleString()}</span>` : ''}
        </div>
      ` : ''}
      <div class="rp-chart-label">Daily net</div>
      ${renderDailyBars(days)}
      <div class="rp-chart-label">Cash balance</div>
      ${renderBalanceLine(days, money)}
    </div>
  `;
}

// Inline SVG: 7 bars, centered on a zero line. Green up for profit,
// red down for loss. Bar height proportional to |net|. Underneath,
// a date-axis row of small labels (with month-name on day 1).
function renderDailyBars(days) {
  if (!days.length) return '';
  const maxAbs = days.reduce((m, d) => Math.max(m, Math.abs(d.net)), 1);
  const n = days.length;
  const pad = 0.6;
  const slot = 100 / n;
  const midY = 28;
  const maxBar = 22;
  const bars = days.map((d, i) => {
    const h = Math.abs(d.net) / maxAbs * maxBar;
    const y = d.net >= 0 ? midY - h : midY;
    const color = d.net >= 0 ? '#5ec49e' : '#e0707a';
    return `<rect x="${(i * slot + pad).toFixed(2)}" y="${y.toFixed(2)}" width="${(slot - 2 * pad).toFixed(2)}" height="${Math.max(0.4, h).toFixed(2)}" fill="${color}" rx="0.5"/>`;
  }).join('');
  return `
    <svg class="rp-svg-chart" viewBox="0 0 100 56" preserveAspectRatio="none">
      <line x1="0" y1="${midY}" x2="100" y2="${midY}" stroke="#3a4a5e" stroke-width="0.3"/>
      ${bars}
    </svg>
    ${renderDateAxis(days)}
  `;
}

// Cumulative-balance sparkline. Reconstructs the start-of-window
// balance by walking nets backwards from current money, then plots
// forward. Color reflects direction (green if ending higher than
// starting, red if lower). Filled area underneath for emphasis.
function renderBalanceLine(days, currentMoney) {
  if (!days.length) return '';
  let startBalance = currentMoney;
  for (const d of days) startBalance -= d.net;
  const balances = [];
  let b = startBalance;
  for (const d of days) { b += d.net; balances.push(b); }

  const minB = Math.min(...balances);
  let maxB = Math.max(...balances);
  if (maxB === minB) maxB = minB + 1;
  const range = maxB - minB;
  const pts = balances.map((v, i) => {
    const x = i / Math.max(1, balances.length - 1) * 100;
    const y = 50 - ((v - minB) / range * 40 + 4);
    return `${x.toFixed(2)},${y.toFixed(2)}`;
  });
  const stroke = balances[balances.length - 1] >= balances[0] ? '#5ec49e' : '#e0707a';
  const areaPts = pts.slice();
  areaPts.push('100,56');
  areaPts.push('0,56');
  return `
    <svg class="rp-svg-chart" viewBox="0 0 100 56" preserveAspectRatio="none">
      <polygon points="${areaPts.join(' ')}" fill="${stroke}" fill-opacity="0.12"/>
      <polyline points="${pts.join(' ')}" stroke="${stroke}" stroke-width="0.7" fill="none" stroke-linejoin="round" stroke-linecap="round"/>
    </svg>
    ${renderDateAxis(days)}
  `;
}

// Date labels under each bar / line tick. Shows month-name only on
// the first label and on month-boundary days, otherwise just the
// day-of-month, to keep the row compact.
function renderDateAxis(days) {
  const ticks = days.map((d, i) => {
    const parts = String(d.date || '').split('-');
    if (parts.length !== 3) return '<span></span>';
    const dt = new Date(Date.UTC(+parts[0], +parts[1] - 1, +parts[2]));
    const dom = dt.getUTCDate();
    const showMonth = (i === 0) || dom === 1;
    const label = showMonth
      ? dt.toLocaleDateString(undefined, { month: 'short', day: 'numeric', timeZone: 'UTC' })
      : String(dom);
    return `<span class="rp-axis-tick">${escapeHtml(label)}</span>`;
  }).join('');
  return `<div class="rp-axis">${ticks}</div>`;
}

// Horizontal proportional bars. Each row's width = value / max_value
// in the set. Sorted descending. `kind` controls bar color (pos=green
// for income, neg=red for spending).
function renderFlowBars(byKey, kind) {
  const keys = Object.keys(byKey).sort((a, b) => byKey[b] - byKey[a]);
  if (keys.length === 0) return '';
  const max = byKey[keys[0]] || 1;
  const color = kind === 'neg' ? '#e94560' : '#16c79a';
  return `<div class="rp-flow">
    ${keys.map((k) => {
      const v = byKey[k];
      const pct = (v / max) * 100;
      return `<div class="rp-flow-row">
        <div class="rp-flow-name">${escapeHtml(friendlySource(k))}</div>
        <div class="rp-flow-bar"><div class="rp-flow-fill" style="width:${pct.toFixed(1)}%;background:${color};"></div></div>
        <div class="rp-flow-amt">$${Math.round(v).toLocaleString()}</div>
      </div>`;
    }).join('')}
  </div>`;
}

function renderTxList(txs) {
  if (txs.length === 0) return '<p class="rp-empty">No transactions in the last 24h.</p>';
  return txs.slice(0, 25).map((row) => {
    const t = new Date(row.created_at);
    const when = t.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
    return `<div class="rp-tx">
      <span class="rp-tx-when">${when}</span>
      <span class="rp-tx-src">${escapeHtml(friendlySource(row.source))}</span>
      <span class="rp-tx-amt ${row.amount >= 0 ? 'rp-pos' : 'rp-neg'}">${row.amount >= 0 ? '+' : ''}$${row.amount.toLocaleString()}</span>
    </div>`;
  }).join('');
}

function friendlySource(src) {
  return SOURCE_LABELS[src] || src;
}

function escapeHtml(s) {
  return String(s || '').replace(/[&<>"]/g, (c) => ({
    '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;'
  }[c]));
}
