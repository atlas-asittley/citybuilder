// Housing tier prereq evaluation. Mirrors the SQL gates inside
// _pp_evolve_housing on the server so the inspector can show the
// player exactly what blocks an upgrade — or what's about to trigger
// a devolve. All pure helpers; ctx-bag passed in so they're testable
// without a live state object.
//
// ctx shape:
//   roadSet                  — Set of "x,y" string keys for road tiles
//   allBuildings             — array of buildings (any owner)
//   buildingTypes            — keyed by building_type_key
//   tileMap                  — keyed by "x,y"
//   inventory                — resource_key → numeric
//   resources                — resource_key → row (carries is_food / is_luxury_food / is_industrial_luxury / name)
//   housingLifestyleDemands  — tier → [{ resource_key, qty_per_minute }]
//   buildingBuffers          — building_id → resource_key → { quantity, capacity } (optional; per-house pantry)

import { hasRoadOnPerimeter } from './helpers.js';

// Returns the array of prerequisite keys that are NOT met for the
// passed tier config. Used two ways:
//   - getHousingUpgradeBlockers(b, nextTierCfg, ctx) → "what blocks the upgrade?"
//   - getHousingUpgradeBlockers(b, currentTierCfg, ctx) → "what would devolve?"
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

  // Cumulative lifestyle demands for this tier — each missing resource
  // is its own blocker so the player knows exactly which good ran out.
  // A demand is satisfied by the primary OR any registered substitute
  // (e.g. bread accepts spices/caviar/spirits).
  const demands = ctx.housingLifestyleDemands?.[tierCfg.tier] || [];
  for (const d of demands) {
    if (!lifestyleDemandSatisfied(d.resource_key, ctx)) {
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
// staffed + fed bathhouse within 4 tiles suppresses devolve.
//
// When per-house pantry buffers are loaded (ctx.buildingBuffers[b.id]),
// the food + lifestyle:<rk> gates re-evaluate against the building's
// OWN buffer rather than city stock — a house with 50 timber in city
// but a half-full food pantry will NOT show food devolve risk, since
// the buffer is what the server actually drains from.
export function getHousingDevolveRisks(building, currentTierCfg, ctx) {
  if (!currentTierCfg) return { blockers: [], hasBathhouseCover: false, willDevolve: false };
  const globalBlockers = getHousingUpgradeBlockers(building, currentTierCfg, ctx);
  const buf = (ctx.buildingBuffers && ctx.buildingBuffers[building.id]) || null;

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
    // Catch pantry-empty cases the global check missed (city stock
    // refilled but pantry hasn't refilled yet).
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

// Friendly forward-looking copy ("needs X"). Used in the upgrade-
// blocker + active-devolve-risk lists. `ctx` is optional — when
// provided, lifestyle demands with multiple acceptable goods list all
// of them equally ("any of Bread / Spices / Caviar / Spirits").
export function describeHousingBlocker(key, resources, ctx) {
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
    const allNames = lifestyleGroupNames(rk, ctx, resources);
    if (allNames.length > 1) {
      return `any of ${allNames.join(' / ')} in stock`;
    }
    return `${allNames[0]} in stock (this tier consumes it ongoingly)`;
  }
  return key;
}

// Past-tense copy ("ran out of X"). Used by the inspector's last-
// devolved row.
export function describeHousingDevolveReason(key, resources, ctx) {
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
    const allNames = lifestyleGroupNames(rk, ctx, resources);
    if (allNames.length > 1) {
      return `ran out of all of ${allNames.join(' / ')}`;
    }
    return `ran out of ${allNames[0]}`;
  }
  return key;
}

// ── Private helpers ─────────────────────────────────────────────

// Mirrors the SQL upgrade gate: a lifestyle demand for `primary` is
// satisfied if either the primary OR any registered substitute has
// stock in city inventory.
function lifestyleDemandSatisfied(primary, ctx) {
  if (Number(ctx.inventory?.[primary] || 0) > 0) return true;
  const subs = ctx.lifestyleSubstitutes?.[primary] || [];
  for (const s of subs) {
    if (Number(ctx.inventory?.[s] || 0) > 0) return true;
  }
  return false;
}

// Returns every good that satisfies this demand, treated as equals
// (primary + any registered substitutes). Used by the blocker/devolve
// copy so the four-good demand reads as "any of A / B / C / D" with no
// one good treated as canonical.
function lifestyleGroupNames(primary, ctx, resources) {
  const primaryName = resources?.[primary]?.name || primary;
  const subs = ctx?.lifestyleSubstitutes?.[primary] || [];
  return [primaryName, ...subs.map((k) => resources?.[k]?.name || k)];
}

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

// Service proximity uses Chebyshev (king's-move) distance so a "range
// of 5" reads as a 5-tile square around the building — what a player
// visually estimates when looking at the map. Switched from Manhattan
// 2026-05-20 after Jill reported townhouses at Chebyshev=4 from her
// school still saying "no operating school" because Manhattan=6.
// Server gates in _pp_evolve_housing + has_well_access mirror this.
function hasNearbyService(building, serviceKey, range, requiresFeeding, ctx) {
  const myId = building.player_id;
  for (const s of ctx.allBuildings || []) {
    if (s.player_id !== myId) continue;
    if (s.building_type_key !== serviceKey) continue;
    if (s.status !== 'active') continue;
    const dist = Math.max(Math.abs(s.x - building.x), Math.abs(s.y - building.y));
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
