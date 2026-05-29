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
  sig += '|p' + (b.status === 'paused' ? 1 : 0);
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

  // Pause is stored as status='paused' in the DB (no separate boolean
  // column). v2 originally read b.paused which is always undefined, so
  // the paused branch never fired. Now reads status directly.
  if (b.status === 'paused') {
    return [{ kind: 'paused', label: 'Paused', symbol: '⏸',
      hint: 'Tap Resume to restart production.' }];
  }
  // Transport hubs + connectors carry a worker_cost in the catalog
  // but the server's _pp_staff_buildings excludes those categories
  // entirely — they never get is_staffed=true even when workers are
  // available. Don't report them as unstaffed; the worker_cost field
  // is a build-cost balancing knob, not a runtime allocation.
  const isTransport = bt.category === 'transport_hub' || bt.category === 'transport_connector';
  if (bt.worker_cost > 0 && !b.is_staffed && !isTransport) {
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

  // Missing-input only fires when inventory has actually loaded. On
  // initial scene render (before the first process_production tick
  // lands), state.inventory is empty {} — which would fire no-input
  // for every staffed processor/service in the city and badge them
  // all red until the first tick arrives. Skip the check until we
  // have at least one resource known to be present; the next render
  // after the tick lands will fire it correctly.
  const inventoryLoaded = inventory && Object.keys(inventory).length > 0;
  if (b.is_staffed && inventoryLoaded) {
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

// Cheap deterministic hash from (x, y) tile coords to a positive
// integer. Used by the grass-tile picker to choose a variant + a
// decoration overlay deterministically — same coords always pick
// the same flower / pattern across re-renders, and every player
// sharing the city sees the same decoration on the same tile.
//
// Mix uses Knuth multiplicative constants (2654435761 = ⌊2³² × φ⌋,
// 1597334677 = a co-prime). Final xor-shift smears low bits so
// (x, y+1) and (x, y) end up in distant slots of the hash space.
export function tileHash(x, y) {
  let h = (x | 0) * 2654435761 + (y | 0) * 1597334677;
  // Force-unsigned 32-bit; xor-shift to mix the high bits down.
  return (h ^ (h >>> 15)) >>> 0;
}

// ── Housing tier gating ────────────────────────────────────────
// Extracted to scenes/housing.js. Re-exported here for back-compat
// with existing imports across the inspector + tests; new callsites
// should import directly from scenes/housing.js.
export {
  getHousingUpgradeBlockers,
  getHousingDevolveRisks,
  describeHousingBlocker,
  describeHousingDevolveReason
} from './housing.js';

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
// traders, allTraderPrices, profile. Pass null for any unused subsystem
// and the section silently returns empty. `profile` drives productivity
// scaling on production/consumption.
export function computeResourceFlow(resourceKey, ctx, myId) {
  const flow = {
    production: [], processing: [], services: [],
    citizens: 0, exports: [], imports: []
  };
  if (!ctx || !ctx.allBuildings) return flow;

  const productivity = getProductivity(ctx.profile);
  const myActive = ctx.allBuildings.filter((b) =>
    b.player_id === myId && b.status === 'active');

  // Group worker-consuming buildings by type, only counting staffed.
  // Per-instance production rates accumulate into prodSum because
  // extractors with different path_lengths and booster coverage
  // produce different rates even within the same building type.
  const byType = {};
  for (const b of myActive) {
    const bt = ctx.buildingTypes?.[b.building_type_key];
    if (!bt) continue;
    if (bt.category === 'road' || bt.category === 'housing') continue;
    if (!b.is_staffed) continue;
    if (!byType[bt.key]) byType[bt.key] = { bt, count: 0, prodSum: 0 };
    byType[bt.key].count++;
    if (bt.output_resource_key === resourceKey && Number(bt.output_rate) > 0) {
      byType[bt.key].prodSum += effectiveOutputRate(
        b, bt, ctx.allBuildings, ctx.buildingTypes, myId, productivity
      );
    }
  }
  for (const k in byType) {
    const grp = byType[k];
    const bt = grp.bt;
    const count = grp.count;
    if (bt.output_resource_key === resourceKey && Number(bt.output_rate) > 0 && grp.prodSum > 0) {
      flow.production.push({ name: bt.name, count, rate: grp.prodSum });
    }
    if (bt.input_resource_key === resourceKey && Number(bt.input_rate) > 0) {
      const item = { name: bt.name, count, rate: count * Number(bt.input_rate) * productivity };
      if (bt.output_resource_key && ctx.resources?.[bt.output_resource_key]) {
        item.output = ctx.resources[bt.output_resource_key].name;
      }
      (bt.category === 'service' ? flow.services : flow.processing).push(item);
    }
    if (bt.input_resource_key_2 === resourceKey && Number(bt.input_rate_2) > 0) {
      const item = { name: bt.name, count, rate: count * Number(bt.input_rate_2) * productivity };
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
  if (policy && policy.mode !== 'hold') {
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

// Housing capacity for the topbar's "pop / cap" stat. Mirrors v1's
// state.js calc: post-tutorial 15-citizen floor + sum of each
// active road-connected house's tier.workers. Houses at tiers 0-2
// don't need a road (housing_tier_config.needs_road is false).
export function computeHousingCapacity(allBuildings, buildingTypes, housingTierConfig, myId, profile) {
  const roadSet = new Set();
  for (const b of allBuildings) {
    const bt = buildingTypes[b.building_type_key];
    if (bt && bt.category === 'road' && b.player_id === myId) {
      roadSet.add(b.x + ',' + b.y);
    }
  }
  let supply = 0;
  for (const b of allBuildings) {
    if (b.player_id !== myId) continue;
    if (b.status !== 'active') continue;
    const bt = buildingTypes[b.building_type_key];
    if (!bt || bt.category !== 'housing') continue;
    const tier = (b.housing_tier !== undefined && b.housing_tier !== null) ? b.housing_tier : 0;
    const tierCfg = housingTierConfig[tier];
    if (!tierCfg) continue;
    if (tierCfg.needs_road && !hasRoadOnPerimeter(b, bt, roadSet)) continue;
    supply += tierCfg.workers || 0;
  }
  const inTutorial = profile && profile.tutorial_step != null && profile.tutorial_step < 4;
  const popFloor = inTutorial ? 0 : 15;
  return popFloor + supply;
}

// Walk the building's footprint perimeter (NOT just the anchor) and
// return true if any neighbor tile is a road. Multi-tile buildings
// touch 2(fw+fh) perimeter cells; anchor-only checks would miss the
// right + bottom edges (see feedback_multitile_perimeter memory).
export function hasRoadOnPerimeter(b, bt, roadSet) {
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
  // Order matters — more specific keys first (orchard/grove must
  // match BEFORE the generic timber/forest fallback, since they're
  // different tile types).
  if (k.includes('orchard') || k.includes('grove')) return 'orchard';
  if (k.includes('timber')  || k.includes('forest')) return 'wood';
  if (k.includes('stone') || k.includes('quarry') || k.includes('rock')) return 'stone';
  if (k.includes('iron') || k.includes('ore') || k.includes('metal')) return 'metal';
  if (k.includes('clay'))   return 'clay';
  // Split food terrain types so a player can tell at a glance
  // whether they're looking at a wheat field, a garden plot, or
  // (future) other crop tiles.
  if (k.includes('grain') || k.includes('farmland') || k.includes('field')) return 'grain';
  if (k.includes('garden') || k.includes('plot'))    return 'vegetables';
  if (k.includes('pond') || k.includes('water') || k.includes('lake') || k.includes('river') || k.includes('fish')) return 'fish';
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
    // Weighted persona pool — citizens dominate, with rarer flavor
    // variants. Higher tiers can roll fancier sprites; lower tiers
    // skew to plain citizens + occasional kids/elders.
    const tier = b.housing_tier ?? 0;
    const pool = ['citizen', 'citizen', 'citizen', 'child', 'elder', 'fat', 'couple'];
    // Civic + extractor walker variants double as "fancy" personas
    // for higher-tier housing — adds visual signaling that a Villa
    // produces different-looking foot traffic than a Shanty.
    if (tier >= 4) pool.push('civic', 'tavern');
    if (tier >= 6) pool.push('temple', 'school');
    return pool[Math.floor(Math.random() * pool.length)];
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
  // Civic amenities (Public Garden, Monument, future Plaza/Library):
  // their desirability_radius drives the placement-preview AoE diamond
  // so players can see exactly which tiles a candidate placement
  // would lift.
  if (bt.category === 'civic' && bt.desirability_radius > 0) {
    return { range: bt.desirability_radius, kind: 'civic' };
  }
  if (bt.category === 'sanitation' && bt.coverage_radius > 0) {
    return { range: bt.coverage_radius, kind: 'sanitation' };
  }
  // Upgraded roads project a desirability aura (dirt road = 0, no ring).
  if (bt.category === 'road' && bt.desirability_radius > 0) {
    return { range: bt.desirability_radius, kind: 'road' };
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
  if (mode === 'waste') {
    // Mirrors crime: housing outside staffed sanitation coverage is
    // tinted (value 100 = uncovered), clean tiles draw nothing.
    if (value < 50) return { tint: 0, alpha: 0 };
    return { tint: 0x8a6d3b, alpha: 0.42 };
  }
  if (mode === 'noise') {
    // Per-tile, scaled like pollution (purple).
    if (value <= 0) return { tint: 0, alpha: 0 };
    const t = Math.min(1, value / 20);
    return { tint: 0xa050b0, alpha: 0.15 + t * 0.45 };
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
// buildings of a given category, over each footprint cell's manhattan
// coverage_radius disk. Pure so tests don't need a Phaser scene.
// Coverage-style heatmaps (crime/waste/…) red-tint the UNcovered tiles.
export function computeCoverageForCategory(allBuildings, buildingTypes, myId, category) {
  const covered = new Set();
  for (const b of allBuildings) {
    if (b.player_id !== myId) continue;
    const bt = buildingTypes[b.building_type_key];
    if (!bt || bt.category !== category) continue;
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

// Police coverage (crime heatmap) and sanitation coverage (waste heatmap)
// are the same geometry over different categories.
export const computePoliceCoverage = (allBuildings, buildingTypes, myId) =>
  computeCoverageForCategory(allBuildings, buildingTypes, myId, 'police');
export const computeSanitationCoverage = (allBuildings, buildingTypes, myId) =>
  computeCoverageForCategory(allBuildings, buildingTypes, myId, 'sanitation');

// Tile keys covered by buildings owned by `myId` that are in a
// problem state — idle, unstaffed-but-needs-workers, or paused.
// Used by the building-issues heatmap.
export function computeProblemTiles(allBuildings, buildingTypes, myId) {
  const tiles = new Set();
  for (const b of allBuildings) {
    if (b.player_id !== myId) continue;
    const bt = buildingTypes[b.building_type_key];
    if (!bt) continue;
    // Transport hubs / connectors aren't subject to the staffing
    // loop — their worker_cost is a build-cost knob — so don't flag
    // them as "problem unstaffed" tiles on the issues heatmap.
    const isTransport = bt.category === 'transport_hub' || bt.category === 'transport_connector';
    const isProblem =
      b.status === 'paused' ||
      (bt.worker_cost > 0 && !b.is_staffed && !isTransport);
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

// ── Production-rate scaling helpers ────────────────────────────
//
// The server's per-tick formulas are:
//   extractor       output = output_rate × min(1, 4/path_length) × boost × productivity
//   food_extractor  output = output_rate × boost × productivity (no path)
//   processor       in/out = rate × min(input_avail/need) × productivity
//
// The UI's net-rate display assumes max progress (=1), so processors
// are simply rate × productivity. Extractors and food_extractors need
// per-instance lookups (path + booster proximity), so we expose the
// scaling helpers below for both the city-wide aggregate and the
// per-resource flow drilldown.

// Productivity multiplier from the player's profile. Defaults to 1.0
// when missing — same as the server's `COALESCE(productivity, 1.0)`.
export function getProductivity(profile) {
  return profile?.productivity != null ? Number(profile.productivity) : 1.0;
}

// MAX booster multiplier applicable to a given extractor or
// food_extractor. Mirrors the server: only staffed + active boosters
// of matching boost_target within Manhattan ≤ boost_range count, and
// multiple in range take the MAX (no stacking).
export function getBoosterMultiplier(b, bt, allBuildings, buildingTypes, myId) {
  if (!bt) return 1.0;
  if (bt.category !== 'extractor' && bt.category !== 'food_extractor') return 1.0;
  let maxMult = 1.0;
  for (const b2 of allBuildings) {
    if (b2.player_id !== myId) continue;
    if (b2.status !== 'active' || !b2.is_staffed) continue;
    const bt2 = buildingTypes[b2.building_type_key];
    if (!bt2 || bt2.category !== 'booster') continue;
    if (bt2.boost_target !== bt.category) continue;
    const range = Number(bt2.boost_range) || 0;
    if (Math.abs(b2.x - b.x) + Math.abs(b2.y - b.y) > range) continue;
    const mult = Number(bt2.boost_multiplier) || 1.0;
    if (mult > maxMult) maxMult = mult;
  }
  return maxMult;
}

// Effective per-minute output rate for one building. Applies path-
// length scaling (extractors only — food_extractors have no claimed
// target), booster proximity, and productivity. For extractors with
// no claimed target (path_length null/0), returns 0 — matches the
// server's "CONTINUE if path_length IS NULL".
export function effectiveOutputRate(b, bt, allBuildings, buildingTypes, myId, productivity) {
  const base = Number(bt?.output_rate) || 0;
  if (!base) return 0;
  if (bt.category === 'extractor') {
    const pl = Number(b.path_length);
    if (!pl || pl <= 0) return 0;
    const pathFactor = Math.min(1, 4 / pl);
    const boost = getBoosterMultiplier(b, bt, allBuildings, buildingTypes, myId);
    return base * pathFactor * boost * productivity;
  }
  if (bt.category === 'food_extractor') {
    const boost = getBoosterMultiplier(b, bt, allBuildings, buildingTypes, myId);
    return base * boost * productivity;
  }
  // Processors / services / tax — flat rate × productivity.
  return base * productivity;
}

// ── Resource production / consumption ──────────────────────────
//
// Iterates myId's active staffed unpaused buildings, sums their
// output / input rates by resource_key. Returns { prod, cons } maps
// where keys are resource keys and values are per-minute floats.
// Tax revenue (output_resource_key='money' or category='tax') is
// excluded from prod — handled separately by the runway calc.
//
// `profile` is required for the productivity multiplier and lets the
// extractor scaling read the same values the server uses. Without it
// the rates default to base × 1.0, which under-reports a city with a
// tavern/education productivity bonus and over-reports a city with a
// crime drag.
export function computeResourceProdCons(allBuildings, buildingTypes, myId, profile) {
  const prod = {};
  const cons = {};
  const productivity = getProductivity(profile);
  for (const b of allBuildings) {
    if (b.player_id !== myId) continue;
    if (b.status !== 'active' || !b.is_staffed) continue;
    const bt = buildingTypes[b.building_type_key];
    if (!bt) continue;
    if (bt.output_resource_key && bt.output_rate > 0 && bt.category !== 'tax') {
      const rate = effectiveOutputRate(b, bt, allBuildings, buildingTypes, myId, productivity);
      if (rate > 0) {
        prod[bt.output_resource_key] = (prod[bt.output_resource_key] || 0) + rate;
      }
    }
    if (bt.input_resource_key && bt.input_rate > 0) {
      cons[bt.input_resource_key] = (cons[bt.input_resource_key] || 0) + Number(bt.input_rate) * productivity;
    }
    if (bt.input_resource_key_2 && bt.input_rate_2 > 0) {
      cons[bt.input_resource_key_2] = (cons[bt.input_resource_key_2] || 0) + Number(bt.input_rate_2) * productivity;
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
export function sizeSvgDataUri(dataUri, scale) {
  // Inject explicit width/height into an SVG data URI so the browser
  // rasterizes it at a known size. Without width/height the browser
  // rasterizes viewBox-only SVGs at its default surface (~300×150),
  // which on mobile (a) wastes massive texture memory and (b) tips
  // some devices into silent texture-upload failure — the building
  // sprites show up as Phaser's __MISSING black square.
  //
  // `scale` multiplies the viewBox dimensions. We use 4 for walkers
  // (small source, supersample for crispness) and 2 for buildings
  // (already 64×64 source, 2× plenty for retina mobile).
  //
  // Returns the input unchanged if viewBox can't be parsed (defensive
  // — better to ship a possibly-large sprite than crash the loader).
  //
  // sprites.js mixes THREE encodings inside the data URI:
  //   1. `viewBox='0 0 64 64'`           literal quotes, literal spaces
  //   2. `viewBox="0 0 64 64"`           literal quotes, literal spaces
  //   3. `viewBox=%220%200%2064%2064%22` %22 quotes, %20 spaces (45/57)
  // Plus the `<svg>` open tag is sometimes literal, sometimes %3Csvg,
  // and (`mill` / `grain_farm`) sometimes `%3Csvg%20`. Handle all of
  // them — a silent no-op on any of these forms shows up to the player
  // as a black square for that building type.
  const m = dataUri.match(/viewBox=(?:%22|['"])([^'"]*?)(?:%22|['"])/);
  if (!m) return dataUri;
  const parts = m[1].split(/\s+|%20/);
  if (parts.length !== 4) return dataUri;
  const vbW = parseFloat(parts[2]);
  const vbH = parseFloat(parts[3]);
  if (!Number.isFinite(vbW) || !Number.isFinite(vbH)) return dataUri;
  const w = Math.round(vbW * scale);
  const h = Math.round(vbH * scale);
  // Match the <svg open tag in whichever form the URI uses. The
  // separator after `svg` is either a literal space or %20. Transport
  // hub sprites use `<svg%20...` (literal angle bracket, encoded
  // space) — the regex has to cover both separators in both branches.
  if (dataUri.includes('%3Csvg')) {
    return dataUri.replace(/%3Csvg(?:%20|\s)+/,
      `%3Csvg width='${w}' height='${h}' `);
  }
  return dataUri.replace(/<svg(?:%20|\s)+/,
    `<svg width='${w}' height='${h}' `);
}

// Backwards-compatible alias for the original walker-specific entry
// point. Scale=4 matches the original sizing.
export function sizeWalkerSvg(dataUri) {
  return sizeSvgDataUri(dataUri, 4);
}
