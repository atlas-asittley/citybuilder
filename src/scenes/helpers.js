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
export function getHousingDevolveRisks(building, currentTierCfg, ctx) {
  if (!currentTierCfg) return { blockers: [], hasBathhouseCover: false, willDevolve: false };
  const blockers = getHousingUpgradeBlockers(building, currentTierCfg, ctx);
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
