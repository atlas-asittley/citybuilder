import { describe, it, expect } from 'vitest';
import {
  buildingSignature,
  resourceKindFor,
  pickWalkerVariant,
  getBuildingAoeRange,
  heatmapTintFor,
  computeWorldBounds,
  sizeWalkerSvg,
  tutorialAllowsBuilding,
  computePoliceCoverage,
  computeProblemTiles,
  computeResourceProdCons,
  computeBuildingIssue,
  listBuildingIssues,
  getHousingUpgradeBlockers,
  getHousingDevolveRisks,
  describeHousingBlocker,
  describeHousingDevolveReason
} from './helpers.js';

describe('buildingSignature', () => {
  const roads = new Set();

  it('encodes position, type, tier, status, staffed, paused', () => {
    const b = {
      building_type_key: 'house', x: 5, y: 10, housing_tier: 3,
      status: 'active', is_staffed: true, paused: false,
      expansion_level: 0, player_id: 'me'
    };
    const bt = { category: 'housing' };
    const sig = buildingSignature(b, bt, roads, 'me');
    expect(sig).toBe('house|5,10|t3|sactive|w1|p0|e0|ome|qn');
  });

  it('includes issue kind, defaults to "n" (none)', () => {
    const b = {
      building_type_key: 'mill', x: 0, y: 0, status: 'active',
      is_staffed: true, paused: false, player_id: 'me'
    };
    const bt = { category: 'processor' };
    expect(buildingSignature(b, bt, roads, 'me')).toContain('|qn');
    expect(buildingSignature(b, bt, roads, 'me', 'unstaffed')).toContain('|qunstaffed');
    expect(buildingSignature(b, bt, roads, 'me', 'no-input')).toContain('|qno-input');
  });

  it('changes when issue state flips, even if base fields are identical', () => {
    const b = {
      building_type_key: 'mill', x: 0, y: 0, status: 'active',
      is_staffed: true, paused: false, player_id: 'me'
    };
    const bt = { category: 'processor' };
    const healthy = buildingSignature(b, bt, roads, 'me', null);
    const broken  = buildingSignature(b, bt, roads, 'me', 'no-input');
    expect(healthy).not.toBe(broken);
  });

  it('changes when is_staffed flips', () => {
    const b = { building_type_key: 'mill', x: 0, y: 0, status: 'active', is_staffed: true, player_id: 'me' };
    const bt = { category: 'processor' };
    const a = buildingSignature(b, bt, roads, 'me');
    const c = buildingSignature({ ...b, is_staffed: false }, bt, roads, 'me');
    expect(a).not.toBe(c);
  });

  it('appends NSEW mask for roads, varying with neighbors', () => {
    const b = { building_type_key: 'road', x: 5, y: 5, status: 'active', player_id: 'me' };
    const bt = { category: 'road' };
    const alone = buildingSignature(b, bt, new Set(), 'me');
    expect(alone).toContain('|r0000');

    const withNorth = buildingSignature(b, bt, new Set(['5,4']), 'me');
    expect(withNorth).toContain('|r1000');

    const withAll = buildingSignature(b, bt, new Set(['5,4','5,6','6,5','4,5']), 'me');
    expect(withAll).toContain('|r1111');
  });

  it('marks ownership with me vs them', () => {
    const b = { building_type_key: 'house', x: 0, y: 0, status: 'active', player_id: 'someone-else' };
    const bt = { category: 'housing' };
    expect(buildingSignature(b, bt, roads, 'me')).toContain('|othem');
  });
});

describe('resourceKindFor', () => {
  it('maps timber/forest/orchard/grove → wood', () => {
    expect(resourceKindFor('timber_grove', null)).toBe('wood');
    expect(resourceKindFor('forest', null)).toBe('wood');
    expect(resourceKindFor('orchard_grove', null)).toBe('wood');
  });
  it('maps stone keys → stone', () => {
    expect(resourceKindFor('stone_outcrop', null)).toBe('stone');
    expect(resourceKindFor('rocky_quarry', null)).toBe('stone');
  });
  it('maps iron/ore/metal → metal', () => {
    expect(resourceKindFor('iron_deposit', null)).toBe('metal');
    expect(resourceKindFor('ore_seam', null)).toBe('metal');
  });
  it('maps water words → fish', () => {
    expect(resourceKindFor('pond', null)).toBe('fish');
    expect(resourceKindFor('river', null)).toBe('fish');
    expect(resourceKindFor('fish_school', null)).toBe('fish');
  });
  it('maps grain/farmland/garden → food', () => {
    expect(resourceKindFor('grain_field', null)).toBe('food');
    expect(resourceKindFor('garden_plot', null)).toBe('food');
    expect(resourceKindFor('farmland', null)).toBe('food');
  });
  it('falls back to industry_key when keys don\'t match', () => {
    expect(resourceKindFor('mystery', { industry_key: 'timber' })).toBe('wood');
    expect(resourceKindFor('mystery', { industry_key: 'iron' })).toBe('metal');
  });
  it('returns default for nothing-matches', () => {
    expect(resourceKindFor('totally-unknown', { industry_key: 'common' })).toBe('default');
    expect(resourceKindFor(null, null)).toBe('default');
  });
});

describe('pickWalkerVariant', () => {
  it('returns a citizen-family persona for housing', () => {
    const b = { building_type_key: 'house' };
    const bt = { category: 'housing' };
    const personas = new Set(['citizen', 'child', 'elder', 'fat', 'couple']);
    for (let i = 0; i < 20; i++) {
      expect(personas.has(pickWalkerVariant(b, bt))).toBe(true);
    }
  });
  it('maps timber_camp → timber', () => {
    expect(pickWalkerVariant({ building_type_key: 'timber_camp' }, { category: 'extractor' })).toBe('timber');
  });
  it('maps iron_mine → iron', () => {
    expect(pickWalkerVariant({ building_type_key: 'iron_mine' }, { category: 'extractor' })).toBe('iron');
  });
  it('maps temple → temple', () => {
    expect(pickWalkerVariant({ building_type_key: 'temple' }, { category: 'service' })).toBe('temple');
  });
  it('maps unknown processor → citizen', () => {
    expect(pickWalkerVariant({ building_type_key: 'cabinetmaker' }, { category: 'processor' })).toBe('citizen');
  });
});

describe('getBuildingAoeRange', () => {
  it('returns null for non-AoE building types', () => {
    expect(getBuildingAoeRange({}, { category: 'housing' })).toBeNull();
    expect(getBuildingAoeRange({}, { category: 'road' })).toBeNull();
    expect(getBuildingAoeRange({}, null)).toBeNull();
  });
  it('returns coverage for police', () => {
    expect(getBuildingAoeRange({}, { category: 'police', coverage_radius: 4 })).toEqual({ range: 4, kind: 'police' });
  });
  it('returns pollution_radius for park (dampener)', () => {
    expect(getBuildingAoeRange({}, { category: 'park', pollution_radius: 3 })).toEqual({ range: 3, kind: 'park' });
  });
  it('returns boost_range for booster', () => {
    expect(getBuildingAoeRange({}, { category: 'booster', boost_range: 2 })).toEqual({ range: 2, kind: 'booster' });
  });
  it('hard-coded service ranges match v1 server-side gates', () => {
    expect(getBuildingAoeRange({}, { category: 'service', key: 'well' })).toEqual({ range: 4, kind: 'well' });
    expect(getBuildingAoeRange({}, { category: 'service', key: 'school' })).toEqual({ range: 5, kind: 'school' });
    expect(getBuildingAoeRange({}, { category: 'service', key: 'temple' })).toEqual({ range: 6, kind: 'temple' });
    expect(getBuildingAoeRange({}, { category: 'service', key: 'bathhouse' })).toEqual({ range: 4, kind: 'bathhouse' });
  });
});

describe('heatmapTintFor', () => {
  it('pollution: 0 → no overlay', () => {
    expect(heatmapTintFor('pollution', 0)).toEqual({ tint: 0, alpha: 0 });
  });
  it('pollution: heavy value → strong red overlay', () => {
    const r = heatmapTintFor('pollution', 60);
    expect(r.alpha).toBeGreaterThan(0.5);
    expect(r.tint).toBe(0xe85a3a);
  });
  it('desirability: low → red, high → green, middle → nothing', () => {
    expect(heatmapTintFor('desirability', 50)).toEqual({ tint: 0, alpha: 0 });
    expect(heatmapTintFor('desirability', 10).tint).toBe(0xc83a3a);
    expect(heatmapTintFor('desirability', 90).tint).toBe(0x3ac860);
  });
  it('crime: 0 → none, 100 → magenta', () => {
    expect(heatmapTintFor('crime', 0).alpha).toBe(0);
    expect(heatmapTintFor('crime', 100).tint).toBe(0xc84878);
  });
  it('issues: binary on/off at the 50 threshold', () => {
    expect(heatmapTintFor('issues', 0).alpha).toBe(0);
    expect(heatmapTintFor('issues', 100).tint).toBe(0xf0a838);
  });
  it('unknown mode → no overlay', () => {
    expect(heatmapTintFor('zzz', 999)).toEqual({ tint: 0, alpha: 0 });
  });
});

describe('computeWorldBounds', () => {
  it('returns 0×0 for empty inputs', () => {
    expect(computeWorldBounds({}, [])).toEqual({ minX: 0, minY: 0, cols: 0, rows: 0 });
  });
  it('wraps a single tile', () => {
    expect(computeWorldBounds({ '5,5': { x: 5, y: 5 } }, [])).toEqual({ minX: 5, minY: 5, cols: 1, rows: 1 });
  });
  it('unions tiles and buildings', () => {
    const tileMap = { '0,0': { x: 0, y: 0 } };
    const buildings = [{ x: 10, y: 4 }];
    expect(computeWorldBounds(tileMap, buildings)).toEqual({ minX: 0, minY: 0, cols: 11, rows: 5 });
  });
  it('handles negative coordinates', () => {
    const tileMap = { '-3,-2': { x: -3, y: -2 } };
    const buildings = [{ x: 1, y: 4 }];
    expect(computeWorldBounds(tileMap, buildings)).toEqual({ minX: -3, minY: -2, cols: 5, rows: 7 });
  });
});

describe('sizeWalkerSvg', () => {
  it('injects width/height = 4× viewBox dimensions', () => {
    const input = "data:image/svg+xml,<svg xmlns='http://w3.org' viewBox='0 0 10 14'><circle/></svg>";
    const out = sizeWalkerSvg(input);
    expect(out).toContain("width='40'");
    expect(out).toContain("height='56'");
  });
  it('leaves the URI unchanged if no viewBox', () => {
    const input = "data:image/svg+xml,<svg><circle/></svg>";
    expect(sizeWalkerSvg(input)).toBe(input);
  });
  it('preserves the original viewBox attribute', () => {
    const input = "data:image/svg+xml,<svg xmlns='x' viewBox='0 0 8 11'><c/></svg>";
    const out = sizeWalkerSvg(input);
    expect(out).toContain("viewBox='0 0 8 11'");
  });
  it('accepts double-quoted viewBox too', () => {
    const input = 'data:image/svg+xml,<svg xmlns="x" viewBox="0 0 12 12"><c/></svg>';
    const out = sizeWalkerSvg(input);
    expect(out).toContain("width='48'");
    expect(out).toContain("height='48'");
  });
});

describe('tutorialAllowsBuilding', () => {
  // Curated set of building types covering every category the
  // gating logic distinguishes.
  const bts = {
    house: { category: 'housing', key: 'house' },
    road:  { category: 'road',    key: 'road' },
    well:  { category: 'service', key: 'well' },
    school:{ category: 'service', key: 'school' },
    farm:  { category: 'food_extractor', key: 'grain_farm' },
    iron:  { category: 'extractor', key: 'iron_mine' },
    kiln:  { category: 'processor', key: 'pottery_kiln' }
  };

  it('step 4+ unlocks everything', () => {
    for (const key in bts) {
      expect(tutorialAllowsBuilding(bts[key], 4)).toBe(true);
      expect(tutorialAllowsBuilding(bts[key], 99)).toBe(true);
    }
  });
  it('undefined step defaults to unlocked', () => {
    expect(tutorialAllowsBuilding(bts.kiln, undefined)).toBe(true);
  });
  it('step 0 only allows housing + road', () => {
    expect(tutorialAllowsBuilding(bts.house, 0)).toBe(true);
    expect(tutorialAllowsBuilding(bts.road,  0)).toBe(true);
    expect(tutorialAllowsBuilding(bts.well,  0)).toBe(false);
    expect(tutorialAllowsBuilding(bts.farm,  0)).toBe(false);
  });
  it('step 1 adds well only (not other services)', () => {
    expect(tutorialAllowsBuilding(bts.well,   1)).toBe(true);
    expect(tutorialAllowsBuilding(bts.school, 1)).toBe(false);
    expect(tutorialAllowsBuilding(bts.farm,   1)).toBe(false);
  });
  it('step 2 adds food extractors', () => {
    expect(tutorialAllowsBuilding(bts.farm, 2)).toBe(true);
    expect(tutorialAllowsBuilding(bts.iron, 2)).toBe(false);
  });
  it('step 3 adds extractors but still not processors', () => {
    expect(tutorialAllowsBuilding(bts.iron, 3)).toBe(true);
    expect(tutorialAllowsBuilding(bts.kiln, 3)).toBe(false);
  });
});

describe('computePoliceCoverage', () => {
  const buildingTypes = {
    watch_house: { category: 'police', coverage_radius: 2, footprint_w: 1, footprint_h: 1 },
    house: { category: 'housing', footprint_w: 1, footprint_h: 1 }
  };

  it('returns empty set with no police', () => {
    expect(computePoliceCoverage([], buildingTypes, 'me').size).toBe(0);
  });
  it('includes anchor + manhattan disk around a 1x1 r2 police', () => {
    const buildings = [
      { player_id: 'me', status: 'active', is_staffed: true,
        building_type_key: 'watch_house', x: 5, y: 5 }
    ];
    const covered = computePoliceCoverage(buildings, buildingTypes, 'me');
    expect(covered.has('5,5')).toBe(true);     // anchor
    expect(covered.has('5,7')).toBe(true);     // r=2 south
    expect(covered.has('7,5')).toBe(true);     // r=2 east
    expect(covered.has('6,6')).toBe(true);     // diagonal sum=2
    expect(covered.has('7,7')).toBe(false);    // diagonal sum=4
    expect(covered.has('5,8')).toBe(false);    // r=3 south
  });
  it('excludes unstaffed / idle / wrong-owner police', () => {
    const buildings = [
      { player_id: 'someone-else', status: 'active', is_staffed: true,
        building_type_key: 'watch_house', x: 5, y: 5 },
      { player_id: 'me', status: 'idle', is_staffed: true,
        building_type_key: 'watch_house', x: 10, y: 10 },
      { player_id: 'me', status: 'active', is_staffed: false,
        building_type_key: 'watch_house', x: 20, y: 20 }
    ];
    expect(computePoliceCoverage(buildings, buildingTypes, 'me').size).toBe(0);
  });
});

describe('computeProblemTiles', () => {
  const buildingTypes = {
    house: { category: 'housing', worker_cost: 0, footprint_w: 1, footprint_h: 1 },
    mill: { category: 'processor', worker_cost: 10, footprint_w: 1, footprint_h: 1 },
    smelter: { category: 'processor', worker_cost: 10, footprint_w: 2, footprint_h: 1 }
  };

  it('flags idle buildings', () => {
    const buildings = [
      { player_id: 'me', status: 'idle', is_staffed: true,
        building_type_key: 'mill', x: 1, y: 1 }
    ];
    const tiles = computeProblemTiles(buildings, buildingTypes, 'me');
    expect(tiles.has('1,1')).toBe(true);
  });
  it('flags unstaffed worker buildings', () => {
    const buildings = [
      { player_id: 'me', status: 'active', is_staffed: false,
        building_type_key: 'mill', x: 2, y: 2 }
    ];
    expect(computeProblemTiles(buildings, buildingTypes, 'me').has('2,2')).toBe(true);
  });
  it('does NOT flag worker-less housing for staffing', () => {
    const buildings = [
      { player_id: 'me', status: 'active', is_staffed: false,
        building_type_key: 'house', x: 3, y: 3 }
    ];
    expect(computeProblemTiles(buildings, buildingTypes, 'me').size).toBe(0);
  });
  it('flags paused buildings', () => {
    const buildings = [
      { player_id: 'me', status: 'active', is_staffed: true, paused: true,
        building_type_key: 'mill', x: 4, y: 4 }
    ];
    expect(computeProblemTiles(buildings, buildingTypes, 'me').has('4,4')).toBe(true);
  });
  it('covers every footprint tile of a multi-tile building', () => {
    const buildings = [
      { player_id: 'me', status: 'idle', is_staffed: true,
        building_type_key: 'smelter', x: 5, y: 5 }
    ];
    const tiles = computeProblemTiles(buildings, buildingTypes, 'me');
    expect(tiles.has('5,5')).toBe(true);
    expect(tiles.has('6,5')).toBe(true);   // fw=2
    expect(tiles.size).toBe(2);
  });
  it('ignores other players', () => {
    const buildings = [
      { player_id: 'someone-else', status: 'idle', is_staffed: true,
        building_type_key: 'mill', x: 1, y: 1 }
    ];
    expect(computeProblemTiles(buildings, buildingTypes, 'me').size).toBe(0);
  });
});

describe('computeResourceProdCons', () => {
  const bts = {
    timber_camp: { category: 'extractor', output_resource_key: 'timber', output_rate: 2 },
    sawmill:     { category: 'processor', input_resource_key: 'timber', input_rate: 2, output_resource_key: 'lumber', output_rate: 1 },
    cabinetmaker:{ category: 'processor', input_resource_key: 'lumber', input_rate: 1,
                   input_resource_key_2: 'lime', input_rate_2: 0.5,
                   output_resource_key: 'furniture', output_rate: 0.25 },
    tax_office:  { category: 'tax', output_resource_key: 'money', output_rate: 50 }
  };

  it('sums output across staffed-active producers', () => {
    const buildings = [
      { player_id: 'me', status: 'active', is_staffed: true,
        building_type_key: 'timber_camp' },
      { player_id: 'me', status: 'active', is_staffed: true,
        building_type_key: 'timber_camp' }
    ];
    const { prod, cons } = computeResourceProdCons(buildings, bts, 'me');
    expect(prod.timber).toBe(4);
    expect(cons).toEqual({});
  });

  it('sums input across processors, including dual-input recipes', () => {
    const buildings = [
      { player_id: 'me', status: 'active', is_staffed: true,
        building_type_key: 'cabinetmaker' }
    ];
    const { prod, cons } = computeResourceProdCons(buildings, bts, 'me');
    expect(cons.lumber).toBe(1);
    expect(cons.lime).toBe(0.5);
    expect(prod.furniture).toBe(0.25);
  });

  it('skips unstaffed / idle / paused / wrong-owner buildings', () => {
    const buildings = [
      { player_id: 'me', status: 'active', is_staffed: false,
        building_type_key: 'timber_camp' },
      { player_id: 'me', status: 'idle', is_staffed: true,
        building_type_key: 'timber_camp' },
      { player_id: 'me', status: 'active', is_staffed: true, paused: true,
        building_type_key: 'timber_camp' },
      { player_id: 'someone-else', status: 'active', is_staffed: true,
        building_type_key: 'timber_camp' }
    ];
    const { prod } = computeResourceProdCons(buildings, bts, 'me');
    expect(prod).toEqual({});
  });

  it('excludes tax revenue from prod (handled by runway calc)', () => {
    const buildings = [
      { player_id: 'me', status: 'active', is_staffed: true,
        building_type_key: 'tax_office' }
    ];
    const { prod } = computeResourceProdCons(buildings, bts, 'me');
    expect(prod.money).toBeUndefined();
  });
});

describe('computeBuildingIssue', () => {
  const myId = 'me';
  const inventory = { timber: 50, lumber: 0 };

  const healthyMill = {
    building_type_key: 'sawmill', x: 5, y: 5, status: 'active',
    is_staffed: true, paused: false, player_id: myId
  };
  const millType = {
    category: 'processor', worker_cost: 10,
    input_resource_key: 'timber', input_rate: 2,
    footprint_w: 1, footprint_h: 1
  };

  it('returns null for healthy active staffed road-connected fed buildings', () => {
    const roadSet = new Set(['5,4']);   // road north of the mill
    expect(computeBuildingIssue(healthyMill, millType, roadSet, inventory, myId)).toBeNull();
  });

  it('returns null for other players\' buildings even when broken', () => {
    const broken = { ...healthyMill, player_id: 'someone-else', paused: true };
    expect(computeBuildingIssue(broken, millType, new Set(), inventory, myId)).toBeNull();
  });

  it('returns null when bt is missing', () => {
    expect(computeBuildingIssue(healthyMill, null, new Set(), inventory, myId)).toBeNull();
  });

  it('reports paused before any other issue', () => {
    const paused = { ...healthyMill, paused: true, is_staffed: false };
    const issue = computeBuildingIssue(paused, millType, new Set(), inventory, myId);
    expect(issue?.kind).toBe('paused');
  });

  it('reports idle when status is idle', () => {
    const idle = { ...healthyMill, status: 'idle' };
    expect(computeBuildingIssue(idle, millType, new Set(['5,4']), inventory, myId)?.kind).toBe('idle');
  });

  it('reports unstaffed when worker_cost > 0 and not staffed', () => {
    const unstaffed = { ...healthyMill, is_staffed: false };
    expect(computeBuildingIssue(unstaffed, millType, new Set(['5,4']), inventory, myId)?.kind).toBe('unstaffed');
  });

  it('reports no-road for road-dependent categories without adjacency', () => {
    const issue = computeBuildingIssue(healthyMill, millType, new Set(), inventory, myId);
    expect(issue?.kind).toBe('no-road');
  });

  it('walks the multi-tile perimeter, not just the anchor', () => {
    const bigB = { ...healthyMill, x: 5, y: 5 };
    const bigBt = { ...millType, footprint_w: 2, footprint_h: 2 };
    // Road only at (7,6) — beyond the anchor's neighbors but on the right
    // perimeter of the 2x2 building (cell at (6,6) has neighbor (7,6)).
    const issue = computeBuildingIssue(bigB, bigBt, new Set(['7,6']), inventory, myId);
    expect(issue).toBeNull();
  });

  it('reports no-input when staffed processor lacks a primary input', () => {
    const noInput = {
      ...healthyMill, is_staffed: true,
      x: 5, y: 5
    };
    const emptyInv = { timber: 0 };
    const issue = computeBuildingIssue(noInput, millType, new Set(['5,4']), emptyInv, myId);
    expect(issue?.kind).toBe('no-input');
  });

  it('reports no-input for a missing second input on a multi-input processor', () => {
    const dualInputBt = {
      category: 'processor', worker_cost: 10,
      input_resource_key: 'timber', input_rate: 2,
      input_resource_key_2: 'lumber', input_rate_2: 1,
      footprint_w: 1, footprint_h: 1
    };
    // Has timber but no lumber → no-input.
    const issue = computeBuildingIssue(healthyMill, dualInputBt, new Set(['5,4']), inventory, myId);
    expect(issue?.kind).toBe('no-input');
  });

  it('does not flag no-road for extractors / housing tier 0-2 / roads', () => {
    const extractor = { ...healthyMill, building_type_key: 'timber_camp' };
    const extractorBt = { ...millType, category: 'extractor', input_resource_key: null };
    expect(computeBuildingIssue(extractor, extractorBt, new Set(), inventory, myId)).toBeNull();

    const hut = { ...healthyMill, building_type_key: 'mud_hut', housing_tier: 1, is_staffed: true };
    const hutBt = { category: 'housing', worker_cost: 0, footprint_w: 1, footprint_h: 1 };
    expect(computeBuildingIssue(hut, hutBt, new Set(), inventory, myId)).toBeNull();
  });

  it('does flag no-road for housing tier 3 and up (Townhouse+)', () => {
    const townhouse = { ...healthyMill, housing_tier: 3, is_staffed: true };
    const housingBt = { category: 'housing', worker_cost: 0, footprint_w: 1, footprint_h: 1 };
    const issue = computeBuildingIssue(townhouse, housingBt, new Set(), inventory, myId);
    expect(issue?.kind).toBe('no-road');
  });
});

describe('listBuildingIssues', () => {
  const myId = 'me';
  const millBt = {
    category: 'processor', worker_cost: 10,
    input_resource_key: 'timber', input_rate: 2,
    footprint_w: 1, footprint_h: 1
  };
  const baseMill = {
    building_type_key: 'sawmill', x: 5, y: 5, status: 'active',
    is_staffed: true, paused: false, player_id: myId
  };

  it('returns [] when healthy', () => {
    expect(listBuildingIssues(baseMill, millBt, new Set(['5,4']), { timber: 50 }, myId)).toEqual([]);
  });

  it('returns [] for other players\' buildings', () => {
    const them = { ...baseMill, player_id: 'neighbor' };
    expect(listBuildingIssues(them, millBt, new Set(), {}, myId)).toEqual([]);
  });

  it('paused short-circuits — only paused, no road / input piled on', () => {
    const paused = { ...baseMill, paused: true, is_staffed: false };
    const issues = listBuildingIssues(paused, millBt, new Set(), { timber: 0 }, myId);
    expect(issues).toHaveLength(1);
    expect(issues[0].kind).toBe('paused');
    expect(issues[0].hint).toContain('Resume');
  });

  it('idle short-circuits — same exclusivity as paused', () => {
    const idle = { ...baseMill, status: 'idle' };
    const issues = listBuildingIssues(idle, millBt, new Set(), { timber: 0 }, myId);
    expect(issues).toHaveLength(1);
    expect(issues[0].kind).toBe('idle');
  });

  it('unstaffed short-circuits — no road / input reported alongside', () => {
    const unstaffed = { ...baseMill, is_staffed: false };
    const issues = listBuildingIssues(unstaffed, millBt, new Set(), { timber: 0 }, myId);
    expect(issues).toHaveLength(1);
    expect(issues[0].kind).toBe('unstaffed');
    expect(issues[0].hint).toContain('Grow population');
  });

  it('reports no-road AND no-input together when both apply', () => {
    const issues = listBuildingIssues(baseMill, millBt, new Set(), { timber: 0 }, myId);
    expect(issues).toHaveLength(2);
    expect(issues.map((i) => i.kind).sort()).toEqual(['no-input', 'no-road']);
  });

  it('attaches resource_key to no-input issues for inspector formatting', () => {
    const issues = listBuildingIssues(baseMill, millBt, new Set(['5,4']), { timber: 0 }, myId);
    const noInput = issues.find((i) => i.kind === 'no-input');
    expect(noInput?.resource_key).toBe('timber');
  });

  it('reports BOTH inputs as separate issues for a multi-input processor', () => {
    const dualBt = {
      ...millBt,
      input_resource_key_2: 'lumber', input_rate_2: 1
    };
    const issues = listBuildingIssues(baseMill, dualBt, new Set(['5,4']), { timber: 0, lumber: 0 }, myId);
    const inputs = issues.filter((i) => i.kind === 'no-input');
    expect(inputs).toHaveLength(2);
    expect(inputs.map((i) => i.resource_key).sort()).toEqual(['lumber', 'timber']);
  });
});

describe('getHousingUpgradeBlockers', () => {
  const myId = 'me';
  const house = { id: 1, x: 5, y: 5, player_id: myId, housing_tier: 2 };
  const baseCtx = {
    roadSet: new Set(),
    allBuildings: [],
    buildingTypes: {
      well:      { worker_cost: 3 },
      school:    { worker_cost: 10, input_resource_key: 'lumber', input_rate: 1, input_resource_key_2: 'flour', input_rate_2: 1 },
      temple:    { worker_cost: 10, input_resource_key: 'statuary', input_rate: 1, input_resource_key_2: 'brick', input_rate_2: 1 },
      bathhouse: { worker_cost: 5, input_resource_key: 'brick', input_rate: 1, input_resource_key_2: 'clay', input_rate_2: 1 }
    },
    tileMap: { '5,5': { x: 5, y: 5, desirability: 70 } },
    inventory: { grain: 10, lumber: 10, flour: 10, statuary: 1, brick: 1, clay: 1, pottery: 1, spirits: 1, cabinets: 1, monuments: 1, mosaics: 1, machinery: 1 },
    resources: {
      grain: { is_food: true, name: 'Grain' },
      pottery: { name: 'Pottery' },
      spirits: { is_luxury_food: true, name: 'Spirits' },
      cabinets: { is_industrial_luxury: true, name: 'Cabinets' },
      monuments: { is_industrial_luxury: true, name: 'Monuments' },
      mosaics:   { is_industrial_luxury: true, name: 'Mosaics' },
      machinery: { is_industrial_luxury: true, name: 'Machinery' }
    },
    housingLifestyleDemands: { 3: [{ resource_key: 'pottery', qty_per_minute: 0.1 }] }
  };

  it('returns [] when every prereq is met', () => {
    const tier3 = {
      tier: 3, needs_road: true, needs_well: true, needs_food: true,
      needs_school: true, min_desirability: 60
    };
    const ctx = {
      ...baseCtx,
      roadSet: new Set(['5,4']),
      allBuildings: [
        { player_id: myId, building_type_key: 'well', x: 4, y: 4, status: 'active', is_staffed: true },
        { player_id: myId, building_type_key: 'school', x: 6, y: 5, status: 'active', is_staffed: true }
      ]
    };
    expect(getHousingUpgradeBlockers(house, tier3, ctx)).toEqual([]);
  });

  it('reports road missing', () => {
    const tier = { tier: 3, needs_road: true };
    expect(getHousingUpgradeBlockers(house, tier, baseCtx)).toContain('road');
  });

  it('reports food missing when no is_food resource > 0', () => {
    const tier = { tier: 1, needs_food: true };
    const ctx = { ...baseCtx, inventory: { grain: 0 } };
    expect(getHousingUpgradeBlockers(house, tier, ctx)).toContain('food');
  });

  it('reports school missing when school is present but not staffed', () => {
    const tier = { tier: 3, needs_school: true };
    const ctx = {
      ...baseCtx,
      allBuildings: [{ player_id: myId, building_type_key: 'school', x: 5, y: 6, status: 'active', is_staffed: false }]
    };
    expect(getHousingUpgradeBlockers(house, tier, ctx)).toContain('school');
  });

  it('reports school missing when school is staffed but unfed', () => {
    const tier = { tier: 3, needs_school: true };
    const ctx = {
      ...baseCtx,
      inventory: { lumber: 0, flour: 10 },   // school needs lumber + flour; lumber is empty
      allBuildings: [{ player_id: myId, building_type_key: 'school', x: 5, y: 6, status: 'active', is_staffed: true }]
    };
    expect(getHousingUpgradeBlockers(house, tier, ctx)).toContain('school');
  });

  it('reports a separate lifestyle:<resource> blocker per missing tier demand', () => {
    const tier = { tier: 3 };   // demands carries pottery
    const ctx = { ...baseCtx, inventory: { pottery: 0 } };
    expect(getHousingUpgradeBlockers(house, tier, ctx)).toContain('lifestyle:pottery');
  });

  it('reports desirability when tile metric < min', () => {
    const tier = { tier: 4, min_desirability: 80 };
    expect(getHousingUpgradeBlockers(house, tier, baseCtx)).toContain('desirability');
  });

  it('treats missing tile desirability as 50 (server default)', () => {
    const tier = { tier: 4, min_desirability: 60 };
    const ctx = { ...baseCtx, tileMap: { '5,5': { x: 5, y: 5 } } };
    expect(getHousingUpgradeBlockers(house, tier, ctx)).toContain('desirability');
  });

  it('all_industrial_luxuries requires every is_industrial_luxury > 0', () => {
    const tier = { tier: 8, needs_all_industrial_luxuries: true };
    const ctx = { ...baseCtx, inventory: { cabinets: 1, monuments: 1, mosaics: 1, machinery: 0 } };
    expect(getHousingUpgradeBlockers(house, tier, ctx)).toContain('all_industrial_luxuries');
  });
});

describe('getHousingDevolveRisks', () => {
  const myId = 'me';
  const house = { id: 1, x: 5, y: 5, player_id: myId, housing_tier: 3 };
  const baseCtx = {
    roadSet: new Set(['5,4']),
    allBuildings: [],
    buildingTypes: {
      bathhouse: { worker_cost: 5, input_resource_key: 'brick', input_rate: 1, input_resource_key_2: 'clay', input_rate_2: 1 }
    },
    tileMap: { '5,5': { x: 5, y: 5, desirability: 70 } },
    inventory: { brick: 1, clay: 1 },
    resources: {}
  };

  it('returns no risk when nothing is failing', () => {
    const tier = { tier: 3, needs_road: true };
    const r = getHousingDevolveRisks(house, tier, baseCtx);
    expect(r.willDevolve).toBe(false);
    expect(r.blockers).toEqual([]);
  });

  it('willDevolve=true when blockers exist and no bathhouse', () => {
    const tier = { tier: 3, needs_road: true };
    const ctx = { ...baseCtx, roadSet: new Set() };
    const r = getHousingDevolveRisks(house, tier, ctx);
    expect(r.willDevolve).toBe(true);
    expect(r.blockers).toContain('road');
    expect(r.hasBathhouseCover).toBe(false);
  });

  it('hasBathhouseCover=true suppresses devolve even with blockers', () => {
    const tier = { tier: 3, needs_road: true };
    const ctx = {
      ...baseCtx,
      roadSet: new Set(),
      allBuildings: [{ player_id: myId, building_type_key: 'bathhouse', x: 6, y: 5, status: 'active', is_staffed: true }]
    };
    const r = getHousingDevolveRisks(house, tier, ctx);
    expect(r.blockers).toContain('road');
    expect(r.hasBathhouseCover).toBe(true);
    expect(r.willDevolve).toBe(false);
  });
});

describe('describeHousingBlocker / describeHousingDevolveReason', () => {
  const resources = { pottery: { name: 'Pottery' } };

  it('returns forward-tense for upgrade blockers', () => {
    expect(describeHousingBlocker('road', resources)).toContain('road');
    expect(describeHousingBlocker('lifestyle:pottery', resources)).toContain('Pottery');
  });

  it('returns past-tense for devolve reasons', () => {
    expect(describeHousingDevolveReason('food', resources)).toContain('ran out');
    expect(describeHousingDevolveReason('lifestyle:pottery', resources)).toContain('Pottery');
  });

  it('falls back to the raw key if unknown', () => {
    expect(describeHousingBlocker('mystery', resources)).toBe('mystery');
  });
});

