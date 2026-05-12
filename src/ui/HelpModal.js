// Help modal — buildings reference. Lists every building type the
// catalog knows about, grouped by industry section (Infrastructure /
// Civic / Timber / Stone / Clay / Iron), with each card showing:
//   build cost · workers · inputs/outputs · coverage radius · description
//
// v1's help.js renders a richer per-category breakdown with full
// recipe scaling; this is the v2 first cut that hits the same
// information needs.
import { state } from '../state/store.js';

let mounted = false;

const SECTION_ORDER = ['infra', 'civic', 'timber', 'stone', 'clay', 'iron'];
const SECTION_TITLES = {
  infra:  'Infrastructure',
  civic:  'Civic & Services',
  timber: 'Timber Industry',
  stone:  'Stone Industry',
  clay:   'Clay Industry',
  iron:   'Iron Industry'
};
const CATEGORY_ORDER = {
  road: 0, housing: 1,
  extractor: 2, food_extractor: 3,
  processor: 4, booster: 5,
  service: 6, tax: 7, police: 8,
  park: 9, transport_hub: 10, transport_connector: 11
};

export function openHelp() {
  if (mounted) return;
  mounted = true;

  const root = document.getElementById('ui-root');
  const overlay = document.createElement('div');
  overlay.id = 'help-overlay';
  overlay.innerHTML = `
    <div class="hl-card">
      <div class="hl-header">
        <h2>Buildings reference</h2>
        <button class="hl-close" aria-label="Close">×</button>
      </div>
      <div class="hl-body" id="hl-body"></div>
    </div>
  `;
  root.appendChild(overlay);

  const close = () => { overlay.remove(); mounted = false; };
  overlay.querySelector('.hl-close').addEventListener('click', close);
  overlay.addEventListener('click', (e) => { if (e.target === overlay) close(); });

  render();
}

function render() {
  const body = document.getElementById('hl-body');
  if (!body) return;

  const grouped = {};
  for (const key in state.buildingTypes) {
    const bt = state.buildingTypes[key];
    if (!bt.is_active) continue;
    const sec = sectionFor(bt);
    (grouped[sec] = grouped[sec] || []).push(bt);
  }

  let html = '';
  for (const sec of SECTION_ORDER) {
    const list = grouped[sec];
    if (!list || !list.length) continue;
    list.sort((a, b) => {
      const ca = CATEGORY_ORDER[a.category] ?? 99;
      const cb = CATEGORY_ORDER[b.category] ?? 99;
      if (ca !== cb) return ca - cb;
      return (a.tier_required || 0) - (b.tier_required || 0) || a.name.localeCompare(b.name);
    });
    html += `<h3 class="hl-section">${SECTION_TITLES[sec]}</h3>`;
    html += list.map(renderCard).join('');
  }
  body.innerHTML = html || '<p class="hl-empty">No buildings loaded yet.</p>';
}

function sectionFor(bt) {
  if (bt.category === 'road' || bt.category === 'housing') return 'infra';
  if (bt.industry_key === 'common') return 'civic';
  if (bt.industry_key === 'timber') return 'timber';
  if (bt.industry_key === 'stone')  return 'stone';
  if (bt.industry_key === 'clay')   return 'clay';
  if (bt.industry_key === 'iron')   return 'iron';
  return 'civic';
}

function renderCard(bt) {
  const rows = [];
  if (bt.build_cost) rows.push(`<span class="hl-label">Cost</span><span class="hl-value">$${bt.build_cost}</span>`);
  if (bt.worker_cost) rows.push(`<span class="hl-label">Workers</span><span class="hl-value">${bt.worker_cost}</span>`);
  if (bt.workers_provided) rows.push(`<span class="hl-label">Houses</span><span class="hl-value">${bt.workers_provided} citizens</span>`);
  if (bt.input_resource_key && bt.input_rate > 0) {
    const ins = [`${bt.input_rate} ${resName(bt.input_resource_key)}`];
    if (bt.input_resource_key_2 && bt.input_rate_2 > 0) {
      ins.push(`${bt.input_rate_2} ${resName(bt.input_resource_key_2)}`);
    }
    rows.push(`<span class="hl-label">Input</span><span class="hl-value">${ins.join(' + ')}/min</span>`);
  }
  if (bt.output_resource_key && bt.output_rate > 0) {
    if (bt.category === 'tax') {
      rows.push(`<span class="hl-label">Revenue</span><span class="hl-value">$${bt.output_rate}/min per 100 pop</span>`);
    } else {
      rows.push(`<span class="hl-label">Output</span><span class="hl-value">${bt.output_rate} ${resName(bt.output_resource_key)}/min</span>`);
    }
  }
  if (bt.coverage_radius > 0) rows.push(`<span class="hl-label">Coverage</span><span class="hl-value">${bt.coverage_radius} tiles</span>`);
  if (bt.boost_multiplier && bt.boost_multiplier > 1) {
    const pct = Math.round((bt.boost_multiplier - 1) * 100);
    const target = bt.boost_target === 'food_extractor' ? 'food extractors' : 'extractors';
    rows.push(`<span class="hl-label">Boost</span><span class="hl-value">+${pct}% to ${target} within ${bt.boost_range || 2} tiles</span>`);
  }
  if (bt.upkeep_per_minute > 0) rows.push(`<span class="hl-label">Upkeep</span><span class="hl-value">$${bt.upkeep_per_minute}/min</span>`);
  if (bt.placement_resource_node_key) {
    rows.push(`<span class="hl-label">Tile</span><span class="hl-value">on ${resName(bt.placement_resource_node_key)}</span>`);
  }
  if (bt.pollution_emit > 0) {
    rows.push(`<span class="hl-label">Pollution</span><span class="hl-value">${bt.pollution_emit} emit, r${bt.pollution_radius}</span>`);
  }
  if ((bt.footprint_w || 1) > 1 || (bt.footprint_h || 1) > 1) {
    rows.push(`<span class="hl-label">Footprint</span><span class="hl-value">${bt.footprint_w}×${bt.footprint_h}</span>`);
  }

  return `
    <div class="hl-bldg">
      <div class="hl-bldg-head">
        <span class="hl-bldg-name">${bt.name || bt.key}</span>
        <span class="hl-bldg-cat">${bt.category}</span>
      </div>
      <div class="hl-rows">${rows.join('')}</div>
      ${bt.description ? `<div class="hl-desc">${escapeHtml(bt.description)}</div>` : ''}
    </div>
  `;
}

function resName(key) {
  return (state.resourceNodes[key]?.name || key).toLowerCase();
}

function escapeHtml(s) {
  return String(s || '').replace(/[&<>"]/g, (c) => ({
    '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;'
  }[c]));
}
