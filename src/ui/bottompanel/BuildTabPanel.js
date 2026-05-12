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

// Tutorial steps gate which buildings appear. Mirrors v1's
// tutorialAllowsBuilding from ui.js.
function tutorialAllowsBuilding(bt) {
  const step = state.profile?.tutorial_step ?? 4;
  if (step >= 4) return true;
  if (!bt) return false;
  if (bt.category === 'road') return true;
  if (step === 0) return bt.category === 'housing';
  if (step === 1) return bt.category === 'housing' || bt.key === 'well';
  if (step === 2) return bt.category === 'housing' || bt.key === 'well' || bt.category === 'food_extractor';
  if (step === 3) {
    return bt.category === 'housing' || bt.key === 'well'
      || bt.category === 'food_extractor' || bt.category === 'extractor';
  }
  return false;
}

export function renderBuildTab(parent, onSelect) {
  const grouped = {};
  for (const key in state.buildingTypes) {
    const bt = state.buildingTypes[key];
    if (!bt.category || !bt.is_active) continue;
    if (!tutorialAllowsBuilding(bt)) continue;
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

// Short v1-style descriptions per category. Doesn't try to recreate
// every nuance from v1 (recipe-period scaling, specific service
// blurbs) — covers the main signal each row needs.
function describeBuilding(bt) {
  const cat = bt.category;
  if (cat === 'road') return 'Connects buildings to the city. Housing and processors need road access.';
  if (cat === 'housing') return 'Citizens live here. Upgrades unlock as you provide services + food.';
  if (cat === 'extractor') {
    const tile = bt.placement_resource_node_key ? resName(bt.placement_resource_node_key) + ' tile' : 'open tile';
    return `Harvests ${out(bt)}. Place on a ${tile.toLowerCase()}.`;
  }
  if (cat === 'food_extractor') {
    const tile = bt.placement_resource_node_key ? resName(bt.placement_resource_node_key) + ' tile' : 'open tile';
    return `Produces food: ${out(bt)}. Place on a ${tile.toLowerCase()}.`;
  }
  if (cat === 'processor') return `Recipe: ${ins(bt)} → ${out(bt)}.`;
  if (cat === 'service') {
    if (bt.key === 'well') return 'Lets housing within 4 tiles upgrade past tier 0.';
    if (bt.key === 'school') return 'Gates Townhouse (tier 3) within 5 tiles.';
    if (bt.key === 'temple') return 'Gates Villa (tier 4) within 6 tiles.';
    if (bt.key === 'bathhouse') return 'Stops nearby housing from devolving (4 tiles).';
    if (bt.key === 'tavern') return '+5% productivity nearby (with a small crime hit).';
    return 'Service building. Needs road access.';
  }
  if (cat === 'police') {
    return `Covers ${bt.coverage_radius || 0} tiles for crime. $${bt.upkeep_per_minute || 0}/min upkeep.`;
  }
  if (cat === 'booster') {
    const pct = Math.round(((bt.boost_multiplier || 1) - 1) * 100);
    const tgt = bt.boost_target === 'food_extractor' ? 'food extractors' : 'extractors';
    return `+${pct}% to ${tgt} within ${bt.boost_range || 2} tiles.`;
  }
  if (cat === 'park') {
    return `Reduces pollution by ${Math.abs(bt.pollution_emit || 0)} within ${bt.pollution_radius || 0} tiles.`;
  }
  if (cat === 'tax') return `+$${bt.output_rate}/min per 100 citizens.`;
  if (cat === 'transport_hub') return 'Unlocks a city-wide trade partner. Expandable.';
  if (cat === 'transport_connector') return 'Routes city to other players\' transport hubs.';
  return bt.description || '';
}

function out(bt) {
  if (!bt.output_resource_key) return '—';
  return `${bt.output_rate} ${resName(bt.output_resource_key).toLowerCase()}/min`;
}
function ins(bt) {
  const parts = [];
  if (bt.input_resource_key && bt.input_rate > 0) {
    parts.push(`${bt.input_rate} ${resName(bt.input_resource_key).toLowerCase()}`);
  }
  if (bt.input_resource_key_2 && bt.input_rate_2 > 0) {
    parts.push(`${bt.input_rate_2} ${resName(bt.input_resource_key_2).toLowerCase()}`);
  }
  return parts.join(' + ') || '—';
}
function resName(key) {
  return state.resourceNodes[key]?.name || key;
}
