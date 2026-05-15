// Top bar — two-row layout mirroring v1 exactly:
//
//   Row 1: city › district | money | runway (⏳) | trader-reset (🔄) | ⋯
//   Row 2: workers (👷) | population (👥) | parcels (🗺) | happiness (🙂) |
//          crime (🚨) | migration (→) | productivity (⚒)
//
// The ⋯ button opens a More menu with Expand / Offers / Reports /
// Players / Settings (Trade and Bell are not in this menu — they
// have their own quick-access icons elsewhere).
//
// Each stat has a tooltip (title attribute) describing what the
// number means and a tap target that does something useful. The
// happiness icon swaps between ☹ 😐 🙂 😊 based on the level; the
// crime value gets a color class; migration has up/down arrows;
// productivity colors by direction.
import { state } from '../state/store.js';
import { computeCityRunway, formatRunway } from '../state/runway.js';
import { computeHousingCapacity } from '../scenes/helpers.js';
import { openExpansionPanel } from './ExpansionPanel.js';
import { openSettings } from './SettingsPanel.js';
import { openBellLog, mountBellLog } from './BellLog.js';
import { sb } from '../api/supabase.js';
import { showToast } from './Toast.js';
import { openStatInfo } from './StatInfoModal.js';
import { openHelp } from './HelpModal.js';

let mounted = false;
let onExpandedCallback = null;
let traderResetInterval = null;

export function mountTopBar(onExpanded) {
  onExpandedCallback = onExpanded || null;
  if (mounted) return;
  const root = document.getElementById('ui-root');
  const bar = document.createElement('div');
  bar.id = 'topbar';
  bar.innerHTML = `
    <div class="topbar-row topbar-row-1">
      <div class="topbar-id">
        <span class="topbar-city" id="tb-city">—</span>
        <span class="topbar-divider">›</span>
        <span class="topbar-district" id="tb-district">—</span>
      </div>
      <span class="topbar-stat topbar-money" id="tb-money-stat" title="Treasury">
        <span class="v gold" id="tb-money">$0</span>
      </span>
      <span class="topbar-stat" id="tb-runway-stat" title="How long current reserves can support the city">
        <span class="runway-icon">⏳</span><span class="v" id="tb-runway">∞</span>
      </span>
      <span class="topbar-stat" id="tb-trader-reset-stat" title="Time until trader daily buy/sell caps reset (UTC midnight)">
        <span>🔄</span><span class="v" id="tb-trader-reset">—</span>
      </span>
      <div class="topbar-actions">
        <button class="tb-btn tb-btn-icon tb-btn-bell" id="tb-bell" title="Notifications">🔔<span id="tb-bell-badge" class="tb-badge"></span></button>
        <button class="tb-btn tb-btn-icon tb-btn-more" id="tb-more" title="More">⋯<span id="tb-more-badge" class="tb-badge"></span></button>
        <div class="tb-more-menu" id="tb-more-menu" role="menu">
          <button class="tb-more-row" id="tb-expand">+ Expand parcel</button>
          <button class="tb-more-row" id="tb-help">📖 Buildings reference</button>
          <button class="tb-more-row" id="tb-settings">⚙ Settings</button>
        </div>
      </div>
    </div>
    <div class="topbar-row topbar-row-2">
      <span class="topbar-stat" id="tb-workers-stat" title="Workers employed / jobs available">
        <span>👷</span><span class="v workers" id="tb-workers">0/0</span><span class="labor-badge" id="tb-labor-badge" style="display:none;"> !</span>
      </span>
      <span class="topbar-stat" id="tb-pop-stat" title="Citizens / housing capacity">
        <span>👥</span><span class="v" id="tb-pop">0</span>
      </span>
      <span class="topbar-stat" id="tb-parcels-stat" title="Parcels claimed">
        <span>🗺</span><span class="v" id="tb-parcels">1</span>
      </span>
      <span class="topbar-stat" id="tb-happiness-stat" title="Citizen happiness (0–100)">
        <span id="tb-happiness-icon">🙂</span><span class="v" id="tb-happiness">50</span>
      </span>
      <span class="topbar-stat" id="tb-crime-stat" title="Crime (0–100, lower is better)">
        <span>🚨</span><span class="v" id="tb-crime">0</span>
      </span>
      <span class="topbar-stat" id="tb-migration-stat" title="Net population change per minute">
        <span id="tb-migration-icon">→</span><span class="v" id="tb-migration">0</span>
      </span>
      <span class="topbar-stat" id="tb-productivity-stat" title="Production multiplier (100% = baseline)">
        <span>⚒</span><span class="v" id="tb-productivity">100%</span>
      </span>
    </div>
  `;
  root.appendChild(bar);
  mounted = true;

  // ── More menu ──
  const closeMore = () => document.getElementById('tb-more-menu').classList.remove('open');
  const wireMore = (id, fn) => {
    document.getElementById(id).addEventListener('click', () => { closeMore(); fn(); });
  };
  document.getElementById('tb-more').addEventListener('click', (e) => {
    document.getElementById('tb-more-menu').classList.toggle('open');
    e.stopPropagation();
  });
  document.addEventListener('click', (e) => {
    if (!e.target.closest('#tb-more-menu') && !e.target.closest('#tb-more')) closeMore();
  });
  document.getElementById('tb-bell').addEventListener('click', openBellLog);
  wireMore('tb-expand', () => {
    openExpansionPanel(() => {
      refreshTopBar();
      if (onExpandedCallback) onExpandedCallback();
    });
  });
  wireMore('tb-help', openHelp);
  wireMore('tb-settings', openSettings);

  mountBellLog();

  // Wire each topbar stat to open the explanation modal on tap.
  // (Triple-tap on money is handled separately further down so it
  // doesn't conflict with single-tap-to-explain.)
  const wireStat = (id, key) => {
    const el = document.getElementById(id);
    if (!el) return;
    el.style.cursor = 'pointer';
    el.addEventListener('click', () => openStatInfo(key));
  };
  wireStat('tb-runway-stat', 'runway');
  wireStat('tb-workers-stat', 'workers');
  wireStat('tb-pop-stat', 'population');
  wireStat('tb-parcels-stat', 'parcels');
  wireStat('tb-happiness-stat', 'happiness');
  wireStat('tb-crime-stat', 'crime');
  wireStat('tb-migration-stat', 'migration');
  wireStat('tb-productivity-stat', 'productivity');

  // Triple-tap the money chip → server-side dev_grant_money cheat.
  // v1 has this as a developer convenience; same RPC, same gesture.
  let moneyTaps = 0;
  let moneyTapTimer = null;
  document.getElementById('tb-money-stat').addEventListener('click', async () => {
    moneyTaps++;
    if (moneyTapTimer) clearTimeout(moneyTapTimer);
    if (moneyTaps >= 3) {
      moneyTaps = 0;
      try {
        const { data, error } = await sb.rpc('dev_grant_money', { p_amount: 100000 });
        if (error) throw error;
        if (data?.money !== undefined) state.profile.money = data.money;
        refreshTopBar();
        showToast('+$100,000 (dev cheat)', 'success');
      } catch (err) {
        showToast('Cheat failed: ' + (err.message || err), 'error');
      }
      return;
    }
    moneyTapTimer = setTimeout(() => { moneyTaps = 0; }, 600);
  });

  // Trader reset countdown: refresh every second so the displayed
  // "Xh Ym" doesn't drift.
  if (traderResetInterval) clearInterval(traderResetInterval);
  traderResetInterval = setInterval(updateTraderResetCountdown, 1000);
  updateTraderResetCountdown();

  refreshTopBar();
}

// Update the Trade tab badge in the bottom panel from
// state.pendingIncomingOffers. Mirrors v1's `trade-badge` element
// — the count flashes red on the Trade tab when someone's sent
// you an offer.
export function refreshOffersBadge() {
  const n = state.pendingIncomingOffers || 0;
  const tradeBadge = document.getElementById('bp-trade-badge');
  if (tradeBadge) {
    if (n > 0) { tradeBadge.textContent = n > 9 ? '9+' : String(n); tradeBadge.classList.add('visible'); }
    else { tradeBadge.classList.remove('visible'); }
  }
}

export function refreshTopBar() {
  if (!mounted || !state.profile) return;
  const p = state.profile;
  const li = state.laborInfo;
  refreshOffersBadge();

  document.getElementById('tb-city').textContent = state.cityName || '—';
  document.getElementById('tb-district').textContent =
    p.district_name || p.display_name || '—';
  document.getElementById('tb-money').textContent = '$' + Math.floor(p.money || 0).toLocaleString();

  // Runway — money runway from tax revenue vs upkeep (v1 has a richer
  // food/lifestyle calc; this is the v2 first cut, money only).
  const r = computeCityRunway();
  const runwayEl = document.getElementById('tb-runway');
  const runwayStat = document.getElementById('tb-runway-stat');
  runwayEl.textContent = formatRunway(r.minutes);
  runwayStat.classList.remove('runway-stable', 'runway-warn', 'runway-bad');
  const bottleneckName = r.bottleneck === 'money' ? 'money'
    : r.bottleneck && state.resourceNodes[r.bottleneck] ? state.resourceNodes[r.bottleneck].name
    : r.bottleneck || 'reserves';
  if (!isFinite(r.minutes)) {
    runwayStat.classList.add('runway-stable');
    runwayStat.title = 'Reserves are sustainable — nothing is draining faster than it\'s being produced.';
  } else if (r.minutes < 60) {
    runwayStat.classList.add('runway-bad');
    runwayStat.title = 'CRITICAL: ' + bottleneckName + ' depletes in ' + formatRunway(r.minutes) + '.';
  } else if (r.minutes < 4 * 60) {
    runwayStat.classList.add('runway-warn');
    runwayStat.title = bottleneckName + ' depletes in ' + formatRunway(r.minutes) + '.';
  } else {
    runwayStat.title = 'Reserves last ' + formatRunway(r.minutes) + ' (bottleneck: ' + bottleneckName + ').';
  }

  // Workers: used/needed with shortage badge.
  const used = Math.max(0, li.workersUsed || 0);
  const needed = Math.max(0, li.workersNeeded || 0);
  const wv = document.getElementById('tb-workers');
  wv.textContent = used + '/' + needed;
  wv.className = 'v ' + (li.laborShortage ? 'shortage' : 'workers');
  document.getElementById('tb-labor-badge').style.display = li.laborShortage ? 'inline' : 'none';
  document.getElementById('tb-workers-stat').title =
    used + ' workers employed / ' + needed + ' jobs available';

  // Population: current / capacity. Capacity = post-tutorial 15-citizen
  // floor + sum of each active road-connected house's tier.workers.
  // Stash on laborInfo so other panels can re-use it without recomputing.
  const pop = Math.floor(p.population || 0);
  const cap = computeHousingCapacity(
    state.allBuildings, state.buildingTypes, state.housingTierConfig,
    state.currentUser?.id, p
  );
  li.housingCapacity = cap;
  document.getElementById('tb-pop').textContent = cap > 0 ? pop + '/' + cap : String(pop);
  document.getElementById('tb-pop-stat').title = pop + ' citizens / ' + cap + ' housing spaces';

  document.getElementById('tb-parcels').textContent = p.chunks_owned || 1;

  // Happiness — number + emotive icon switches at 25/50/75 thresholds.
  const h = Math.round(p.happiness || 0);
  document.getElementById('tb-happiness').textContent = h;
  document.getElementById('tb-happiness-icon').textContent =
    h <= 25 ? '☹' : h <= 50 ? '😐' : h <= 75 ? '🙂' : '😊';
  document.getElementById('tb-happiness-stat').title = 'Happiness ' + h + '/100';

  // Crime — colored by severity.
  const c = Math.round(p.crime || 0);
  const cv = document.getElementById('tb-crime');
  cv.textContent = c;
  cv.className = 'v ' + (c <= 25 ? 'crime-low' : c <= 50 ? 'crime-mid' : 'crime-high');
  document.getElementById('tb-crime-stat').title = 'Crime ' + c + '/100. ' +
    (c <= 25 ? 'Streets are quiet.' :
     c <= 50 ? 'Some unrest — consider more police coverage.' :
              'High crime is dragging down happiness.');

  // Migration — arrow + signed rate per minute.
  const rate = Number(p.migration_rate || 0);
  const rounded = Math.round(rate * 100) / 100;
  const mv = document.getElementById('tb-migration');
  const mi = document.getElementById('tb-migration-icon');
  if (rounded > 0.01) {
    mi.textContent = '↑'; mv.textContent = '+' + rounded.toFixed(2);
    mv.className = 'v migration-up';
  } else if (rounded < -0.01) {
    mi.textContent = '↓'; mv.textContent = rounded.toFixed(2);
    mv.className = 'v migration-down';
  } else {
    mi.textContent = '→'; mv.textContent = '0';
    mv.className = 'v migration-steady';
  }
  document.getElementById('tb-migration-stat').title = rounded > 0.01
    ? 'Citizens moving in: ' + rounded.toFixed(2) + '/min'
    : rounded < -0.01
      ? 'Citizens leaving: ' + Math.abs(rounded).toFixed(2) + '/min'
      : 'Population steady';

  // Productivity — % multiplier, colored by direction.
  const prod = p.productivity != null ? Number(p.productivity) : 1.0;
  const pct = Math.round(prod * 100);
  const pv = document.getElementById('tb-productivity');
  pv.textContent = pct + '%';
  pv.className = 'v ' + (pct >= 105 ? 'productivity-up' : pct < 100 ? 'productivity-down' : 'productivity-neutral');
  document.getElementById('tb-productivity-stat').title = pct === 100
    ? 'Production at baseline (100%)'
    : pct > 100 ? 'Production +' + (pct - 100) + '% above baseline'
                : 'Production ' + (pct - 100) + '% below baseline';
}

function updateTraderResetCountdown() {
  const v = document.getElementById('tb-trader-reset');
  if (!v) return;
  const now = new Date();
  const nextUtcMidnight = Date.UTC(
    now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate() + 1, 0, 0, 0, 0
  );
  let msLeft = Math.max(0, nextUtcMidnight - now.getTime());
  const totalMin = Math.floor(msLeft / 60000);
  const h = Math.floor(totalMin / 60);
  const m = totalMin % 60;
  if (h >= 1) v.textContent = h + 'h ' + m + 'm';
  else if (m >= 1) v.textContent = m + 'm';
  else v.textContent = Math.max(0, Math.floor(msLeft / 1000)) + 's';
}

export function unmountTopBar() {
  const el = document.getElementById('topbar');
  if (el) el.remove();
  mounted = false;
  if (traderResetInterval) {
    clearInterval(traderResetInterval);
    traderResetInterval = null;
  }
}
