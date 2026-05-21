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
import { spriteIcons } from '../../sprites.js';

let selectedKey = null;

// Accordion mode — exactly one section open at a time. Persisted to
// localStorage so the player's last-open section comes back on reload.
//   null = user has never picked a section, auto-open the first one
//          that has buildings (so a fresh player sees SOMETHING)
//   ''   = user explicitly collapsed the open section, respect it
//   '<section>' = that section is open (infra/industry/farming/civic/transport)
// Atlas 2026-05-15: the original code coerced null → '' on load,
// which made clicks-to-close trigger the auto-open path and snap
// the first section back open. The null vs '' distinction is what
// lets the player close the last section without it re-opening.
// Key changed v2→v3 because the values now hold section names, not
// raw category names — old values would map to invalid sections.
const OPEN_KEY = 'city_build_open_v3';
let openSection = (() => {
  try { return localStorage.getItem(OPEN_KEY); } catch (_e) { return null; }
})();
function setOpenSection(cat) {
  openSection = cat;
  try { localStorage.setItem(OPEN_KEY, cat); } catch (_e) { /* no-op */ }
}

// Top-level sections — matches v1's panels.js (Atlas 2026-05-15:
// "make the buildings tab match the old one"). Two-level grouping:
// every building maps to one section via sectionFor(bt), then sorted
// within the section by category → tier → name.
const SECTION_ORDER = ['infra', 'industry', 'farming', 'civic', 'transport'];

// Category sort order within each section. Pulled out of v1's
// CATEGORY_ORDER so sub-groupings stay stable across re-renders.
const CATEGORY_RANK = {
  road: 0, housing: 1, extractor: 2, food_extractor: 3,
  processor: 4, booster: 5, service: 6, tax: 7, police: 8, park: 9,
  transport_hub: 10, transport_connector: 11
};

// Map a building_type to its top-level section. Mirrors v1's
// sectionFor in panels.js so the v2 menu groups identically.
//   infra     = roads + housing
//   industry  = the player's resource chain (extractor + non-food
//               processor + resource booster)
//   farming   = food chain (food_extractor + food-output processor
//               + food booster)
//   civic     = services + tax + police + park (industry_key='common')
//   transport = transport_hub + transport_connector
function sectionFor(bt) {
  if (bt.category === 'road' || bt.category === 'housing') return 'infra';
  if (bt.category === 'transport_hub' || bt.category === 'transport_connector') return 'transport';
  if (bt.industry_key === 'common') return 'civic';
  if (bt.category === 'food_extractor') return 'farming';
  if (bt.category === 'extractor') return 'industry';
  if (bt.category === 'booster') {
    return bt.boost_target === 'food_extractor' ? 'farming' : 'industry';
  }
  if (bt.category === 'processor') {
    const out = state.resourceNodes?.[bt.output_resource_key];
    return out?.is_food ? 'farming' : 'industry';
  }
  return 'industry';
}

function sectionTitles(industryKey) {
  const name = industryKey
    ? industryKey.charAt(0).toUpperCase() + industryKey.slice(1)
    : 'Industry';
  return {
    infra: 'Infrastructure',
    industry: name + ' Industry',
    farming: 'Farming',
    civic: 'Civic & Services',
    transport: 'Transport Network'
  };
}

export function renderBuildTab(parent, onSelect) {
  const tutorialStep = state.profile?.tutorial_step;
  const playerIndustry = state.profile?.industry_key;

  // Per-industry resource availability: a building can only USEFULLY
  // produce its output if every input it needs is available from
  // something in this industry's catalog. Precompute the set of
  // resources someone in your industry could produce (your industry's
  // extractors + processors + 'common' producers). Atlas 2026-05-15:
  // "I shouldn't be able to build a building that makes bread if I
  // don't have grain as a resource."
  const producibleResources = new Set();
  for (const k in state.buildingTypes) {
    const b = state.buildingTypes[k];
    if (!b.is_active || !b.output_resource_key) continue;
    if (b.industry_key !== playerIndustry && b.industry_key !== 'common') continue;
    producibleResources.add(b.output_resource_key);
  }

  // Section-keyed buckets (infra / industry / farming / civic /
  // transport). Industry filter: only show buildings from this
  // player's industry or shared 'common' buildings. Inputs filter:
  // before trade is unlocked, skip buildings whose inputs nobody
  // in this industry can produce (the bread-without-grain guard).
  // Once trade is unlocked, every input is obtainable from a partner
  // city, so school/temple/bathhouse/tavern (common, cross-industry
  // inputs by design) and late-game cross-industry processors
  // (e.g. mosaic_workshop needs nails from iron) must remain visible.
  const tradeUnlocked = !!state.profile?.trade_unlocked;
  const grouped = { infra: [], industry: [], farming: [], civic: [], transport: [] };
  for (const key in state.buildingTypes) {
    const bt = state.buildingTypes[key];
    if (!bt.category || !bt.is_active) continue;
    if (bt.industry_key && bt.industry_key !== 'common' && bt.industry_key !== playerIndustry) continue;
    if (!tutorialAllowsBuilding(bt, tutorialStep)) continue;
    if (!tradeUnlocked) {
      if (bt.input_resource_key && !producibleResources.has(bt.input_resource_key)) continue;
      if (bt.input_resource_key_2 && !producibleResources.has(bt.input_resource_key_2)) continue;
    }
    grouped[sectionFor(bt)].push(bt);
  }

  const money = state.profile?.money || 0;
  const maxTierEver = state.profile?.highest_housing_tier_ever || 0;
  const inventory = state.inventory || {};
  const resourceCostsByKey = state.buildingResourceCosts || {};
  const titles = sectionTitles(playerIndustry);

  // Default the first section with buildings open if the user hasn't
  // picked one yet (post-tutorial player wants to see SOMETHING).
  // openSection === null means "never picked"; '' means "explicitly
  // closed everything" and is left alone.
  if (openSection === null) {
    for (const s of SECTION_ORDER) {
      if (grouped[s].length) { openSection = s; break; }
    }
  }

  let html = '';
  for (const section of SECTION_ORDER) {
    const items = grouped[section];
    if (!items.length) continue;
    // Sort within section by category rank → tier → name so v1 mixed
    // category sections (Civic shows service / tax / police / park
    // in that order) read predictably.
    items.sort((a, b) => {
      const ra = CATEGORY_RANK[a.category] ?? 99;
      const rb = CATEGORY_RANK[b.category] ?? 99;
      if (ra !== rb) return ra - rb;
      return (a.tier_required || 0) - (b.tier_required || 0) ||
             a.name.localeCompare(b.name);
    });
    const isOpen = openSection === section;
    const chev = isOpen ? '▾' : '▸';
    html += `<div class="btp-section ${isOpen ? 'btp-section-open' : ''}" data-cat="${section}">
      <button class="btp-section-title">
        <span class="btp-section-chev">${chev}</span>
        ${titles[section]}
        <small class="btp-section-count">${items.length}</small>
      </button>
      ${isOpen ? `<div class="btp-items">` : ''}`;
    if (!isOpen) {
      html += `</div>`;
      continue;
    }
    for (const bt of items) {
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
      // Labor-shortage hint: if placing this would exceed the worker
      // pool, warn early. Skips zero-cost categories (road / park /
      // housing) and transport (whose worker_cost is a balance knob
      // that the server's staffing loop ignores).
      const li = state.laborInfo || {};
      const skipsStaffing = bt.category === 'transport_hub' || bt.category === 'transport_connector';
      const wouldExceedCapacity = bt.worker_cost > 0
        && !skipsStaffing
        && (li.workersUsed + bt.worker_cost) > (li.workerCapacity || 0);

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

      const iconUri = spriteIcons[bt.key];
      const iconHtml = iconUri
        ? `<img class="btp-icon" src="${iconUri}" alt="" />`
        : `<div class="btp-icon btp-icon-fallback"></div>`;
      html += `<button class="${classes.join(' ')}" data-key="${bt.key}" ${(!unlocked) ? 'disabled' : ''}>
        ${iconHtml}
        <div class="btp-body">
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
          ${wouldExceedCapacity ? `<div class="btp-warn">⚠️ Will be unstaffed — population needs to grow by ${(li.workersUsed + bt.worker_cost) - (li.workerCapacity || 0)} first.</div>` : ''}
          ${lockHint}
        </div>
      </button>`;
    }
    html += `</div></div>`;
  }
  parent.innerHTML = html || '<p class="btp-empty">No buildings available.</p>';

  // Section header click toggles accordion: open → close, closed → open
  // and close every other section. Re-render after to redraw.
  parent.querySelectorAll('.btp-section-title').forEach((header) => {
    header.addEventListener('click', () => {
      const cat = header.parentElement.dataset.cat;
      setOpenSection(openSection === cat ? '' : cat);
      renderBuildTab(parent, onSelect);
    });
  });

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
  if (cat === 'transport_hub') {
    const myHubs = (state.allBuildings || []).filter((b) =>
      b.player_id === state.currentUser?.id
      && state.buildingTypes[b.building_type_key]?.category === 'transport_hub'
    ).length;
    if (myHubs === 0) {
      return 'Your FIRST trade hub. Placing it unlocks one procedural city-wide trade partner. Each subsequent hub or expansion adds another to the pool.';
    }
    return `You have ${myHubs} hub${myHubs === 1 ? '' : 's'} placed. Adds another procedural trade partner to the city pool. Existing hubs can also be expanded one level from their inspector.`;
  }
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
