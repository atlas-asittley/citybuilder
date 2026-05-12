// Bottom panel — v1's primary tabbed UI surface, mirrored as-is.
// Persistent strip at the bottom with three top-level tabs:
//
//   Build | City | Trade
//
// Plus subtabs within City (Resources / Treasury) and Trade
// (Partners / Black Market / Players). Two header controls:
//
//   Hide ▾  — collapse to just the tab bar
//   Full ▴  — expand to near-full-screen
//
// Each tab/subtab has its own renderer module (BuildTabPanel,
// CityResources rendered into the City > Resources area, etc.).
// BottomPanel just owns the chrome + tab switching.
import { renderBuildTab } from './bottompanel/BuildTabPanel.js';
import { renderCityResources } from './bottompanel/CityResourcesTab.js';
import { renderCityTreasury } from './bottompanel/CityTreasuryTab.js';
import { renderTradePartners } from './bottompanel/TradePartnersTab.js';
import { renderTradeBlackMarket } from './bottompanel/TradeBlackMarketTab.js';
import { renderTradePlayers } from './bottompanel/TradePlayersTab.js';

let mounted = false;
let currentTab = 'build';
let currentSubtab = { city: 'resources', trade: 'partners' };
let onBuildSelect = null;

export function mountBottomPanel(opts = {}) {
  if (mounted) return;
  onBuildSelect = opts.onBuildSelect || null;

  const root = document.getElementById('ui-root');
  const panel = document.createElement('div');
  panel.id = 'bottom-panel';
  panel.innerHTML = `
    <div class="bp-controls">
      <button class="bp-ctrl" id="bp-hide">Hide ▾</button>
      <button class="bp-ctrl" id="bp-full">Full ▴</button>
    </div>
    <div class="bp-tabs">
      <button class="bp-tab active" data-tab="build">Build</button>
      <button class="bp-tab" data-tab="city">City</button>
      <button class="bp-tab" data-tab="trade">Trade<span class="tab-badge" id="bp-trade-badge"></span></button>
    </div>
    <div class="bp-content" id="bp-content"></div>
  `;
  root.appendChild(panel);
  mounted = true;

  panel.querySelectorAll('.bp-tab').forEach((btn) => {
    btn.addEventListener('click', () => switchTab(btn.dataset.tab));
  });

  document.getElementById('bp-hide').addEventListener('click', () => {
    panel.classList.toggle('collapsed');
    // Mirror to body class so sibling fixed elements (zoom controls,
    // heatmap toggle, tutorial banner) can reposition via CSS without
    // a JS handler each.
    document.body.classList.toggle('bp-collapsed', panel.classList.contains('collapsed'));
    document.getElementById('bp-hide').textContent =
      panel.classList.contains('collapsed') ? 'Show ▴' : 'Hide ▾';
    panel.classList.remove('full');
    document.body.classList.remove('bp-full');
    document.getElementById('bp-full').textContent = 'Full ▴';
  });
  document.getElementById('bp-full').addEventListener('click', () => {
    panel.classList.toggle('full');
    document.body.classList.toggle('bp-full', panel.classList.contains('full'));
    document.getElementById('bp-full').textContent =
      panel.classList.contains('full') ? 'Compact ▾' : 'Full ▴';
    panel.classList.remove('collapsed');
    document.body.classList.remove('bp-collapsed');
    document.getElementById('bp-hide').textContent = 'Hide ▾';
  });

  renderActiveTab();
}

export function refreshBottomPanel() {
  if (!mounted) return;
  // Skip the refresh if the user is mid-interaction with the panel
  // (typing in a policy input, focused on a select). Mirrors v1's
  // refreshActiveDataPanelIfIdle so tick-time re-renders don't blow
  // away unsaved input. The panel still re-renders the next time
  // they tap somewhere else.
  const focused = document.activeElement;
  if (focused && focused.closest && focused.closest('#bottom-panel')) {
    const tag = focused.tagName?.toLowerCase();
    if (tag === 'input' || tag === 'select' || tag === 'textarea') return;
  }
  renderActiveTab();
}

function switchTab(tab) {
  currentTab = tab;
  const panel = document.getElementById('bottom-panel');
  panel.querySelectorAll('.bp-tab').forEach((b) =>
    b.classList.toggle('active', b.dataset.tab === tab));
  renderActiveTab();
}

function renderActiveTab() {
  const content = document.getElementById('bp-content');
  if (!content) return;
  if (currentTab === 'build') {
    renderBuildTab(content, (bt) => onBuildSelect?.(bt));
    return;
  }
  if (currentTab === 'city') {
    renderSubtabs(content, 'city',
      [
        { key: 'resources', label: 'Resources' },
        { key: 'treasury',  label: 'Treasury' }
      ],
      (sub, body) => {
        if (sub === 'resources') renderCityResources(body);
        else if (sub === 'treasury') renderCityTreasury(body);
      });
    return;
  }
  if (currentTab === 'trade') {
    renderSubtabs(content, 'trade',
      [
        { key: 'partners',     label: 'Partners' },
        { key: 'black_market', label: 'Black Market' },
        { key: 'players',      label: 'Players' }
      ],
      (sub, body) => {
        if (sub === 'partners') renderTradePartners(body);
        else if (sub === 'black_market') renderTradeBlackMarket(body);
        else if (sub === 'players') renderTradePlayers(body);
      });
    return;
  }
}

function renderSubtabs(parent, tabKey, options, render) {
  const active = currentSubtab[tabKey];
  parent.innerHTML = `
    <div class="bp-subtabs">
      ${options.map((o) =>
        `<button class="bp-subtab ${o.key === active ? 'active' : ''}" data-sub="${o.key}">${o.label}</button>`
      ).join('')}
    </div>
    <div class="bp-subbody" id="bp-subbody"></div>
  `;
  parent.querySelectorAll('.bp-subtab').forEach((btn) => {
    btn.addEventListener('click', () => {
      currentSubtab[tabKey] = btn.dataset.sub;
      parent.querySelectorAll('.bp-subtab').forEach((b) =>
        b.classList.toggle('active', b === btn));
      render(btn.dataset.sub, document.getElementById('bp-subbody'));
    });
  });
  render(active, document.getElementById('bp-subbody'));
}
