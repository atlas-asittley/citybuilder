// Help modal — buildings reference. Lists every building type the
// catalog knows about, grouped by industry section (Infrastructure /
// Civic / Timber / Stone / Clay / Iron), with each card showing:
//   build cost · workers · inputs/outputs · coverage radius · description
//
// v1's help.js renders a richer per-category breakdown with full
// recipe scaling; this is the v2 first cut that hits the same
// information needs.
import { state } from '../state/store.js';
import { recipeOf, periodSuffix } from '../scenes/helpers.js';
import { spriteIcons } from '../sprites.js';
import { escapeHtml, resNameLower as resName } from './util.js';

// Module-scope expanded card set — persists across re-renders so
// clicking a card and waiting for an inadvertent re-render (none
// today, but future tick-driven refreshes) keeps the card open.
const expanded = new Set();

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

  // Wire click-to-expand on each card header.
  body.querySelectorAll('.hl-bldg-toggle').forEach((header) => {
    header.addEventListener('click', () => {
      const card = header.parentElement;
      const key = card.dataset.key;
      if (!key) return;
      if (expanded.has(key)) expanded.delete(key);
      else expanded.add(key);
      render();
    });
  });
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
  // Integer-ratio recipe rows: "2 timber per 2 min" reads cleaner
  // than "1 timber/min" or "0.5 timber/min" depending on rate.
  if (bt.input_resource_key && bt.input_rate > 0) {
    const r = recipeOf(bt);
    const ins = [`${r.input_q} ${resName(bt.input_resource_key)}`];
    if (bt.input_resource_key_2 && bt.input_rate_2 > 0) {
      ins.push(`${r.input_q_2} ${resName(bt.input_resource_key_2)}`);
    }
    rows.push(`<span class="hl-label">Input</span><span class="hl-value">${ins.join(' + ')}${periodSuffix(r.period_min)}</span>`);
  }
  if (bt.output_resource_key && bt.output_rate > 0) {
    if (bt.category === 'tax') {
      rows.push(`<span class="hl-label">Revenue</span><span class="hl-value">$${bt.output_rate}/min per 100 pop</span>`);
    } else {
      const r = recipeOf(bt);
      rows.push(`<span class="hl-label">Output</span><span class="hl-value">${r.output_q} ${resName(bt.output_resource_key)}${periodSuffix(r.period_min)}</span>`);
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

  // Plain-language "what this does" line — fills the gap between raw
  // mechanic rows above and the catalog description below. Surfaces
  // non-output effects (service gating, booster %, police coverage,
  // tax scaling) in player-readable form.
  const benefit = benefitText(bt);
  // Unlock blurb for buildings whose only purpose is gating a higher
  // housing tier (school / temple / industrial luxuries).
  const unlock = unlockBlurb(bt);
  const isOpen = expanded.has(bt.key);
  // Housing gets the full 9-tier breakdown appended below the rows so
  // the player sees the whole evolution ladder + every prereq at each
  // step + the per-house drain rates. Only renders when expanded.
  const housingDetail = (bt.category === 'housing' && isOpen) ? renderHousingTierBreakdown() : '';

  const iconUri = spriteIcons[bt.key];
  const iconHtml = iconUri
    ? `<img class="hl-bldg-icon" src="${iconUri}" alt="" />`
    : `<div class="hl-bldg-icon hl-bldg-icon-fallback"></div>`;
  return `
    <div class="hl-bldg ${isOpen ? 'hl-bldg-open' : ''}" data-key="${escapeHtml(bt.key)}">
      <div class="hl-bldg-head hl-bldg-toggle">
        <span class="hl-chev">${isOpen ? '▾' : '▸'}</span>
        ${iconHtml}
        <span class="hl-bldg-name">${escapeHtml(bt.name || bt.key)}</span>
        <span class="hl-bldg-cat">${escapeHtml(bt.category)}</span>
        ${bt.build_cost ? `<span class="hl-bldg-cost">$${bt.build_cost}</span>` : ''}
      </div>
      ${benefit ? `<div class="hl-benefit">${escapeHtml(benefit)}</div>` : ''}
      ${isOpen ? `
        ${unlock  ? `<div class="hl-unlock">🔒 ${escapeHtml(unlock)}</div>` : ''}
        <div class="hl-rows">${rows.join('')}</div>
        ${bt.description ? `<div class="hl-desc">${escapeHtml(bt.description)}</div>` : ''}
        ${housingDetail}
      ` : ''}
    </div>
  `;
}

// Plain-language gameplay summary per building. Where the effect IS
// "produces X", we lean on the Output row above and skip the line.
function benefitText(bt) {
  if (bt.category === 'road') {
    return 'Connects buildings to the city. Required for housing tier 3+ and most production.';
  }
  if (bt.category === 'housing') {
    return 'Houses citizens, contributing workers to your city. Evolves through nine tiers as services + food + luxuries become available.';
  }
  if (bt.category === 'extractor') {
    return `Your district's source of ${resName(bt.output_resource_key)}. Place near a matching resource patch.`;
  }
  if (bt.category === 'food_extractor') {
    return `Produces ${resName(bt.output_resource_key)} to feed your population. Higher-tier housing requires food in stock.`;
  }
  if (bt.category === 'processor') {
    const inText = [resName(bt.input_resource_key)];
    if (bt.input_resource_key_2) inText.push(resName(bt.input_resource_key_2));
    return `Refines ${inText.join(' + ')} into ${resName(bt.output_resource_key)}.`;
  }
  if (bt.category === 'booster') {
    const pct = Math.round(((bt.boost_multiplier || 1) - 1) * 100);
    const target = bt.boost_target === 'food_extractor' ? 'food extractors' : 'extractors';
    return `Boosts every ${target} within ${bt.boost_range || 2} tiles by +${pct}%. Stack one near each cluster.`;
  }
  if (bt.category === 'service') {
    if (bt.key === 'well')      return 'Lets housing within 4 tiles upgrade past Shanty.';
    if (bt.key === 'tavern')    return 'Boosts city productivity by +5% while staffed and fed. Consumes bread + pottery, with a small crime cost.';
    if (bt.key === 'bathhouse') return 'Stops nearby housing from devolving when conditions slip.';
    if (bt.key === 'school')    return 'Gates Townhouse (tier 3) evolution for any housing within 5 tiles.';
    if (bt.key === 'temple')    return 'Gates Villa (tier 4) evolution for any housing within 6 tiles.';
    if (bt.key === 'hospital')  return `Reduces city-wide crime by ${bt.crime_reduction || 0} while staffed. Consumes ale — competes with high-tier housing for it.`;
    return 'Service building.';
  }
  if (bt.category === 'civic') {
    if (bt.key === 'marketplace') {
      return `Adds +${bt.trade_sell_bonus_pct || 0}% to trader sell prices city-wide while staffed (across-marketplace cap at +25%). Generates a small amount of crime.`;
    }
    const bonus = bt.desirability_bonus || 0;
    const radius = bt.desirability_radius || 0;
    const draw = Number(bt.migration_bonus || 0);
    const drawSentence = draw > 0
      ? ` Draws +${draw.toFixed(2)} citizens/min while staffed.`
      : '';
    return `Adds +${bonus} desirability to every tile within ${radius} squares while staffed.${drawSentence}`;
  }
  if (bt.category === 'tax') {
    return `Tax revenue scales with population: $${bt.output_rate || 0}/min per 100 citizens. A city of 200 generates $${(bt.output_rate || 0) * 2}/min per office.`;
  }
  if (bt.category === 'police') {
    return `Reduces crime in housing within ${bt.coverage_radius || 0} tiles. Crime over 50 pushes citizens out of the city.`;
  }
  if (bt.category === 'sanitation') {
    return `Collects waste for housing within ${bt.coverage_radius || 0} tiles while staffed. Uncovered homes build up waste, which drags down desirability. The Incinerator needs Machinery to build.`;
  }
  if (bt.category === 'power') {
    const fuel = bt.input_resource_key
      ? ` Burns ${resName(bt.input_resource_key)} while running (needs Machinery to build).`
      : ' No fuel needed.';
    return `Generates +${bt.power_output || 0} power while staffed.${fuel} Processors and transport hubs consume power; a shortage will throttle production once that mechanic is switched on.`;
  }
  if (bt.category === 'park') {
    return `Dampens pollution by ${Math.abs(bt.pollution_emit || 0)} on every tile within ${bt.pollution_radius || 0}. No staffing needed.`;
  }
  if (bt.category === 'transport_hub') {
    return 'Unlocks a city-wide procedural trade partner. Expand once to add another partner from the pool.';
  }
  if (bt.category === 'transport_connector') {
    return 'Routes your city to other players\' transport hubs over the road network.';
  }
  return null;
}

// Buildings whose only purpose is to gate a higher housing tier
// surface that prereq prominently. The build menu also shows this as
// a 🔒 row when the player hasn't unlocked the tier yet.
function unlockBlurb(bt) {
  if (bt.unlocks_at_housing_tier == null) return null;
  const tierName = state.housingTierConfig?.[bt.unlocks_at_housing_tier]?.name
    || ('Tier ' + bt.unlocks_at_housing_tier);
  return `Locked until you reach ${tierName} housing.`;
}

// 9-tier evolution ladder rendered into the housing card. Reads from
// state.housingTierConfig + state.housingLifestyleDemands so the
// numbers stay current as balance migrations move them — never
// hardcoded.
function renderHousingTierBreakdown() {
  const tiers = state.housingTierConfig || {};
  const demands = state.housingLifestyleDemands || {};

  const chain = [];
  for (let t = 0; t <= 8; t++) {
    if (tiers[t]) chain.push(tiers[t].name);
  }
  let html = `
    <div class="hl-tier-banner">
      <div class="hl-tier-chain">${escapeHtml(chain.join(' → '))}</div>
      <p class="hl-tier-explainer">
        Houses evolve through these tiers automatically as their needs
        are met, and devolve a tier when a need fails (after a grace
        window). Lifestyle goods stack — once a tier earns a good,
        every higher tier keeps needing it. Some demands are
        satisfied by any of a group of goods, listed equally (e.g.
        bread / spices / caviar / spirits — keep any of them stocked,
        in any combination). Tap any house in the city to see its
        exact next-upgrade blockers.
      </p>
    </div>
  `;
  for (let t = 0; t <= 8; t++) {
    const cfg = tiers[t];
    if (!cfg) continue;
    html += renderTierBlock(t, cfg, demands, tiers);
  }
  return html;
}

function renderTierBlock(tier, cfg, demands, allTiers) {
  const workers = cfg.workers || 0;
  const prevTier = allTiers?.[tier - 1];
  const prevWorkers = prevTier?.workers || 0;
  const workerDelta = workers - prevWorkers;
  const foodPerMin = Number(cfg.food_per_minute || 0);
  const foodPerHour = Math.round(foodPerMin * 60);
  const upgradeSecs = Number(cfg.upgrade_secs || 0);
  const devolveSecs = Number(cfg.devolve_secs || 0);

  const prereqs = [];
  if (tier === 1) {
    prereqs.push('any well in your district');
  } else if (tier > 0) {
    if (cfg.needs_well)   prereqs.push('well within 4 tiles');
    if (cfg.needs_road)   prereqs.push('road-connected');
    if (cfg.needs_food)   prereqs.push('food in stock (any food type)');
    if (cfg.needs_school) prereqs.push('operating school within 5 tiles');
    if (cfg.needs_temple) prereqs.push('operating temple within 6 tiles');
    if (cfg.needs_luxury_food) prereqs.push('a luxury food in stock');
    if (cfg.needs_all_industrial_luxuries) {
      prereqs.push('ALL FOUR industrial luxuries (cabinets + monuments + mosaics + machinery)');
    } else if (cfg.needs_industrial_luxury) {
      prereqs.push('an industrial luxury in stock');
    }
    if (cfg.min_desirability > 0) prereqs.push(`desirability ≥ ${cfg.min_desirability}/100`);
  }

  const lifestyleRows = (demands[tier] || []).slice().sort((a, b) =>
    a.resource_key.localeCompare(b.resource_key));
  const subsMap = state.lifestyleSubstitutes || {};
  const drainParts = [];
  if (foodPerHour > 0) drainParts.push(`${foodPerHour} food/hr`);
  for (const d of lifestyleRows) {
    const perHour = Math.round(Number(d.qty_per_minute) * 60 * 10) / 10;
    const subs = subsMap[d.resource_key] || [];
    const label = subs.length > 0
      ? `${[d.resource_key, ...subs].map(resName).join('/')}/hr`
      : `${resName(d.resource_key)}/hr`;
    drainParts.push(`${perHour} ${label}`);
  }

  const lifestyleGoodsLine = lifestyleRows.length > 0
    ? `<div class="hl-tier-line"><i>Lifestyle goods (must stay stocked):</i> ${lifestyleGoodHtml(lifestyleRows)}</div>`
    : '';

  const headerExtras = [];
  if (workerDelta > 0 && tier > 0) headerExtras.push(`+${workerDelta} vs prev tier`);
  if (upgradeSecs > 0) headerExtras.push(`upgrade after ${upgradeSecs}s`);
  if (devolveSecs > 0) headerExtras.push(`${devolveSecs}s devolve grace`);

  return `
    <div class="hl-tier-block hl-tier-t${tier}">
      <div class="hl-tier-head">${escapeHtml(cfg.name)} <small>tier ${tier} · houses ${workers}${headerExtras.length ? ' · ' + headerExtras.join(' · ') : ''}</small></div>
      ${prereqs.length > 0
        ? `<div class="hl-tier-line"><i>Needs:</i> ${escapeHtml(prereqs.join(' · '))}</div>`
        : tier === 0
          ? `<div class="hl-tier-line"><i>No prereqs</i> — placed as Shanty, then evolves automatically.</div>`
          : ''}
      ${lifestyleGoodsLine}
      ${drainParts.length > 0
        ? `<div class="hl-tier-line"><i>Per-house drain:</i> ${escapeHtml(drainParts.join(' · '))}</div>`
        : ''}
    </div>
  `;
}

// Render the lifestyle-goods list. When a demand has multiple
// acceptable goods (e.g. bread/spices/caviar/spirits), all of them are
// listed inline as equals — no good is treated as the canonical one.
function lifestyleGoodHtml(rows) {
  const subsMap = state.lifestyleSubstitutes || {};
  return rows.map((d) => {
    const primary = resName(d.resource_key);
    const subs = subsMap[d.resource_key] || [];
    if (subs.length === 0) return escapeHtml(primary);
    const allNames = [primary, ...subs.map(resName)].join(' / ');
    return `<span class="hl-group">any of ${escapeHtml(allNames)}</span>`;
  }).join(' + ');
}


