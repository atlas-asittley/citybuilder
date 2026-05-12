// Build tab — v1-style categorized building list.
//
// Each row shows:
//   name · cost · workers · short description
//
// Visual state mirrors v1:
//   - selected (gold ring) — current placement target
//   - locked (greyed + reason) — blocked by tier-unlock or tutorial step
//   - unaffordable (red money) — not enough $ or resources
import { state } from '../../state/store.js';
import { tutorialAllowsBuilding, recipeOf, periodSuffix } from '../../scenes/helpers.js';

let selectedKey = null;

const CATEGORY_ORDER = [
  'housing', 'service', 'police', 'tax',
  'food_extractor', 'extractor', 'processor',
  'booster', 'park',
  'transport_hub', 'transport_connector',
  'road'
];
const CATEGORY_LABELS = {
  housing: 'Housing', service: 'Services', police: 'Police', tax: 'Tax',
  food_extractor: 'Food', extractor: 'Extractors', processor: 'Processors',
  booster: 'Boosters', park: 'Parks',
  transport_hub: 'Transport Hubs', transport_connector: 'Connectors',
  road: 'Road'
};

export function renderBuildTab(parent, onSelect) {
  const tutorialStep = state.profile?.tutorial_step;
  const grouped = {};
  for (const key in state.buildingTypes) {
    const bt = state.buildingTypes[key];
    if (!bt.category || !bt.is_active) continue;
    if (!tutorialAllowsBuilding(bt, tutorialStep)) continue;
    (grouped[bt.category] = grouped[bt.category] || []).push(bt);
  }

  const money = state.profile?.money || 0;
  const maxTierEver = state.profile?.highest_housing_tier_ever || 0;
  const inventory = state.inventory || {};
  const resourceCostsByKey = state.buildingResourceCosts || {};

  let html = '';
  for (const cat of CATEGORY_ORDER) {
    if (!grouped[cat] || !grouped[cat].length) continue;
    grouped[cat].sort((a, b) =>
      (a.tier_required || 0) - (b.tier_required || 0) ||
      a.name.localeCompare(b.name));
    html += `<div class="btp-section">
      <h3 class="btp-section-title">${CATEGORY_LABELS[cat] || cat}</h3>
      <div class="btp-items">`;
    for (const bt of grouped[cat]) {
      const cost = bt.build_cost || 0;
      const canAffordMoney = money >= cost;
      const resourceCosts = resourceCostsByKey[bt.key] || [];
      let canAffordResources = true;
      const resourceShortages = [];
      for (const rc of resourceCosts) {
        const have = Math.floor(inventory[rc.resource_key] || 0);
        if (have < rc.quantity) {
          canAffordResources = false;
          resourceShortages.push({ key: rc.resource_key, short: rc.quantity - have, want: rc.quantity });
        }
      }
      const canAfford = canAffordMoney && canAffordResources;
      const unlockTier = bt.unlocks_at_housing_tier;
      const unlocked = unlockTier == null || maxTierEver >= unlockTier;
      const isSelected = selectedKey === bt.key;

      const classes = ['btp-item'];
      if (isSelected) classes.push('selected');
      if (!unlocked) classes.push('locked');
      if (!canAfford && unlocked) classes.push('cant-afford');

      let lockHint = '';
      if (!unlocked) {
        const tierName = state.housingTierConfig?.[unlockTier]?.name || ('Tier ' + unlockTier);
        lockHint = `<div class="btp-lock">🔒 Unlocks at ${tierName}</div>`;
      }
      const resourceBits = resourceCosts.map((rc) => {
        const have = Math.floor(inventory[rc.resource_key] || 0);
        const short = have < rc.quantity;
        return `<span class="btp-meta-bit ${short ? 'btp-bit-short' : ''}">${rc.quantity} ${resName(rc.resource_key)}</span>`;
      }).join('');
      const description = describeBuilding(bt);

      html += `<button class="${classes.join(' ')}" data-key="${bt.key}" ${(!unlocked) ? 'disabled' : ''}>
        <div class="btp-head">
          <span class="btp-name">${bt.name || bt.key}</span>
          <span class="btp-cost ${!canAffordMoney ? 'cant-afford' : ''}">${cost ? '$' + cost : ''}</span>
        </div>
        <div class="btp-meta">
          ${bt.worker_cost > 0 ? `<span class="btp-meta-bit">👷 ${bt.worker_cost}</span>` : ''}
          ${bt.workers_provided ? `<span class="btp-meta-bit">🏠 ${bt.workers_provided}</span>` : ''}
          ${bt.coverage_radius > 0 ? `<span class="btp-meta-bit">📡 r${bt.coverage_radius}</span>` : ''}
          ${resourceBits}
        </div>
        <div class="btp-desc">${description}</div>
        ${lockHint}
      </button>`;
    }
    html += `</div></div>`;
  }
  parent.innerHTML = html || '<p class="btp-empty">No buildings available.</p>';

  parent.querySelectorAll('.btp-item').forEach((btn) => {
    btn.addEventListener('click', () => {
      if (btn.classList.contains('locked')) return;
      const key = btn.dataset.key;
      if (selectedKey === key) {
        selectedKey = null;
        btn.classList.remove('selected');
        onSelect(null);
      } else {
        selectedKey = key;
        parent.querySelectorAll('.btp-item').forEach((b) =>
          b.classList.toggle('selected', b === btn));
        onSelect(state.buildingTypes[key]);
      }
    });
  });
}

export function clearBuildTabSelection() {
  selectedKey = null;
  const root = document.getElementById('bp-content');
  if (root) root.querySelectorAll('.btp-item.selected').forEach((b) => b.classList.remove('selected'));
}

// Per-category descriptions. Processor / extractor recipes use the
// integer-ratio formatter so a sawmill reads as "2 timber → 1 lumber
// per 2 min" instead of "1 timber → 0.5 lumber/min". Service blurbs
// mention inputs explicitly ("consumes lumber + flour") so players
// know what to stockpile. Housing builds in the tier chain so the
// player sees the evolution arc at the card.
function describeBuilding(bt) {
  const cat = bt.category;
  if (cat === 'road') return 'Connects buildings to the city. Housing tier 3+ and most production need road access.';
  if (cat === 'housing') {
    return 'Citizens live here. Evolves: ' + housingTierChain() +
      '. Each upgrade adds a new prereq (well, food, school, temple, luxury food, industrial luxuries). Workers 2 → 100 across the ladder.';
  }
  if (cat === 'extractor') {
    const tile = bt.placement_resource_node_key
      ? resName(bt.placement_resource_node_key) + ' tile'
      : 'open tile';
    return `Harvests ${out(bt)}. Place on a ${tile.toLowerCase()}.`;
  }
  if (cat === 'food_extractor') {
    const tile = bt.placement_resource_node_key
      ? resName(bt.placement_resource_node_key) + ' tile'
      : 'open tile';
    return `Produces food: ${out(bt)}. Place on a ${tile.toLowerCase()}.`;
  }
  if (cat === 'processor') return `Recipe: ${ins(bt)} → ${out(bt)}.`;
  if (cat === 'service') {
    if (bt.key === 'well') return 'Lets housing within 4 tiles upgrade past Shanty. No inputs.';
    if (bt.key === 'school') return `Gates Townhouse (tier 3) within 5 tiles. Consumes ${ins(bt)} while staffed.`;
    if (bt.key === 'temple') return `Gates Villa (tier 4) within 6 tiles. Consumes ${ins(bt)} while staffed.`;
    if (bt.key === 'bathhouse') return `Stops nearby housing from devolving (4 tiles). Consumes ${ins(bt)} while staffed.`;
    if (bt.key === 'tavern') return `+5% productivity nearby (with a small crime hit). Consumes ${ins(bt)} while staffed.`;
    return `Service building. Needs road access. ${bt.input_resource_key ? 'Consumes ' + ins(bt) + ' while staffed.' : ''}`;
  }
  if (cat === 'police') {
    return `Covers ${bt.coverage_radius || 0} tiles for crime when staffed. $${bt.upkeep_per_minute || 0}/min upkeep while staffed.`;
  }
  if (cat === 'booster') {
    const pct = Math.round(((bt.boost_multiplier || 1) - 1) * 100);
    const tgt = bt.boost_target === 'food_extractor' ? 'food extractors' : 'extractors';
    return `+${pct}% to ${tgt} within ${bt.boost_range || 2} tiles. Multiple boosters take MAX, not stack.`;
  }
  if (cat === 'park') {
    return `Reduces pollution by ${Math.abs(bt.pollution_emit || 0)} on every tile within ${bt.pollution_radius || 0}. No staffing needed.`;
  }
  if (cat === 'tax') return `+$${bt.output_rate}/min per 100 citizens. A 200-pop city earns $${(bt.output_rate || 0) * 2}/min per office.`;
  if (cat === 'transport_hub') return 'Unlocks a city-wide procedural trade partner. Expand once to add another.';
  if (cat === 'transport_connector') return 'Routes city to other players\' transport hubs over the road network.';
  return bt.description || '';
}

// Output formatted in integer-ratio with explicit period.
function out(bt) {
  if (!bt.output_resource_key) return '—';
  const r = recipeOf(bt);
  return `${r.output_q} ${resName(bt.output_resource_key).toLowerCase()}${periodSuffix(r.period_min)}`;
}

// Inputs share the recipe's period; "2 timber + 1 statuary per 2 min".
function ins(bt) {
  const r = recipeOf(bt);
  const parts = [];
  if (bt.input_resource_key && bt.input_rate > 0) {
    parts.push(`${r.input_q} ${resName(bt.input_resource_key).toLowerCase()}`);
  }
  if (bt.input_resource_key_2 && bt.input_rate_2 > 0) {
    parts.push(`${r.input_q_2} ${resName(bt.input_resource_key_2).toLowerCase()}`);
  }
  if (!parts.length) return '—';
  return parts.join(' + ') + periodSuffix(r.period_min);
}

function resName(key) {
  return state.resourceNodes[key]?.name || key;
}

// "Shanty → Mud Hut → ... → Palace" from housingTierConfig. Bounded
// to whatever tiers the catalog has, so balance migrations that add /
// remove tiers don't strand stale copy here.
function housingTierChain() {
  const cfg = state.housingTierConfig || {};
  const names = [];
  for (let t = 0; t <= 8; t++) {
    if (cfg[t]?.name) names.push(cfg[t].name);
  }
  return names.length ? names.join(' → ') : '(tier chain not loaded)';
}
