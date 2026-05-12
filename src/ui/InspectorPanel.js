// Building inspector — DOM panel that slides up from the bottom
// when the player taps a building. Shows name, type, status,
// staffing, owner. v1's inspector is elaborate (devolve reasons,
// AoE highlights, manage-tab); we start with the minimum useful
// surface and grow from there.
import { state } from '../state/store.js';
import {
  demolishBuilding, upgradeHouse,
  setHouseAutoUpgrade, setBuildingPaused, setBuildingPriority, expandTransportHub
} from '../api/buildings.js';
import { listBuildingIssues } from '../scenes/helpers.js';

// Set by main.js after MainScene starts. Lets the inspector ask the
// scene to draw / clear the AoE highlight without an awkward import
// cycle (scene also imports inspector functions).
let sceneRef = null;
export function bindSceneToInspector(scene) { sceneRef = scene; }

let mounted = false;
let activeBuilding = null;
let onCloseCallback = null;

// Public — used by ResourceTileInspector to mount the shared DOM
// without duplicating the panel HTML (avoids ID collisions and
// stale event listeners).
export function ensureInspectorMounted() {
  if (!mounted) mountInspector();
}

export function openInspector(building, onClose) {
  activeBuilding = building;
  onCloseCallback = onClose || null;
  if (!mounted) mountInspector();
  renderInspector();
  if (sceneRef?.showAoe) sceneRef.showAoe(building);
}

export function closeInspector() {
  if (!mounted) return;
  const panel = document.getElementById('inspector-panel');
  if (panel) panel.classList.remove('open');
  activeBuilding = null;
  if (sceneRef?.clearAoe) sceneRef.clearAoe();
  if (onCloseCallback) {
    onCloseCallback();
    onCloseCallback = null;
  }
}

// Called from the realtime / tick layer when state.allBuildings
// changes. If the currently-inspected building is in the updated
// list, refresh the panel content so the player sees live data
// (status flips, staffed/unstaffed, devolves, etc.) without
// closing and reopening.
export function refreshInspectorIfOpen() {
  if (!mounted || !activeBuilding) return;
  const panel = document.getElementById('inspector-panel');
  if (!panel?.classList.contains('open')) return;
  // Re-look-up the building by id in case the realtime sub
  // replaced the in-state row with a new object reference.
  const fresh = state.allBuildings.find((b) => b.id === activeBuilding.id);
  if (!fresh) {
    // Building was demolished — close.
    closeInspector();
    return;
  }
  activeBuilding = fresh;
  renderInspector();
}

function mountInspector() {
  const root = document.getElementById('ui-root');
  const panel = document.createElement('div');
  panel.id = 'inspector-panel';
  panel.innerHTML = `
    <div class="ip-header">
      <div class="ip-title-row">
        <h2 class="ip-title" id="ip-title"></h2>
        <div class="ip-header-actions">
          <button class="ip-mini" id="ip-mini" aria-label="Minimize" title="Minimize">
            <svg viewBox="0 0 16 16" width="14" height="14" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><polyline points="3,6 8,11 13,6"/></svg>
          </button>
          <button class="ip-close" id="ip-close" aria-label="Close" title="Close">
            <svg viewBox="0 0 16 16" width="14" height="14" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><line x1="4" y1="4" x2="12" y2="12"/><line x1="12" y1="4" x2="4" y2="12"/></svg>
          </button>
        </div>
      </div>
      <p class="ip-subtitle" id="ip-subtitle"></p>
    </div>
    <div class="ip-body" id="ip-body"></div>
    <div class="ip-actions" id="ip-actions"></div>
    <div class="ip-hint">tap outside to close</div>
  `;
  root.appendChild(panel);
  mounted = true;

  document.getElementById('ip-close').addEventListener('click', closeInspector);
  document.getElementById('ip-mini').addEventListener('click', () => {
    panel.classList.toggle('minimized');
    // Flip the chevron direction so the affordance reads either as
    // "collapse" or "expand" depending on current state.
    const svg = document.getElementById('ip-mini').querySelector('svg polyline');
    if (svg) {
      svg.setAttribute('points',
        panel.classList.contains('minimized') ? '3,10 8,5 13,10' : '3,6 8,11 13,6');
    }
  });
}

function renderInspector() {
  const panel = document.getElementById('inspector-panel');
  const b = activeBuilding;
  if (!b) return;

  const bt = state.buildingTypes[b.building_type_key] || {};
  const owner = b.player_profiles?.display_name || 'unknown';
  const isMine = b.player_id === state.currentUser?.id;

  document.getElementById('ip-title').textContent = bt.name || b.building_type_key;
  document.getElementById('ip-subtitle').textContent =
    `${bt.category || 'building'} · owned by ${isMine ? 'you' : owner}`;

  const rows = [];

  // Issues section — every reason this building isn't operational, with
  // a fix hint per item. Mirrors v1's consolidated Issues list. Only
  // computed for own-player buildings (the helper short-circuits).
  // When healthy, header reads "Operational" and no Issues panel renders.
  const issues = isMine ? listBuildingIssues(b, bt, buildRoadSet(), state.inventory, state.currentUser?.id) : [];
  if (issues.length === 0) {
    rows.push(row('Status', isMine ? 'Operational' : formatStatus(b)));
  } else {
    rows.push(row('Status', issues.length === 1 ? '1 issue' : `${issues.length} issues`));
    rows.push(issueListHtml(issues));
  }
  if (bt.worker_cost > 0) rows.push(row('Workers', b.is_staffed ? `${bt.worker_cost} (staffed)` : `${bt.worker_cost} (unstaffed)`));
  if (b.housing_tier) {
    const tier = state.housingTierConfig[b.housing_tier];
    rows.push(row('Housing tier', tier ? `${tier.name} (tier ${b.housing_tier})` : `tier ${b.housing_tier}`));
    if (b.population) rows.push(row('Residents', b.population));
    const nextTier = state.housingTierConfig[b.housing_tier + 1];
    if (nextTier) {
      const workerDelta = (nextTier.workers || nextTier.workers_provided || 0)
                       - (tier?.workers || tier?.workers_provided || 0);
      const deltaStr = workerDelta > 0 ? ` (+${workerDelta} workers)` : '';
      const readyHint = b.evolution_eligible_at
        ? ' — ready to upgrade'
        : ' — needs more services / lifestyle goods';
      rows.push(row('Next tier', `${nextTier.name}${deltaStr}${readyHint}`));
    }
    if (b.last_devolve_reason) {
      rows.push(row('Last devolved', friendlyDevolveReason(b.last_devolve_reason), true));
    }
  }
  if (b.expansion_level > 0) {
    rows.push(row('Expansion level', `${b.expansion_level}× (output multiplier)`));
  }
  if (b.staffing_priority !== null && b.staffing_priority !== undefined && bt.worker_cost > 0) {
    rows.push(row('Staffing priority', priorityLabel(b.staffing_priority)));
  }
  // Production / consumption details for processors + extractors.
  if (bt.output_resource_key && bt.output_rate > 0) {
    if (bt.category === 'tax') {
      rows.push(row('Revenue', `$${bt.output_rate}/min per 100 citizens`));
    } else {
      rows.push(row('Output', `${bt.output_rate} ${resName(bt.output_resource_key)}/min`));
    }
  }
  if (bt.input_resource_key && bt.input_rate > 0) {
    const inputs = [`${bt.input_rate} ${resName(bt.input_resource_key)}`];
    if (bt.input_resource_key_2 && bt.input_rate_2 > 0) {
      inputs.push(`${bt.input_rate_2} ${resName(bt.input_resource_key_2)}`);
    }
    rows.push(row('Input', inputs.join(' + ') + '/min'));
  }
  if (bt.upkeep_per_minute > 0) rows.push(row('Upkeep', `$${bt.upkeep_per_minute}/min`));
  if (bt.coverage_radius > 0) rows.push(row('Coverage', `${bt.coverage_radius} tiles`));
  if (bt.boost_multiplier && bt.boost_multiplier > 1) {
    const pct = Math.round((bt.boost_multiplier - 1) * 100);
    const tgt = bt.boost_target === 'food_extractor' ? 'food extractors' : 'extractors';
    rows.push(row('Effect', `+${pct}% to ${tgt} within ${bt.boost_range || 2} tiles`));
  }
  rows.push(row('Location', `(${b.x}, ${b.y})`));
  rows.push(row('Footprint', `${bt.footprint_w || 1} × ${bt.footprint_h || 1}`));
  if (bt.pollution_emit > 0) rows.push(row('Pollution', `${bt.pollution_emit} emit, radius ${bt.pollution_radius}`));

  document.getElementById('ip-body').innerHTML = rows.join('');
  document.getElementById('ip-actions').innerHTML = renderActions(b, bt, isMine);
  wireActionHandlers(b);
  panel.classList.add('open');
}

// Action buttons. Only the owner can act. Layout:
//   Housing:    [Upgrade?]  [Auto-upgrade ON/OFF toggle]  [Demolish]
//   Worker buildings: [Pause/Resume]  [Priority▾]  [Demolish]
//   Transport hubs:  [Expand hub]  [Demolish]
//   Everything else: [Demolish]
function renderActions(b, bt, isMine) {
  if (!isMine) return '';
  const parts = [];

  const isHousing = bt.category === 'housing' && b.housing_tier;
  const isWorkerBuilding = bt.worker_cost > 0;
  const isTransportHub = bt.category === 'transport_hub' || bt.category === 'transport_connector';
  const canUpgrade = isHousing && !!b.evolution_eligible_at;

  if (canUpgrade) {
    parts.push('<button class="ip-btn ip-btn-primary" id="ip-upgrade">Upgrade house</button>');
  }
  if (isHousing) {
    parts.push(`<button class="ip-btn ip-toggle ${b.auto_upgrade ? 'ip-toggle-on' : 'ip-toggle-off'}" id="ip-auto">
      Auto-upgrade: ${b.auto_upgrade ? 'ON' : 'OFF'}
    </button>`);
  }
  if (isWorkerBuilding && !isHousing) {
    parts.push(`<button class="ip-btn ip-toggle ${b.paused ? 'ip-toggle-off' : 'ip-toggle-on'}" id="ip-paused">
      ${b.paused ? 'Resume' : 'Pause'}
    </button>`);
    parts.push(`<select class="ip-priority" id="ip-priority">
      <option value="0" ${b.staffing_priority === 0 ? 'selected' : ''}>Priority: Low</option>
      <option value="1" ${(!b.staffing_priority || b.staffing_priority === 1) ? 'selected' : ''}>Priority: Normal</option>
      <option value="2" ${b.staffing_priority === 2 ? 'selected' : ''}>Priority: High</option>
    </select>`);
  }
  if (isTransportHub) {
    parts.push(`<button class="ip-btn" id="ip-expand-hub">Expand hub (lvl ${(b.expansion_level || 0) + 1})</button>`);
  }
  parts.push('<button class="ip-btn ip-btn-danger" id="ip-demolish">Demolish</button>');
  return parts.join('');
}

function wireActionHandlers(b) {
  bind('ip-upgrade', async (btn) => {
    btn.disabled = true; btn.textContent = 'Upgrading…';
    try { await upgradeHouse(b.id); closeInspector(); }
    catch (err) { alert(err.message || 'Upgrade failed.'); btn.disabled = false; btn.textContent = 'Upgrade house'; }
  });

  bind('ip-demolish', async (btn) => {
    if (!confirm('Demolish this building? You will get a partial refund.')) return;
    btn.disabled = true; btn.textContent = 'Demolishing…';
    try { await demolishBuilding(b.id); closeInspector(); }
    catch (err) { alert(err.message || 'Could not demolish.'); btn.disabled = false; btn.textContent = 'Demolish'; }
  });

  bind('ip-auto', async (btn) => {
    btn.disabled = true;
    const next = !b.auto_upgrade;
    try {
      await setHouseAutoUpgrade(b.id, next);
      b.auto_upgrade = next;
      // Just retoggle styling + label in place — saves a re-render.
      btn.classList.toggle('ip-toggle-on', next);
      btn.classList.toggle('ip-toggle-off', !next);
      btn.textContent = 'Auto-upgrade: ' + (next ? 'ON' : 'OFF');
    } catch (err) {
      alert(err.message || 'Could not change auto-upgrade.');
    } finally {
      btn.disabled = false;
    }
  });

  bind('ip-paused', async (btn) => {
    btn.disabled = true;
    const next = !b.paused;
    try {
      await setBuildingPaused(b.id, next);
      b.paused = next;
      btn.classList.toggle('ip-toggle-on', !next);
      btn.classList.toggle('ip-toggle-off', next);
      btn.textContent = next ? 'Resume' : 'Pause';
    } catch (err) {
      alert(err.message || 'Could not change pause state.');
    } finally {
      btn.disabled = false;
    }
  });

  bind('ip-expand-hub', async (btn) => {
    if (!confirm('Expand this hub? Costs money + raw materials and increases its output capacity.')) return;
    btn.disabled = true; btn.textContent = 'Expanding…';
    try { await expandTransportHub(b.id); closeInspector(); }
    catch (err) { alert(err.message || 'Could not expand.'); btn.disabled = false; btn.textContent = 'Expand hub'; }
  });

  const prioritySelect = document.getElementById('ip-priority');
  if (prioritySelect) {
    prioritySelect.addEventListener('change', async () => {
      const val = parseInt(prioritySelect.value, 10);
      try {
        await setBuildingPriority(b.id, val);
        b.staffing_priority = val;
      } catch (err) {
        alert(err.message || 'Could not change priority.');
        prioritySelect.value = String(b.staffing_priority ?? 1);
      }
    });
  }
}

function bind(id, handler) {
  const btn = document.getElementById(id);
  if (btn) btn.addEventListener('click', () => handler(btn));
}

function priorityLabel(p) {
  return p === 0 ? 'Low' : p === 2 ? 'High' : 'Normal';
}

function friendlyDevolveReason(reason) {
  return ({
    no_food: 'No food available — residents went hungry.',
    no_water: 'Out of well coverage — needed water nearby.',
    no_pottery: 'Out of pottery — tier requires it.',
    no_bread: 'Out of bread — tier requires it.',
    no_furniture: 'Out of furniture — tier requires it.',
    no_statuary: 'Out of statuary — tier requires it.',
    desirability_too_low: 'Surroundings became unappealing.',
    no_school: 'No school in range — tier requires it.',
    no_temple: 'No temple in range — tier requires it.',
    no_bathhouse: 'No bathhouse in range — tier requires it.',
    no_tavern: 'No tavern available — tier requires it.'
  })[reason] || reason;
}

function row(label, value, wide) {
  return `<div class="ip-row ${wide ? 'ip-row-wide' : ''}">
    <span class="ip-label">${label}</span>
    <span class="ip-value">${escapeHtml(String(value))}</span>
  </div>`;
}

function formatStatus(b) {
  if (b.status === 'idle') return 'idle (no input or no output capacity)';
  if (b.status === 'active') return b.is_staffed ? 'active' : 'active (unstaffed)';
  return b.status || '—';
}

function escapeHtml(s) {
  return s.replace(/[&<>"]/g, (c) => ({
    '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;'
  }[c]));
}

function resName(key) {
  return (state.resourceNodes[key]?.name || key).toLowerCase();
}

// Build the road-set the issue helper needs. Walks state.allBuildings
// for road-category entries. Cheap O(N) — only fires when inspector
// is rendering an own-player building, which is bounded by player
// interaction frequency.
function buildRoadSet() {
  const s = new Set();
  for (const b of state.allBuildings) {
    const bt = state.buildingTypes[b.building_type_key];
    if (bt && bt.category === 'road') s.add(b.x + ',' + b.y);
  }
  return s;
}

// Render the Issues bulleted list. Each issue gets a colored severity
// dot, the label, the friendly resource name (if applicable), and a
// fix-hint paragraph. Returned as a row-html chunk so the caller can
// splice it into the inspector body.
function issueListHtml(issues) {
  const items = issues.map((iss) => {
    const resName = iss.resource_key
      ? (state.resourceNodes[iss.resource_key]?.name || iss.resource_key)
      : null;
    const label = resName ? `${iss.label}: ${resName}` : iss.label;
    return `<li class="ip-issue ip-issue-${iss.kind}">
      <span class="ip-issue-label">${escapeHtml(label)}</span>
      <span class="ip-issue-hint">${escapeHtml(iss.hint || '')}</span>
    </li>`;
  }).join('');
  return `<div class="ip-issues">
    <ul class="ip-issue-list">${items}</ul>
  </div>`;
}

export function isInspectorOpen() {
  return activeBuilding !== null;
}
