// Pure-logic helpers used by MainScene. Extracted into a separate
// module so they can be unit-tested without booting Phaser.
//
// Everything here is stateless or takes its state via arguments —
// no `this`, no scene refs, no DOM lookups.

// ── Building signature ──────────────────────────────────────────
//
// Pack every visual-affecting field of a building into a string so
// the diff renderer can decide whether the sprite needs updating.
// If two consecutive renders produce the same signature, the existing
// sprite + animations are kept as-is. Any change → re-render. The
// road bitmask is included so a road tile retextures when a neighbor
// is laid or removed.
export function buildingSignature(b, bt, roadSet, myId, issueKind) {
  let sig = b.building_type_key + '|' + b.x + ',' + b.y;
  sig += '|t' + (b.housing_tier || 0);
  sig += '|s' + (b.status || '-');
  sig += '|w' + (b.is_staffed ? 1 : 0);
  sig += '|p' + (b.paused ? 1 : 0);
  sig += '|e' + (b.expansion_level || 0);
  sig += '|o' + (b.player_id === myId ? 'me' : 'them');
  if (bt.category === 'road') {
    const n = roadSet.has(b.x + ',' + (b.y - 1)) ? 1 : 0;
    const s = roadSet.has(b.x + ',' + (b.y + 1)) ? 1 : 0;
    const e = roadSet.has((b.x + 1) + ',' + b.y) ? 1 : 0;
    const w = roadSet.has((b.x - 1) + ',' + b.y) ? 1 : 0;
    sig += '|r' + n + s + e + w;
  }
  // Issue state participates in the diff so the broken-building badge
  // appears / disappears as the underlying state flips.
  sig += '|q' + (issueKind || 'n');
  return sig;
}

// ── Building issue detection ────────────────────────────────────
//
// Returns ALL operational issues blocking a building, in render
// order. Empty array means the building is working (or belongs to
// another player — we don't badge neighbors). Used by:
//   - the `!` badge + sprite fade in MainScene (takes issues[0]?.kind)
//   - the inspector "Issues" section (renders every entry with hints)
//
// Each issue carries:
//   kind        — short slug (paused / idle / unstaffed / no-road / no-input)
//   label       — display string ("Paused", "No road access", ...)
//   hint        — one-sentence player-actionable fix
//   resource_key — only for no-input issues, the missing resource's key
//
// Mutually-exclusive states (paused / idle / unstaffed) short-circuit:
// reporting "no road" on top of "paused" is just noise. Once we're
// past those, road + missing-input checks can stack — a brand-new
// sawmill might lack both road access AND timber stock simultaneously.
export function listBuildingIssues(b, bt, roadSet, inventory, myId) {
  if (!bt) return [];
  if (b.player_id !== myId) return [];

  if (b.paused) {
    return [{ kind: 'paused', label: 'Paused',
      hint: 'Tap Resume to restart production.' }];
  }
  if (b.status === 'idle') {
    return [{ kind: 'idle', label: 'Idle',
      hint: 'Server has no work to give this building right now (no path, no eligible target, or no demand).' }];
  }
  if (bt.worker_cost > 0 && !b.is_staffed) {
    return [{ kind: 'unstaffed', label: 'No workers assigned',
      hint: 'Grow population (more housing) or lower another building\'s priority so this one gets staffed.' }];
  }

  const issues = [];

  const needsRoad = (
    bt.category === 'processor' ||
    bt.category === 'service' ||
    bt.category === 'tax' ||
    bt.category === 'police' ||
    bt.category === 'transport_hub' ||
    bt.category === 'transport_connector' ||
    (bt.category === 'housing' && (b.housing_tier || 0) >= 3)
  );
  if (needsRoad && roadSet && !hasRoadOnPerimeter(b, bt, roadSet)) {
    issues.push({ kind: 'no-road', label: 'No road access',
      hint: 'Place a road on any tile adjacent to this building (perimeter — not diagonal).' });
  }

  if (b.is_staffed && inventory) {
    if (bt.input_resource_key && Number(bt.input_rate) > 0) {
      const have = Number(inventory[bt.input_resource_key] || 0);
      if (have <= 0) {
        issues.push({ kind: 'no-input', label: 'Missing input',
          resource_key: bt.input_resource_key,
          hint: 'Produce, buy from a trader, or set up a player trade for this resource.' });
      }
    }
    if (bt.input_resource_key_2 && Number(bt.input_rate_2) > 0) {
      const have = Number(inventory[bt.input_resource_key_2] || 0);
      if (have <= 0) {
        issues.push({ kind: 'no-input', label: 'Missing input',
          resource_key: bt.input_resource_key_2,
          hint: 'Produce, buy from a trader, or set up a player trade for this resource.' });
      }
    }
  }

  return issues;
}

// Convenience for callsites that only need the top issue (e.g., the
// sprite badge picks one kind to drive its color/icon).
export function computeBuildingIssue(b, bt, roadSet, inventory, myId) {
  return listBuildingIssues(b, bt, roadSet, inventory, myId)[0] || null;
}

// ── Housing tier gating ────────────────────────────────────────
//
// Returns the array of prerequisite keys that are NOT met for the
// passed tier config. Used by the inspector to show:
//   - getHousingUpgradeBlockers(b, nextTierCfg, ctx) → "what blocks the upgrade?"
//   - getHousingUpgradeBlockers(b, currentTierCfg, ctx) → "what would devolve?"
//
// Mirrors the SQL gates inside `_pp_evolve_housing` so the player
// sees what the server will see. The `ctx` parameter bundles every
// piece of state we need to read — passed explicitly so this helper
// stays pure and unit-testable.
//
// ctx shape:
//   roadSet                    — Set of "x,y" string keys for road tiles
//   allBuildings               — array of buildings (any owner)
//   buildingTypes              — keyed by building_type_key
//   tileMap                    — keyed by "x,y"
//   inventory                  — resource_key → numeric
//   resources                  — resource_key → row (carries is_food / is_luxury_food / is_industrial_luxury / name)
//   housingLifestyleDemands    — tier → [{ resource_key, qty_per_minute }]
export function getHousingUpgradeBlockers(building, tierCfg, ctx) {
  if (!tierCfg) return [];
  const blockers = [];

  if (tierCfg.needs_road &&
      !hasRoadOnPerimeter(building, { footprint_w: 1, footprint_h: 1 }, ctx.roadSet)) {
    blockers.push('road');
  }

  if (tierCfg.needs_food) {
    const hasFood = anyResourceFlag(ctx, 'is_food');
    if (!hasFood) blockers.push('food');
  }

  if (tierCfg.needs_well   && !hasNearbyService(building, 'well',   4, false, ctx)) blockers.push('well');
  if (tierCfg.needs_school && !hasNearbyService(building, 'school', 5, true,  ctx)) blockers.push('school');
  if (tierCfg.needs_temple && !hasNearbyService(building, 'temple', 6, true,  ctx)) blockers.push('temple');

  if (tierCfg.needs_luxury_food && !anyResourceFlag(ctx, 'is_luxury_food')) {
    blockers.push('luxury_food');
  }
  if (tierCfg.needs_industrial_luxury && !anyResourceFlag(ctx, 'is_industrial_luxury')) {
    blockers.push('industrial_luxury');
  }
  if (tierCfg.needs_all_industrial_luxuries && !allResourcesWithFlag(ctx, 'is_industrial_luxury')) {
    blockers.push('all_industrial_luxuries');
  }

  // Cumulative lifestyle demands for this tier (pottery, bread, etc.).
  // Each missing resource is its own blocker so the player knows
  // exactly which good ran out.
  const demands = ctx.housingLifestyleDemands?.[tierCfg.tier] || [];
  for (const d of demands) {
    if (Number(ctx.inventory?.[d.resource_key] || 0) <= 0) {
      blockers.push('lifestyle:' + d.resource_key);
    }
  }

  // Desirability gate (server defaults to 50 when tile metric is null).
  if (tierCfg.min_desirability && tierCfg.min_desirability > 0) {
    const tile = ctx.tileMap?.[building.x + ',' + building.y];
    const d = tile?.desirability != null ? Number(tile.desirability) : 50;
    if (d < tierCfg.min_desirability) blockers.push('desirability');
  }

  return blockers;
}

// Devolve risk: same gate logic against the CURRENT tier, plus the
// bathhouse-override check that mirrors the server's safeguard. A
// staffed + fed bathhouse within 4 tiles suppresses devolve even when
// other gates are failing — useful as a temporary buffer.
//
// When per-house pantry buffers are loaded (ctx.buildingBuffers[b.id]),
// the food + lifestyle:<rk> gates re-evaluate against the building's
// OWN buffer rather than city stock. A house with 50 timber in city
// but a half-full food pantry will NOT show food devolve risk — the
// buffer is what the server actually drains from.
export function getHousingDevolveRisks(building, currentTierCfg, ctx) {
  if (!currentTierCfg) return { blockers: [], hasBathhouseCover: false, willDevolve: false };
  const globalBlockers = getHousingUpgradeBlockers(building, currentTierCfg, ctx);
  const buf = (ctx.buildingBuffers && ctx.buildingBuffers[building.id]) || null;

  // If we have buffer data, re-evaluate the food + lifestyle keys
  // against the pantry rather than city stock. Other gates (road, well,
  // services, desirability, luxury food, industrial luxury) stay as-is
  // — they're not per-house pantried.
  let blockers;
  if (buf) {
    blockers = globalBlockers.filter((key) => {
      if (key === 'food') {
        const entry = buf['food'];
        return !entry || entry.quantity <= 0;
      }
      if (key.startsWith('lifestyle:')) {
        const rk = key.slice('lifestyle:'.length);
        const entry = buf[rk];
        return !entry || entry.quantity <= 0;
      }
      return true;
    });
    // Also surface pantry-empty cases the global check didn't catch
    // (city stock refilled but pantry hasn't refilled yet).
    const demands = ctx.housingLifestyleDemands?.[currentTierCfg.tier] || [];
    for (const d of demands) {
      const entry = buf[d.resource_key];
      const key = 'lifestyle:' + d.resource_key;
      if ((!entry || entry.quantity <= 0) && !blockers.includes(key)) {
        blockers.push(key);
      }
    }
    if (currentTierCfg.needs_food) {
      const entry = buf['food'];
      if ((!entry || entry.quantity <= 0) && !blockers.includes('food')) {
        blockers.push('food');
      }
    }
  } else {
    blockers = globalBlockers;
  }

  if (blockers.length === 0) {
    return { blockers, hasBathhouseCover: false, willDevolve: false };
  }
  const hasBathhouseCover = hasNearbyService(building, 'bathhouse', 4, true, ctx);
  return { blockers, hasBathhouseCover, willDevolve: !hasBathhouseCover };
}

// Friendly forward-looking copy: "needs X". Used in upgrade-blocker
// + active-devolve-risk lists.
export function describeHousingBlocker(key, resources) {
  if (key === 'road')                      return 'a road touching this house';
  if (key === 'well')                      return 'a well within 4 tiles';
  if (key === 'food')                      return 'food in stock (any is_food resource)';
  if (key === 'school')                    return 'an operating school within 5 tiles (staffed + fed)';
  if (key === 'temple')                    return 'an operating temple within 6 tiles (staffed + fed)';
  if (key === 'luxury_food')               return 'a luxury food in stock (spirits / caviar / spices / ale)';
  if (key === 'industrial_luxury')         return 'an industrial luxury in stock (cabinets / monuments / mosaics / machinery)';
  if (key === 'all_industrial_luxuries')   return 'ALL FOUR industrial luxuries in stock simultaneously';
  if (key === 'desirability')              return 'higher tile desirability (parks, services, less pollution / crime)';
  if (key.startsWith('lifestyle:')) {
    const rk = key.slice('lifestyle:'.length);
    const name = resources?.[rk]?.name || rk;
    return `${name} in stock (this tier consumes it ongoingly)`;
  }
  return key;
}

// Past-tense copy: "ran out of X". Used by the inspector's last-
// devolved row.
export function describeHousingDevolveReason(key, resources) {
  if (key === 'road')                      return 'lost road access';
  if (key === 'well')                      return 'lost a well within 4 tiles';
  if (key === 'food')                      return 'ran out of food';
  if (key === 'school')                    return 'the nearby school stopped operating';
  if (key === 'temple')                    return 'the nearby temple stopped operating';
  if (key === 'luxury_food')               return 'ran out of all luxury foods';
  if (key === 'industrial_luxury')         return 'ran out of all industrial luxuries';
  if (key === 'all_industrial_luxuries')   return 'at least one of the four industrial luxuries ran out (Palace needs all of them)';
  if (key === 'desirability')              return 'tile desirability dropped too low';
  if (key.startsWith('lifestyle:')) {
    const rk = key.slice('lifestyle:'.length);
    const name = resources?.[rk]?.name || rk;
    return `ran out of ${name}`;
  }
  return key;
}

// ── Local helpers (not exported) ───────────────────────────────

function anyResourceFlag(ctx, flagKey) {
  const resources = ctx.resources || {};
  const inv = ctx.inventory || {};
  for (const k in resources) {
    if (resources[k]?.[flagKey] && Number(inv[k] || 0) > 0) return true;
  }
  return false;
}

function allResourcesWithFlag(ctx, flagKey) {
  const resources = ctx.resources || {};
  const inv = ctx.inventory || {};
  let saw = false;
  for (const k in resources) {
    if (!resources[k]?.[flagKey]) continue;
    saw = true;
    if (Number(inv[k] || 0) <= 0) return false;
  }
  return saw;   // false if no resources had the flag at all
}

// ── Integer-ratio recipe formatting ─────────────────────────────
//
// Atlas rule: players think in whole units, not decimals. A sawmill at
// "1 timber → 0.5 lumber per minute" reads as "2 timber → 1 lumber
// every 2 min". recipeOf scales the rates to integers and surfaces
// the cycle period explicitly.
//
// findRateScale searches for the smallest integer multiplier (cap 60)
// that rounds every supplied rate to an integer. Cap exists so weird
// fractional rates fall back to decimal display rather than hanging.
export function findRateScale(rates) {
  const nonzero = rates.filter((r) => r > 0);
  if (nonzero.length === 0) return 1;
  for (let k = 1; k <= 60; k++) {
    let ok = true;
    for (const r of nonzero) {
      if (Math.abs(r * k - Math.round(r * k)) > 0.001) { ok = false; break; }
    }
    if (ok) return k;
  }
  return 1;
}

// Returns { input_q, input_q_2, output_q, period_min } where qty
// fields are integers and period_min is the cycle in minutes.
export function recipeOf(bt) {
  const rates = [bt.input_rate || 0, bt.input_rate_2 || 0, bt.output_rate || 0].map(Number);
  const k = findRateScale(rates);
  return {
    input_q:   Math.round((bt.input_rate   || 0) * k),
    input_q_2: Math.round((bt.input_rate_2 || 0) * k),
    output_q:  Math.round((bt.output_rate  || 0) * k),
    period_min: k
  };
}

// "/min" when period_min=1, " per N min" otherwise.
export function periodSuffix(periodMin) {
  return periodMin === 1 ? '/min' : ' per ' + periodMin + ' min';
}

// ── Resource flow breakdown ─────────────────────────────────────
//
// For a single resource, returns where it's being produced (extractors
// + processors with that output) and where it's being consumed
// (processors + services that take it as input, housing-citizen
// food/lifestyle drain, NPC trader exports/imports per policy).
//
// Shape:
//   {
//     production: [{ name, count, rate }],
//     processing: [{ name, count, rate, output? }],
//     services:   [{ name, count, rate, output? }],
//     citizens:   number — food + lifestyle drain from housing
//     exports:    [{ trader, rate, price }],   // sell_surplus projections
//     imports:    [{ trader, rate, price }]    // buy_to_reserve projections
//   }
//
// Trader rates are sustained (cap-aware: min(burst, daily_cap/1440min)),
// matching v1's projection so the drilldown agrees with the top-bar
// runway calc.
//
// ctx required fields: allBuildings, buildingTypes, resources,
// housingTierConfig, housingLifestyleDemands, inventory, tradePolicies,
// traders, allTraderPrices. Pass null for any unused subsystem and the
// section silently returns empty.
export function computeResourceFlow(resourceKey, ctx, myId) {
  const flow = {
    production: [], processing: [], services: [],
    citizens: 0, exports: [], imports: []
  };
  if (!ctx || !ctx.allBuildings) return flow;

  const myActive = ctx.allBuildings.filter((b) =>
    b.player_id === myId && b.status === 'active');

  // Group worker-consuming buildings by type, only counting staffed.
  const byType = {};
  for (const b of myActive) {
    const bt = ctx.buildingTypes?.[b.building_type_key];
    if (!bt) continue;
    if (bt.category === 'road' || bt.category === 'housing') continue;
    if (!b.is_staffed) continue;
    if (!byType[bt.key]) byType[bt.key] = { bt, count: 0 };
    byType[bt.key].count++;
  }
  for (const k in byType) {
    const bt = byType[k].bt;
    const count = byType[k].count;
    if (bt.output_resource_key === resourceKey && Number(bt.output_rate) > 0) {
      flow.production.push({ name: bt.name, count, rate: count * Number(bt.output_rate) });
    }
    if (bt.input_resource_key === resourceKey && Number(bt.input_rate) > 0) {
      const item = { name: bt.name, count, rate: count * Number(bt.input_rate) };
      if (bt.output_resource_key && ctx.resources?.[bt.output_resource_key]) {
        item.output = ctx.resources[bt.output_resource_key].name;
      }
      (bt.category === 'service' ? flow.services : flow.processing).push(item);
    }
    if (bt.input_resource_key_2 === resourceKey && Number(bt.input_rate_2) > 0) {
      const item = { name: bt.name, count, rate: count * Number(bt.input_rate_2) };
      if (bt.output_resource_key && ctx.resources?.[bt.output_resource_key]) {
        item.output = ctx.resources[bt.output_resource_key].name;
      }
      (bt.category === 'service' ? flow.services : flow.processing).push(item);
    }
  }

  // Citizen food drain — proportional split across is_food resources.
  const resInfo = ctx.resources?.[resourceKey];
  if (resInfo?.is_food) {
    let totalFoodPerMin = 0;
    for (const b of myActive) {
      const bt = ctx.buildingTypes?.[b.building_type_key];
      if (!bt || bt.category !== 'housing') continue;
      const tier = b.housing_tier ?? 1;
      const cfg = ctx.housingTierConfig?.[tier];
      if (cfg?.food_per_minute) totalFoodPerMin += Number(cfg.food_per_minute);
    }
    if (totalFoodPerMin > 0) {
      const foodKeys = Object.keys(ctx.resources || {}).filter((k2) => ctx.resources[k2].is_food);
      const totalAvail = foodKeys.reduce((s, k2) => s + Number(ctx.inventory?.[k2] || 0), 0);
      if (totalAvail > 0) {
        const qty = Number(ctx.inventory?.[resourceKey] || 0);
        flow.citizens = totalFoodPerMin * (qty / totalAvail);
      } else if (resourceKey === 'grain') {
        flow.citizens = totalFoodPerMin;
      }
    }
  }

  // Lifestyle drain — direct (not pro-rata) per-tier demand.
  if (ctx.housingLifestyleDemands) {
    let lifestyleRate = 0;
    for (const tier in ctx.housingLifestyleDemands) {
      const demands = ctx.housingLifestyleDemands[tier];
      for (const d of demands) {
        if (d.resource_key !== resourceKey) continue;
        const houseCount = myActive.filter((b) => {
          const bt = ctx.buildingTypes?.[b.building_type_key];
          return bt && bt.category === 'housing' && b.housing_tier === Number(tier);
        }).length;
        lifestyleRate += houseCount * Number(d.qty_per_minute);
      }
    }
    if (lifestyleRate > 0) flow.citizens += lifestyleRate;
  }

  // NPC trade flow — cap-aware sustained rate projections.
  const policy = ctx.tradePolicies?.[resourceKey];
  if (policy && policy.mode !== 'keep') {
    const DAY = 24 * 60;
    for (const tk in (ctx.traders || {})) {
      const t = ctx.traders[tk];
      const prices = ctx.allTraderPrices?.[tk]?.[resourceKey];
      if (!prices) continue;
      const burst = (Number(t.visit_capacity) || 0) / (Number(t.visit_interval_minutes) || 1);
      if (policy.mode === 'sell_surplus' && prices.buy_price) {
        const sustained = prices.daily_buy_cap != null
          ? Math.min(burst, Number(prices.daily_buy_cap) / DAY) : burst;
        flow.exports.push({ trader: t.name, rate: sustained, price: prices.buy_price });
      } else if (policy.mode === 'buy_to_reserve' && prices.sell_price) {
        const sustained = prices.daily_sell_cap != null
          ? Math.min(burst, Number(prices.daily_sell_cap) / DAY) : burst;
        flow.imports.push({ trader: t.name, rate: sustained, price: prices.sell_price });
      }
    }
  }

  return flow;
}

function hasNearbyService(building, serviceKey, range, requiresFeeding, ctx) {
  const myId = building.player_id;
  for (const s of ctx.allBuildings || []) {
    if (s.player_id !== myId) continue;
    if (s.building_type_key !== serviceKey) continue;
    if (s.status !== 'active') continue;
    const dist = Math.abs(s.x - building.x) + Math.abs(s.y - building.y);
    if (dist > range) continue;
    if (!requiresFeeding) return true;
    if (!s.is_staffed) continue;
    const sbt = ctx.buildingTypes?.[serviceKey];
    if (!sbt) continue;
    if (sbt.input_resource_key && Number(sbt.input_rate) > 0
        && Number(ctx.inventory?.[sbt.input_resource_key] || 0) <= 0) continue;
    if (sbt.input_resource_key_2 && Number(sbt.input_rate_2) > 0
        && Number(ctx.inventory?.[sbt.input_resource_key_2] || 0) <= 0) continue;
    return true;
  }
  return false;
}

// Walk the building's footprint perimeter (NOT just the anchor) and
// return true if any neighbor tile is a road. Multi-tile buildings
// touch 2(fw+fh) perimeter cells; anchor-only checks would miss the
// right + bottom edges (see feedback_multitile_perimeter memory).
function hasRoadOnPerimeter(b, bt, roadSet) {
  const fw = bt.footprint_w || 1;
  const fh = bt.footprint_h || 1;
  for (let dx = 0; dx < fw; dx++) {
    if (roadSet.has(b.x + dx + ',' + (b.y - 1))) return true;
    if (roadSet.has(b.x + dx + ',' + (b.y + fh))) return true;
  }
  for (let dy = 0; dy < fh; dy++) {
    if (roadSet.has((b.x - 1) + ',' + (b.y + dy))) return true;
    if (roadSet.has((b.x + fw) + ',' + (b.y + dy))) return true;
  }
  return false;
}

// ── Resource-tile kind ─────────────────────────────────────────
//
// Resource-key → visual kind. The resources table's `kind` column
// (raw / processed / terrain) is too coarse to drive icons, so we
// derive a finer kind from the key itself. Each kind has a drawn
// texture (`res-wood`, `res-stone`, etc.).
export function resourceKindFor(resourceKey, resource) {
  const k = (resourceKey || '').toLowerCase();
  if (k.includes('timber') || k.includes('forest') || k.includes('orchard') || k.includes('grove')) return 'wood';
  if (k.includes('stone') || k.includes('quarry') || k.includes('rock')) return 'stone';
  if (k.includes('iron') || k.includes('ore') || k.includes('metal')) return 'metal';
  if (k.includes('clay'))   return 'clay';
  if (k.includes('grain')  || k.includes('farmland') || k.includes('field')) return 'food';
  if (k.includes('garden') || k.includes('plot'))     return 'food';
  if (k.includes('pond')   || k.includes('water')    || k.includes('lake') || k.includes('river') || k.includes('fish')) return 'fish';
  if (resource?.industry_key === 'timber') return 'wood';
  if (resource?.industry_key === 'stone')  return 'stone';
  if (resource?.industry_key === 'iron')   return 'metal';
  if (resource?.industry_key === 'clay')   return 'clay';
  return 'default';
}

// ── Walker variant picker ──────────────────────────────────────
//
// Building → walker variant key. Picks the v1 walker SVG that best
// fits the source building. Housing spawns one of four "citizen"
// personas at random for visual variety; specific industries spawn
// their job-specific worker; services spawn their domain figure.
export function pickWalkerVariant(b, bt) {
  if (bt.category === 'housing') {
    const personas = ['citizen', 'child', 'elder', 'fat', 'couple'];
    return personas[Math.floor(Math.random() * personas.length)];
  }
  const key = b.building_type_key || '';
  if (key === 'timber_camp')   return 'timber';
  if (key === 'sawmill')       return 'sawmill';
  if (key === 'stone_quarry')  return 'stone';
  if (key === 'grain_farm' || key === 'mill') return 'grain';
  if (key === 'iron_mine')     return 'iron';
  if (key === 'clay_pit' || key === 'pottery_kiln' || key === 'clay_master_hut') return 'clay';
  if (key === 'orchard')       return 'orchard';
  if (key === 'fishing_pier')  return 'fish';
  if (key === 'garden')        return 'garden';
  if (key === 'tavern')        return 'tavern';
  if (key === 'bathhouse')     return 'bathhouse';
  if (key === 'school')        return 'school';
  if (key === 'temple')        return 'temple';
  if (key === 'tax_man' || key === 'foreman_office' || key === 'mine_office') return 'civic';
  return 'citizen';
}

// ── Building AoE range ─────────────────────────────────────────
//
// Returns { range, kind } for a building that has gameplay coverage,
// or null otherwise. Ranges match the server-side gate checks in
// `_pp_evolve_housing` for services and the building_types columns
// for police / park / booster.
export function getBuildingAoeRange(b, bt) {
  if (!bt) return null;
  if (bt.category === 'police' && bt.coverage_radius > 0) {
    return { range: bt.coverage_radius, kind: 'police' };
  }
  if (bt.category === 'park' && bt.pollution_radius > 0) {
    return { range: bt.pollution_radius, kind: 'park' };
  }
  if (bt.category === 'booster' && bt.boost_range > 0) {
    return { range: bt.boost_range, kind: 'booster' };
  }
  if (bt.category === 'service') {
    if (bt.key === 'well')      return { range: 4, kind: 'well' };
    if (bt.key === 'school')    return { range: 5, kind: 'school' };
    if (bt.key === 'temple')    return { range: 6, kind: 'temple' };
    if (bt.key === 'bathhouse') return { range: 4, kind: 'bathhouse' };
  }
  return null;
}

// ── Heatmap tint ────────────────────────────────────────────────
//
// Returns { tint, alpha } for a tile's value under a given mode.
// alpha=0 means "no overlay drawn".
export function heatmapTintFor(mode, value) {
  if (mode === 'pollution') {
    if (value <= 0) return { tint: 0, alpha: 0 };
    const t = Math.min(1, value / 30);
    return { tint: 0xe85a3a, alpha: 0.15 + t * 0.45 };
  }
  if (mode === 'desirability') {
    if (value < 30) {
      const t = (30 - value) / 30;
      return { tint: 0xc83a3a, alpha: 0.15 + t * 0.4 };
    }
    if (value > 70) {
      const t = Math.min(1, (value - 70) / 30);
      return { tint: 0x3ac860, alpha: 0.15 + t * 0.4 };
    }
    return { tint: 0, alpha: 0 };
  }
  if (mode === 'crime') {
    if (value < 50) return { tint: 0, alpha: 0 };
    return { tint: 0xc84878, alpha: 0.42 };
  }
  if (mode === 'issues') {
    if (value < 50) return { tint: 0, alpha: 0 };
    return { tint: 0xf0a838, alpha: 0.5 };
  }
  return { tint: 0, alpha: 0 };
}

// ── World bounds from a state snapshot ──────────────────────────
//
// Returns { minX, minY, cols, rows } covering every owned tile AND
// every visible building. Pass tileMap + buildings explicitly so
// this stays pure / testable.
export function computeWorldBounds(tileMap, allBuildings) {
  let minX = Infinity, maxX = -Infinity, minY = Infinity, maxY = -Infinity;
  for (const k in tileMap) {
    const t = tileMap[k];
    if (t.x < minX) minX = t.x; if (t.x > maxX) maxX = t.x;
    if (t.y < minY) minY = t.y; if (t.y > maxY) maxY = t.y;
  }
  for (const b of allBuildings) {
    if (b.x < minX) minX = b.x;
    if (b.x > maxX) maxX = b.x;
    if (b.y < minY) minY = b.y;
    if (b.y > maxY) maxY = b.y;
  }
  if (!isFinite(minX)) return { minX: 0, minY: 0, cols: 0, rows: 0 };
  return { minX, minY, cols: maxX - minX + 1, rows: maxY - minY + 1 };
}

// ── Tutorial gating ─────────────────────────────────────────────
//
// Each tutorial step (0..3) limits which building categories the
// player can see in the Build tab. step 4 = done, all unlocked.
// Mirrors v1's tutorialAllowsBuilding in ui.js.
export function tutorialAllowsBuilding(bt, tutorialStep) {
  const step = tutorialStep ?? 4;
  if (step >= 4) return true;
  if (!bt) return false;
  if (bt.category === 'road') return true;
  if (step === 0) return bt.category === 'housing';
  if (step === 1) return bt.category === 'housing' || bt.key === 'well';
  if (step === 2) {
    return bt.category === 'housing' || bt.key === 'well' || bt.category === 'food_extractor';
  }
  if (step === 3) {
    return bt.category === 'housing' || bt.key === 'well'
      || bt.category === 'food_extractor' || bt.category === 'extractor';
  }
  return false;
}

// ── Heatmap data computation ────────────────────────────────────
//
// Set of "x,y" tile keys covered by any of `myId`'s staffed active
// police buildings' manhattan disks. Pure function so tests don't
// need a Phaser scene to validate the geometry.
export function computePoliceCoverage(allBuildings, buildingTypes, myId) {
  const covered = new Set();
  for (const b of allBuildings) {
    if (b.player_id !== myId) continue;
    const bt = buildingTypes[b.building_type_key];
    if (!bt || bt.category !== 'police') continue;
    if (b.status !== 'active' || !b.is_staffed) continue;
    const r = bt.coverage_radius || 0;
    const fw = bt.footprint_w || 1, fh = bt.footprint_h || 1;
    for (let dx = 0; dx < fw; dx++) {
      for (let dy = 0; dy < fh; dy++) {
        for (let rx = -r; rx <= r; rx++) {
          for (let ry = -r; ry <= r; ry++) {
            if (Math.abs(rx) + Math.abs(ry) <= r) {
              covered.add((b.x + dx + rx) + ',' + (b.y + dy + ry));
            }
          }
        }
      }
    }
  }
  return covered;
}

// Tile keys covered by buildings owned by `myId` that are in a
// problem state — idle, unstaffed-but-needs-workers, or paused.
// Used by the building-issues heatmap.
export function computeProblemTiles(allBuildings, buildingTypes, myId) {
  const tiles = new Set();
  for (const b of allBuildings) {
    if (b.player_id !== myId) continue;
    const bt = buildingTypes[b.building_type_key];
    if (!bt) continue;
    const isProblem =
      b.status === 'idle' ||
      (bt.worker_cost > 0 && !b.is_staffed) ||
      b.paused === true;
    if (!isProblem) continue;
    const fw = bt.footprint_w || 1, fh = bt.footprint_h || 1;
    for (let dx = 0; dx < fw; dx++) {
      for (let dy = 0; dy < fh; dy++) {
        tiles.add((b.x + dx) + ',' + (b.y + dy));
      }
    }
  }
  return tiles;
}

// ── Resource production / consumption ──────────────────────────
//
// Iterates myId's active staffed unpaused buildings, sums their
// output / input rates by resource_key. Returns { prod, cons } maps
// where keys are resource keys and values are per-minute floats.
// Tax revenue (output_resource_key='money' or category='tax') is
// excluded from prod — handled separately by the runway calc.
export function computeResourceProdCons(allBuildings, buildingTypes, myId) {
  const prod = {};
  const cons = {};
  for (const b of allBuildings) {
    if (b.player_id !== myId) continue;
    if (b.status !== 'active' || !b.is_staffed || b.paused) continue;
    const bt = buildingTypes[b.building_type_key];
    if (!bt) continue;
    if (bt.output_resource_key && bt.output_rate > 0 && bt.category !== 'tax') {
      prod[bt.output_resource_key] = (prod[bt.output_resource_key] || 0) + Number(bt.output_rate);
    }
    if (bt.input_resource_key && bt.input_rate > 0) {
      cons[bt.input_resource_key] = (cons[bt.input_resource_key] || 0) + Number(bt.input_rate);
    }
    if (bt.input_resource_key_2 && bt.input_rate_2 > 0) {
      cons[bt.input_resource_key_2] = (cons[bt.input_resource_key_2] || 0) + Number(bt.input_rate_2);
    }
  }
  return { prod, cons };
}

// ── Walker SVG sizing ──────────────────────────────────────────
//
// Inject explicit width/height into a walker SVG data URI so the
// browser rasterizes it at a known small size. Returns a new
// data URI with width="<vb_w * 4>" height="<vb_h * 4>" added. If
// the viewBox can't be parsed, returns the input unchanged.
export function sizeWalkerSvg(dataUri) {
  // Accept either single or double quotes around viewBox so the
  // helper isn't brittle to upstream string-formatting changes.
  const m = dataUri.match(/viewBox=['"]([\d.\s]+)['"]/);
  if (!m) return dataUri;
  const parts = m[1].split(/\s+/);
  if (parts.length !== 4) return dataUri;
  const vbW = parseFloat(parts[2]);
  const vbH = parseFloat(parts[3]);
  if (!Number.isFinite(vbW) || !Number.isFinite(vbH)) return dataUri;
  const w = Math.round(vbW * 4);
  const h = Math.round(vbH * 4);
  return dataUri.replace(/<svg\s+/, `<svg width='${w}' height='${h}' `);
}
