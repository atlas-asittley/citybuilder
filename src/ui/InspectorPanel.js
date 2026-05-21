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
import {
  listBuildingIssues,
  getHousingUpgradeBlockers,
  getHousingDevolveRisks,
  describeHousingBlocker,
  describeHousingDevolveReason,
  recipeOf, periodSuffix,
  getProductivity, getBoosterMultiplier
} from '../scenes/helpers.js';

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
  if (sceneRef?.showSelection) sceneRef.showSelection(building);
}

export function closeInspector() {
  if (!mounted) return;
  const panel = document.getElementById('inspector-panel');
  if (panel) panel.classList.remove('open');
  activeBuilding = null;
  if (sceneRef?.clearAoe) sceneRef.clearAoe();
  if (sceneRef?.clearSelection) sceneRef.clearSelection();
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
  // Transport hub/connector worker_cost is a balance knob, not a
  // runtime allocation — server's staffing loop skips those
  // categories. Don't render the "(staffed)/(unstaffed)" annotation
  // for them; just show the cost as the build-time gate it is.
  const isTransportCat = bt.category === 'transport_hub' || bt.category === 'transport_connector';
  if (bt.worker_cost > 0) {
    if (isTransportCat) {
      rows.push(row('Workers', `${bt.worker_cost}`));
    } else {
      rows.push(row('Workers', b.is_staffed ? `${bt.worker_cost} (staffed)` : `${bt.worker_cost} (unstaffed)`));
    }
  }
  // Housing-only block: tier, upgrade blockers, pantry, devolve risk,
  // last-devolve reason. Gated on bt.category === 'housing' because
  // the housing_tier column is non-null even for non-housing rows
  // (defaults to 0), so checking the column alone would surface "needs
  // a well" / "needs food" on extractors and processors too.
  if (bt.category === 'housing') {
    const tier = state.housingTierConfig[b.housing_tier];
    rows.push(row('Housing tier', tier ? `${tier.name} (tier ${b.housing_tier})` : `tier ${b.housing_tier}`));
    if (b.population) rows.push(row('Residents', b.population));

    const nextTier = state.housingTierConfig[b.housing_tier + 1];
    if (nextTier && isMine) {
      const ctx = buildHousingCtx();
      const blockers = getHousingUpgradeBlockers(b, nextTier, ctx);
      const workerDelta = (nextTier.workers || nextTier.workers_provided || 0)
                       - (tier?.workers || tier?.workers_provided || 0);
      const deltaStr = workerDelta > 0 ? ` (+${workerDelta} workers)` : '';
      if (b.evolution_eligible_at) {
        rows.push(row('Next tier', `${nextTier.name}${deltaStr} — ready to upgrade`));
      } else if (blockers.length === 0) {
        rows.push(row('Next tier', `${nextTier.name}${deltaStr} — waiting on server confirmation`));
      } else {
        rows.push(row('Next tier', `${nextTier.name}${deltaStr}`));
        rows.push(housingBlockersHtml('Needed to upgrade', blockers));
      }
    } else if (nextTier) {
      rows.push(row('Next tier', nextTier.name));
    }

    // Per-house pantry fill rows. Shows how much food + lifestyle
    // buffer this specific house holds — the actual gate the server
    // drains from, not city stock.
    if (isMine) {
      const pantry = pantryHtml(b);
      if (pantry) rows.push(pantry);
    }

    // Active devolve-risk section for own buildings — surfaces the
    // failing prereqs at the CURRENT tier before they actually fire,
    // plus whether a bathhouse is shielding the house in the meantime.
    if (isMine && tier) {
      const ctx = buildHousingCtx();
      const risk = getHousingDevolveRisks(b, tier, ctx);
      if (risk.blockers.length > 0) {
        const header = risk.hasBathhouseCover
          ? 'Devolve risk — bathhouse is holding for now'
          : 'Devolve risk — will drop next tick';
        rows.push(housingBlockersHtml(header, risk.blockers, /*severity*/ risk.hasBathhouseCover ? 'warn' : 'bad'));
      }
    }

    if (b.last_devolve_reason) {
      const text = describeHousingDevolveReason(
        b.last_devolve_reason, state.resourceNodes,
        { lifestyleSubstitutes: state.lifestyleSubstitutes }
      );
      rows.push(row('Last devolved', text, true));
    }
  }
  if (b.expansion_level > 0) {
    rows.push(row('Expansion level', `${b.expansion_level}× (output multiplier)`));
  }
  if (b.staffing_priority !== null && b.staffing_priority !== undefined && bt.worker_cost > 0) {
    rows.push(row('Staffing priority', priorityLabel(b.staffing_priority)));
  }
  // Production / consumption details. Display the integer-ratio recipe
  // (the building's *design* throughput) and, when it would differ —
  // because of productivity, a nearby booster, or path-length falloff —
  // an "Effective rate" row showing the actual per-minute output. The
  // server applies all three multiplicatively, so the inspector has to
  // mirror them or rate displays silently lie (per
  // feedback_ui_must_mirror_server_math.md).
  const productivity = getProductivity(state.profile);
  const boost = getBoosterMultiplier(b, bt, state.allBuildings || [], state.buildingTypes, state.currentUser?.id);
  if (bt.output_resource_key && bt.output_rate > 0) {
    if (bt.category === 'tax') {
      const base = Number(bt.output_rate);
      const eff = base * productivity;
      rows.push(row('Revenue', `$${base}/min per 100 citizens (design)`));
      if (Math.abs(eff - base) > 0.01) {
        rows.push(row('Effective revenue', `$${eff.toFixed(2).replace(/\.?0+$/, '')}/min per 100 citizens (× ${productivity.toFixed(2)} productivity)`));
      }
    } else if (bt.category === 'extractor' && b.target_x != null && b.target_y != null) {
      const CANONICAL = 4;
      const pathLen = b.path_length || 1;
      const pathFactor = Math.min(1, CANONICAL / Math.max(pathLen, 1));
      const base = Number(bt.output_rate);
      const effective = base * pathFactor * boost * productivity;
      rows.push(row('Target', `(${b.target_x}, ${b.target_y})`));
      rows.push(row('Path', `${pathLen} tile${pathLen === 1 ? '' : 's'}`));
      const fullRate = Math.abs(effective - base) < 0.001;
      const rateStr = effective.toFixed(2).replace(/\.?0+$/, '');
      // Build a parenthetical that names every multiplier away from 1.
      const factors = [];
      if (pathFactor < 0.999) factors.push(`${Math.round(pathFactor * 100)}% path`);
      if (boost > 1.001) factors.push(`× ${boost.toFixed(2)} booster`);
      if (Math.abs(productivity - 1) > 0.001) factors.push(`× ${productivity.toFixed(2)} productivity`);
      const suffix = fullRate ? '/min (full rate)' : `/min (${factors.join(', ')})`;
      rows.push(row('Effective rate', `${rateStr} ${resName(bt.output_resource_key)}${suffix}`));
      if (pathLen > CANONICAL) {
        rows.push(row('', `Tip — a ${CANONICAL}-tile path produces at full rate. Shorten the road to the resource tile to boost output.`, true));
      }
    } else if (bt.category === 'food_extractor') {
      const base = Number(bt.output_rate);
      const effective = base * boost * productivity;
      const r = recipeOf(bt);
      rows.push(row('Output', `${r.output_q} ${resName(bt.output_resource_key)}${periodSuffix(r.period_min)} (design)`));
      if (Math.abs(effective - base) > 0.01) {
        const factors = [];
        if (boost > 1.001) factors.push(`× ${boost.toFixed(2)} booster`);
        if (Math.abs(productivity - 1) > 0.001) factors.push(`× ${productivity.toFixed(2)} productivity`);
        rows.push(row('Effective rate', `${effective.toFixed(2).replace(/\.?0+$/, '')} ${resName(bt.output_resource_key)}/min (${factors.join(', ')})`));
      }
    } else {
      // Integer-ratio recipe: "1 lumber/min" or "1 lumber per 2 min".
      // Processors + services apply productivity to their throughput.
      const r = recipeOf(bt);
      rows.push(row('Output', `${r.output_q} ${resName(bt.output_resource_key)}${periodSuffix(r.period_min)} (design)`));
      if (Math.abs(productivity - 1) > 0.001) {
        const effective = Number(bt.output_rate) * productivity;
        rows.push(row('Effective rate', `${effective.toFixed(2).replace(/\.?0+$/, '')} ${resName(bt.output_resource_key)}/min (× ${productivity.toFixed(2)} productivity)`));
      }
    }
  }
  if (bt.input_resource_key && bt.input_rate > 0) {
    // Integer-ratio inputs share the recipe's period — "2 timber + 1
    // statuary → 1 cabinets per 2 min" reads cleanly. Effective input
    // consumption is base × productivity (matches server's
    // _pp_run_processors / _pp_run_services).
    const r = recipeOf(bt);
    const inputs = [`${r.input_q} ${resName(bt.input_resource_key)}`];
    if (bt.input_resource_key_2 && bt.input_rate_2 > 0) {
      inputs.push(`${r.input_q_2} ${resName(bt.input_resource_key_2)}`);
    }
    rows.push(row('Input', inputs.join(' + ') + periodSuffix(r.period_min) + ' (design)'));
    if (Math.abs(productivity - 1) > 0.001) {
      const effIns = [`${(Number(bt.input_rate) * productivity).toFixed(2).replace(/\.?0+$/, '')} ${resName(bt.input_resource_key)}`];
      if (bt.input_resource_key_2 && bt.input_rate_2 > 0) {
        effIns.push(`${(Number(bt.input_rate_2) * productivity).toFixed(2).replace(/\.?0+$/, '')} ${resName(bt.input_resource_key_2)}`);
      }
      rows.push(row('Effective draw', `${effIns.join(' + ')}/min (× ${productivity.toFixed(2)} productivity)`));
    }
  }
  if (bt.upkeep_per_minute > 0) rows.push(row('Upkeep', `$${bt.upkeep_per_minute}/min`));
  // Trade-value row — for producers with an output, surface what the
  // best unlocked trader pays per minute. Scaled the same way the
  // building's output is, so the dollar figure matches reality.
  if (isMine && bt.output_resource_key && bt.output_rate > 0 && bt.category !== 'tax') {
    const tradeValue = bestTraderBuyPrice(bt.output_resource_key);
    if (tradeValue > 0) {
      let effRate = Number(bt.output_rate) * productivity;
      if (bt.category === 'extractor' && b.target_x != null && b.target_y != null) {
        const pathFactor = Math.min(1, 4 / Math.max(b.path_length || 1, 1));
        effRate *= pathFactor * boost;
      } else if (bt.category === 'food_extractor') {
        effRate *= boost;
      }
      const perMin = tradeValue * effRate;
      rows.push(row('Trade value', `$${Math.round(perMin)}/min at best trader price ($${tradeValue}/unit)`));
    }
  }
  if (bt.coverage_radius > 0) rows.push(row('Coverage', `${bt.coverage_radius} tiles`));
  if (bt.boost_multiplier && bt.boost_multiplier > 1) {
    const pct = Math.round((bt.boost_multiplier - 1) * 100);
    const tgt = bt.boost_target === 'food_extractor' ? 'food extractors' : 'extractors';
    rows.push(row('Effect', `+${pct}% to ${tgt} within ${bt.boost_range || 2} tiles`));
  }
  rows.push(row('Location', `(${b.x}, ${b.y})`));
  rows.push(row('Footprint', `${bt.footprint_w || 1} × ${bt.footprint_h || 1}`));
  if (bt.pollution_emit > 0) rows.push(row('Pollution', `${bt.pollution_emit} emit, radius ${bt.pollution_radius}`));
  // For housing, surface this tile's environmental metrics + what tier
  // they qualify for. Helps the player see why a fancy house won't
  // upgrade ("desirability 48, Villa needs 60") at a glance.
  if (bt.category === 'housing') {
    const tile = state.tileMap?.[b.x + ',' + b.y];
    if (tile) {
      const d = tile.desirability != null ? Number(tile.desirability) : 50;
      const p = Number(tile.pollution || 0);
      // Find the highest tier this desirability qualifies for.
      let qualifiesFor = null;
      for (let t = 8; t >= 0; t--) {
        const cfg = state.housingTierConfig?.[t];
        if (!cfg) continue;
        if (!cfg.min_desirability || d >= cfg.min_desirability) {
          qualifiesFor = cfg;
          break;
        }
      }
      const qualLine = qualifiesFor
        ? ` — qualifies for ${qualifiesFor.name}`
        : '';
      rows.push(row('Desirability', `${d}/100${qualLine}`));
      if (p > 0) {
        const sev = p >= 20 ? 'toxic' : p >= 10 ? 'heavy' : 'light';
        rows.push(row('Pollution', `${p} (${sev})`));
      }
    }
  }
  // Demolish refund preview (only on own buildings — only owner can demolish).
  // Server formula is floor(build_cost * 0.5).
  if (isMine && bt.build_cost > 0) {
    const refund = Math.floor(bt.build_cost * 0.5);
    rows.push(row('Refund on demolish', `$${refund.toLocaleString()}`));
  }

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
    parts.push(`<button class="ip-btn ip-toggle ${b.status === 'paused' ? 'ip-toggle-off' : 'ip-toggle-on'}" id="ip-paused">
      ${b.status === 'paused' ? 'Resume' : 'Pause'}
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
    const bt = state.buildingTypes[b.building_type_key] || {};
    const refund = bt.build_cost > 0 ? Math.floor(bt.build_cost * 0.5) : 0;
    const msg = refund > 0
      ? `Demolish this ${bt.name || 'building'}? You'll get $${refund.toLocaleString()} back.`
      : `Demolish this ${bt.name || 'building'}?`;
    if (!confirm(msg)) return;
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
    // Pause/Resume reads from status, not a paused boolean. Schema is
    // status IN ('active', 'paused') — there's no separate column.
    const wasPaused = b.status === 'paused';
    const next = !wasPaused;   // true → pause, false → resume
    try {
      await setBuildingPaused(b.id, next);
      b.status = next ? 'paused' : 'active';
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

// Build the ctx object the helpers need from current state. Cheap
// to recompute per render — bounded by player interaction frequency,
// not tick frequency.
function buildHousingCtx() {
  return {
    roadSet: buildRoadSet(),
    allBuildings: state.allBuildings,
    buildingTypes: state.buildingTypes,
    tileMap: state.tileMap,
    inventory: state.inventory || {},
    resources: state.resourceNodes,
    housingLifestyleDemands: state.housingLifestyleDemands,
    buildingBuffers: state.buildingBuffers,
    lifestyleSubstitutes: state.lifestyleSubstitutes || {}
  };
}

// Render the per-house pantry fill section. Each gated resource on
// this tier shows fill % + raw quantity/capacity. Yellow when <25%,
// red at 0. Drives the "you have 7 minutes of pottery left" mental
// model that v1 surfaces by default.
function pantryHtml(b) {
  const pantry = state.buildingBuffers?.[b.id];
  if (!pantry) return '';
  const keys = Object.keys(pantry).sort();
  if (keys.length === 0) return '';
  const rows = keys.map((rk) => {
    const entry = pantry[rk];
    if (!entry || !entry.capacity) return '';
    const pct = Math.max(0, Math.min(100, Math.round(entry.quantity / entry.capacity * 100)));
    const label = rk === 'food' ? 'Food' : (state.resourceNodes?.[rk]?.name || rk);
    const sev = pct === 0 ? 'bad' : pct < 25 ? 'warn' : 'ok';
    return `<div class="ip-pantry-row ip-pantry-${sev}">
      <div class="ip-pantry-name">${escapeHtml(label)}</div>
      <div class="ip-pantry-bar"><div class="ip-pantry-fill" style="width:${pct}%"></div></div>
      <div class="ip-pantry-value">${entry.quantity.toFixed(1)} / ${entry.capacity.toFixed(0)} (${pct}%)</div>
    </div>`;
  }).join('');
  return `<div class="ip-pantry">
    <div class="ip-pantry-header">Pantry · per-house buffer</div>
    ${rows}
  </div>`;
}

// Render a labeled list of housing blockers, each line as
// "Needs <description>". Severity tints the left border red ('bad')
// or amber ('warn').
function housingBlockersHtml(header, blockers, severity) {
  const sev = severity === 'warn' ? 'warn' : 'bad';
  const items = blockers.map((key) => {
    const desc = describeHousingBlocker(
      key, state.resourceNodes,
      { lifestyleSubstitutes: state.lifestyleSubstitutes }
    );
    return `<li class="ip-blocker">${escapeHtml(desc)}</li>`;
  }).join('');
  return `<div class="ip-blockers ip-blockers-${sev}">
    <div class="ip-blockers-header">${escapeHtml(header)}</div>
    <ul class="ip-blocker-list">${items}</ul>
  </div>`;
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

// Find the highest buy_price across all loaded trader catalogs for
// this resource. Returns 0 if no trader buys it.
function bestTraderBuyPrice(resourceKey) {
  let best = 0;
  const prices = state.allTraderPrices || {};
  for (const tk in prices) {
    const p = prices[tk]?.[resourceKey];
    if (p?.buy_price > best) best = p.buy_price;
  }
  return best;
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
