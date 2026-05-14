import { describe, it, expect } from 'vitest';
import {
  buildingSignature,
  resourceKindFor,
  pickWalkerVariant,
  getBuildingAoeRange,
  heatmapTintFor,
  computeWorldBounds,
  sizeWalkerSvg,
  sizeSvgDataUri,
  tutorialAllowsBuilding,
  computePoliceCoverage,
  computeProblemTiles,
  computeResourceProdCons,
  computeBuildingIssue,
  listBuildingIssues,
  tileHash,
  getHousingUpgradeBlockers,
  getHousingDevolveRisks,
  describeHousingBlocker,
  describeHousingDevolveReason,
  computeResourceFlow
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
  it('maps timber/forest → wood; orchard/grove → distinct orchard kind', () => {
    expect(resourceKindFor('timber', null)).toBe('wood');
    expect(resourceKindFor('timber_grove', null)).toBe('orchard');   // grove wins
    expect(resourceKindFor('forest', null)).toBe('wood');
    expect(resourceKindFor('orchard_grove', null)).toBe('orchard');
    expect(resourceKindFor('orchard', null)).toBe('orchard');
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
  it('splits food tiles by type: grain/farmland → grain, garden/plot → vegetables', () => {
    expect(resourceKindFor('grain_field', null)).toBe('grain');
    expect(resourceKindFor('farmland', null)).toBe('grain');
    expect(resourceKindFor('garden_plot', null)).toBe('vegetables');
    expect(resourceKindFor('garden', null)).toBe('vegetables');
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
  it('injects size into URL-encoded SVGs (%3Csvg form)', () => {
    // walker_sprites.js has 9 entries using percent-encoded <svg>;
    // before the fix, the size regex silently no-op'd on them and
    // the browser rasterized them at the default ~300px surface.
    const input = "data:image/svg+xml,%3Csvg xmlns='http://w3.org' viewBox='0 0 10 14'%3E%3Ccircle/%3E%3C/svg%3E";
    const out = sizeWalkerSvg(input);
    expect(out).toContain("width='40'");
    expect(out).toContain("height='56'");
    // The opening tag stays percent-encoded — we only insert the
    // attribute, we don't decode the whole URI.
    expect(out).toContain('%3Csvg');
  });
});

describe('sizeSvgDataUri', () => {
  it('uses the passed scale (buildings at 2× for 64×64 viewBox)', () => {
    // spriteIcons entries are viewBox-only at 0 0 64 64; without
    // sizing they rasterized at the browser's default 300×150
    // surface and tipped mobile texture memory over budget.
    const input = "data:image/svg+xml,%3Csvg viewBox='0 0 64 64'%3E%3C/svg%3E";
    const out = sizeSvgDataUri(input, 2);
    expect(out).toContain("width='128'");
    expect(out).toContain("height='128'");
  });
  it('passes invalid viewBox through unchanged', () => {
    const input = 'data:image/svg+xml,<svg>...</svg>';
    expect(sizeSvgDataUri(input, 2)).toBe(input);
  });
  // Three encoding variants of the same viewBox string. Real
  // sprites.js mixes all of them — earlier shipped code only
  // matched form (a), so 47 of 57 buildings silently failed
  // size-injection and rendered as black squares on mobile.
  it('handles viewBox with URL-encoded spaces (%20)', () => {
    // (b) literal single-quote, encoded space — common in spriteIcons
    const input = "data:image/svg+xml,%3Csvg viewBox='0%200%2064%2064'%3E%3C/svg%3E";
    const out = sizeSvgDataUri(input, 2);
    expect(out).toContain("width='128'");
    expect(out).toContain("height='128'");
  });
  it('handles viewBox with %22 quotes + %20 spaces (grain_farm/mill form)', () => {
    // (c) fully URL-encoded — quotes and spaces both encoded
    const input = 'data:image/svg+xml,%3Csvg%20xmlns=%22http://x%22%20viewBox=%220%200%2064%2064%22%3E%3C/svg%3E';
    const out = sizeSvgDataUri(input, 2);
    expect(out).toContain("width='128'");
    expect(out).toContain("height='128'");
  });
  it('handles literal <svg followed by %20 (transport hub form)', () => {
    // airport/seaport/train_depot/truck_depot all use this:
    // literal angle bracket, encoded space separator.
    const input = "data:image/svg+xml,<svg%20xmlns='http://x'%20viewBox='0 0 64 64'><c/></svg>";
    const out = sizeSvgDataUri(input, 2);
    expect(out).toContain("width='128'");
    expect(out).toContain("height='128'");
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
  it('excludes unstaffed / paused / wrong-owner police', () => {
    const buildings = [
      { player_id: 'someone-else', status: 'active', is_staffed: true,
        building_type_key: 'watch_house', x: 5, y: 5 },
      { player_id: 'me', status: 'paused', is_staffed: true,
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
      { player_id: 'me', status: 'paused', is_staffed: true,
        building_type_key: 'mill', x: 4, y: 4 }
    ];
    expect(computeProblemTiles(buildings, buildingTypes, 'me').has('4,4')).toBe(true);
  });
  it('covers every footprint tile of a multi-tile building', () => {
    const buildings = [
      { player_id: 'me', status: 'paused', is_staffed: true,
        building_type_key: 'smelter', x: 5, y: 5 }
    ];
    const tiles = computeProblemTiles(buildings, buildingTypes, 'me');
    expect(tiles.has('5,5')).toBe(true);
    expect(tiles.has('6,5')).toBe(true);   // fw=2
    expect(tiles.size).toBe(2);
  });
  it('ignores other players', () => {
    const buildings = [
      { player_id: 'someone-else', status: 'paused', is_staffed: true,
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
    grain_farm:  { category: 'food_extractor', output_resource_key: 'grain', output_rate: 0.5 },
    forester:    { category: 'booster', boost_target: 'extractor', boost_multiplier: 1.25, boost_range: 2 },
    apiary:      { category: 'booster', boost_target: 'food_extractor', boost_multiplier: 1.25, boost_range: 2 },
    tax_office:  { category: 'tax', output_resource_key: 'money', output_rate: 50 }
  };

  // Extractors need a claimed target (path_length > 0) to produce — the
  // server skips path_length=NULL ones. Tests pass path_length: 4 to
  // hit the canonical "full rate" path-factor of 1.0.
  it('sums output across staffed-active extractors at canonical path', () => {
    const buildings = [
      { player_id: 'me', status: 'active', is_staffed: true,
        building_type_key: 'timber_camp', x: 0, y: 0, path_length: 4 },
      { player_id: 'me', status: 'active', is_staffed: true,
        building_type_key: 'timber_camp', x: 5, y: 0, path_length: 4 }
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

  it('skips unstaffed / paused / wrong-owner buildings', () => {
    const buildings = [
      { player_id: 'me', status: 'active', is_staffed: false,
        building_type_key: 'timber_camp', x: 0, y: 0, path_length: 4 },
      { player_id: 'me', status: 'paused', is_staffed: true,
        building_type_key: 'timber_camp', x: 1, y: 0, path_length: 4 },
      { player_id: 'someone-else', status: 'active', is_staffed: true,
        building_type_key: 'timber_camp', x: 2, y: 0, path_length: 4 }
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

  // ── Effective-rate scaling ─────────────────────────────────────
  // These are the regression tests for the bug Jill filed (clay UI
  // shown as +9/min net but actual stockpile flat at 0): the city-wide
  // net rate must apply path_length scaling, booster proximity, and
  // productivity — same as the server's per-tick math.

  it('extractor with no claimed target (path_length null) produces 0', () => {
    const buildings = [
      { player_id: 'me', status: 'active', is_staffed: true,
        building_type_key: 'timber_camp', x: 0, y: 0 }
    ];
    const { prod } = computeResourceProdCons(buildings, bts, 'me');
    expect(prod.timber).toBeUndefined();
  });

  it('extractor production scales by min(1, 4/path_length)', () => {
    const buildings = [
      // path_length 8 → factor 0.5 → 2 × 0.5 = 1.0 timber/min
      { player_id: 'me', status: 'active', is_staffed: true,
        building_type_key: 'timber_camp', x: 0, y: 0, path_length: 8 }
    ];
    const { prod } = computeResourceProdCons(buildings, bts, 'me');
    expect(prod.timber).toBeCloseTo(1.0, 5);
  });

  it('booster within Manhattan range applies MAX multiplier (no stack)', () => {
    const buildings = [
      // Two boosters next to one extractor — should pick MAX, not sum.
      { player_id: 'me', status: 'active', is_staffed: true,
        building_type_key: 'forester', x: 1, y: 0 },
      { player_id: 'me', status: 'active', is_staffed: true,
        building_type_key: 'forester', x: 0, y: 1 },
      { player_id: 'me', status: 'active', is_staffed: true,
        building_type_key: 'timber_camp', x: 0, y: 0, path_length: 4 }
    ];
    const { prod } = computeResourceProdCons(buildings, bts, 'me');
    // 2 (output_rate) × 1.0 (path) × 1.25 (boost) = 2.5
    expect(prod.timber).toBeCloseTo(2.5, 5);
  });

  it('out-of-range booster has no effect', () => {
    const buildings = [
      // Booster at Manhattan 3 from the extractor — outside range 2.
      { player_id: 'me', status: 'active', is_staffed: true,
        building_type_key: 'forester', x: 0, y: 3 },
      { player_id: 'me', status: 'active', is_staffed: true,
        building_type_key: 'timber_camp', x: 0, y: 0, path_length: 4 }
    ];
    const { prod } = computeResourceProdCons(buildings, bts, 'me');
    expect(prod.timber).toBe(2);
  });

  it('unstaffed booster has no effect', () => {
    const buildings = [
      { player_id: 'me', status: 'active', is_staffed: false,
        building_type_key: 'forester', x: 1, y: 0 },
      { player_id: 'me', status: 'active', is_staffed: true,
        building_type_key: 'timber_camp', x: 0, y: 0, path_length: 4 }
    ];
    const { prod } = computeResourceProdCons(buildings, bts, 'me');
    expect(prod.timber).toBe(2);
  });

  it('booster only boosts matching boost_target', () => {
    const buildings = [
      // Apiary boosts food_extractor only — NOT the timber extractor.
      { player_id: 'me', status: 'active', is_staffed: true,
        building_type_key: 'apiary', x: 1, y: 0 },
      { player_id: 'me', status: 'active', is_staffed: true,
        building_type_key: 'timber_camp', x: 0, y: 0, path_length: 4 }
    ];
    const { prod } = computeResourceProdCons(buildings, bts, 'me');
    expect(prod.timber).toBe(2);
  });

  it('food_extractor is boosted but never path-scaled', () => {
    const buildings = [
      { player_id: 'me', status: 'active', is_staffed: true,
        building_type_key: 'apiary', x: 1, y: 0 },
      { player_id: 'me', status: 'active', is_staffed: true,
        building_type_key: 'grain_farm', x: 0, y: 0 }
    ];
    const { prod } = computeResourceProdCons(buildings, bts, 'me');
    // 0.5 × 1.25 boost = 0.625
    expect(prod.grain).toBeCloseTo(0.625, 5);
  });

  it('productivity multiplier scales both production and consumption', () => {
    const buildings = [
      { player_id: 'me', status: 'active', is_staffed: true,
        building_type_key: 'timber_camp', x: 0, y: 0, path_length: 4 },
      { player_id: 'me', status: 'active', is_staffed: true,
        building_type_key: 'sawmill' }
    ];
    const profile = { productivity: 1.15 };
    const { prod, cons } = computeResourceProdCons(buildings, bts, 'me', profile);
    expect(prod.timber).toBeCloseTo(2.30, 5);   // 2 × 1.15
    expect(cons.timber).toBeCloseTo(2.30, 5);   // 2 × 1.15
    expect(prod.lumber).toBeCloseTo(1.15, 5);   // 1 × 1.15
  });

  it('reproduces Jill\'s clay deficit: 20 pits × scaled + boost vs 12 kilns', () => {
    // Mirror her actual layout: 20 clay_pits with assorted path_lengths,
    // 4 clay_master_huts, 12 pottery_kilns, productivity 1.15.
    // Server-correct math: production ~17.8/min, consumption 20.7/min,
    // so the UI must show net negative — not +9 like the old buggy calc.
    const clayBts = {
      clay_pit: { category: 'extractor', output_resource_key: 'clay', output_rate: 1.5 },
      clay_master_hut: { category: 'booster', boost_target: 'extractor', boost_multiplier: 1.25, boost_range: 2 },
      pottery_kiln: { category: 'processor', input_resource_key: 'clay', input_rate: 1.5, output_resource_key: 'pottery', output_rate: 0.75 }
    };
    // Place 4 huts and 20 pits with the actual mix of path_lengths
    // observed on Jill's map (3,3,4,5,6,8,9,13,13,15,17,18,20,21,22,32,32,37 + 1 null).
    const pits = [
      { x: 0, y: 0, pl: 3 }, { x: 0, y: 1, pl: 3 }, { x: 0, y: 2, pl: 4 },
      { x: 0, y: 3, pl: 5 }, { x: 0, y: 4, pl: 6 }, { x: 0, y: 5, pl: 8 },
      { x: 0, y: 6, pl: 9 }, { x: 0, y: 7, pl: 13 }, { x: 0, y: 8, pl: 13 },
      { x: 0, y: 9, pl: 15 }, { x: 0, y: 10, pl: 17 }, { x: 0, y: 11, pl: 18 },
      { x: 0, y: 12, pl: 20 }, { x: 0, y: 13, pl: 21 }, { x: 0, y: 14, pl: 22 },
      { x: 0, y: 15, pl: 32 }, { x: 0, y: 16, pl: 32 }, { x: 0, y: 17, pl: 37 },
      { x: 0, y: 18, pl: null }, { x: 0, y: 19, pl: 4 }
    ].map((p, i) => ({
      player_id: 'me', status: 'active', is_staffed: true,
      building_type_key: 'clay_pit', x: p.x, y: p.y, path_length: p.pl
    }));
    const huts = [
      // Place each hut adjacent to a few pits so SOME get boosted.
      { x: 1, y: 1 }, { x: 1, y: 4 }, { x: 1, y: 9 }, { x: 1, y: 14 }
    ].map((h) => ({
      player_id: 'me', status: 'active', is_staffed: true,
      building_type_key: 'clay_master_hut', x: h.x, y: h.y
    }));
    const kilns = [];
    for (let i = 0; i < 12; i++) {
      kilns.push({
        player_id: 'me', status: 'active', is_staffed: true,
        building_type_key: 'pottery_kiln', x: 50 + i, y: 0
      });
    }
    const profile = { productivity: 1.15 };
    const { prod, cons } = computeResourceProdCons(
      [...pits, ...huts, ...kilns], clayBts, 'me', profile
    );
    // Consumption: 12 × 1.5 × 1.15 = 20.7
    expect(cons.clay).toBeCloseTo(20.7, 1);
    // Production should be well under 20 — the net must be negative.
    expect(prod.clay).toBeLessThan(20.7);
    expect(prod.clay - cons.clay).toBeLessThan(0);
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
    // Schema: status IN ('active','paused') — no separate boolean.
    const paused = { ...healthyMill, status: 'paused', is_staffed: false };
    const issue = computeBuildingIssue(paused, millType, new Set(), inventory, myId);
    expect(issue?.kind).toBe('paused');
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
    is_staffed: true, player_id: myId
  };

  it('returns [] when healthy', () => {
    expect(listBuildingIssues(baseMill, millBt, new Set(['5,4']), { timber: 50 }, myId)).toEqual([]);
  });

  it('returns [] for other players\' buildings', () => {
    const them = { ...baseMill, player_id: 'neighbor' };
    expect(listBuildingIssues(them, millBt, new Set(), {}, myId)).toEqual([]);
  });

  it('paused short-circuits — only paused, no road / input piled on', () => {
    // Schema: status IN ('active','paused'). No separate boolean.
    const paused = { ...baseMill, status: 'paused', is_staffed: false };
    const issues = listBuildingIssues(paused, millBt, new Set(), { timber: 0 }, myId);
    expect(issues).toHaveLength(1);
    expect(issues[0].kind).toBe('paused');
    expect(issues[0].hint).toContain('Resume');
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

  it('with pantry: clears food/lifestyle global blockers when buffer has stock', () => {
    // City stock empty but pantry full → no food / lifestyle blocker.
    const tier = { tier: 2, needs_food: true };
    const ctx = {
      ...baseCtx,
      inventory: { grain: 0, brick: 1, clay: 1 },   // grain empty in city
      resources: { grain: { is_food: true, name: 'Grain' } },
      buildingBuffers: { 1: { food: { quantity: 5, capacity: 30 } } }
    };
    const r = getHousingDevolveRisks(house, tier, ctx);
    expect(r.blockers).not.toContain('food');
  });

  it('with pantry: adds lifestyle:<rk> blocker when pantry empty even if city stock has it', () => {
    const tier = { tier: 3 };
    const ctx = {
      ...baseCtx,
      inventory: { pottery: 9999 },
      resources: { pottery: { name: 'Pottery' } },
      housingLifestyleDemands: { 3: [{ resource_key: 'pottery', qty_per_minute: 0.1 }] },
      buildingBuffers: { 1: { pottery: { quantity: 0, capacity: 30 } } }
    };
    const r = getHousingDevolveRisks(house, tier, ctx);
    expect(r.blockers).toContain('lifestyle:pottery');
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

describe('computeResourceFlow', () => {
  const myId = 'me';
  const ctx = {
    allBuildings: [
      // Two staffed sawmills producing lumber from timber.
      { id: 1, player_id: myId, status: 'active', is_staffed: true, building_type_key: 'sawmill' },
      { id: 2, player_id: myId, status: 'active', is_staffed: true, building_type_key: 'sawmill' },
      // One staffed woodcarver consuming lumber.
      { id: 3, player_id: myId, status: 'active', is_staffed: true, building_type_key: 'woodcarver' },
      // Unstaffed sawmill — should NOT count.
      { id: 4, player_id: myId, status: 'active', is_staffed: false, building_type_key: 'sawmill' },
      // Neighbor's sawmill — should NOT count.
      { id: 5, player_id: 'them', status: 'active', is_staffed: true, building_type_key: 'sawmill' }
    ],
    buildingTypes: {
      sawmill:    { key: 'sawmill', category: 'processor', name: 'Sawmill',
                    input_resource_key: 'timber', input_rate: 2,
                    output_resource_key: 'lumber', output_rate: 1 },
      woodcarver: { key: 'woodcarver', category: 'processor', name: 'Woodcarver',
                    input_resource_key: 'lumber', input_rate: 1,
                    output_resource_key: 'furniture', output_rate: 0.5 }
    },
    resources: { timber: { name: 'Timber' }, lumber: { name: 'Lumber' }, furniture: { name: 'Furniture' } },
    housingTierConfig: {}, housingLifestyleDemands: {}, inventory: {}, tradePolicies: {},
    traders: {}, allTraderPrices: {}, profile: { productivity: 1.0 }
  };

  it('groups producers by building type with count + total rate', () => {
    const flow = computeResourceFlow('lumber', ctx, myId);
    expect(flow.production).toHaveLength(1);
    expect(flow.production[0]).toMatchObject({ name: 'Sawmill', count: 2, rate: 2 });
  });

  it('lists processors that consume the resource with output annotation', () => {
    const flow = computeResourceFlow('lumber', ctx, myId);
    expect(flow.processing).toHaveLength(1);
    expect(flow.processing[0]).toMatchObject({ name: 'Woodcarver', count: 1, rate: 1, output: 'Furniture' });
  });

  it('ignores unstaffed buildings and other players\' buildings', () => {
    const flow = computeResourceFlow('timber', ctx, myId);
    // The 2 staffed sawmills consume timber (input). The unstaffed
    // sawmill and the neighbor's sawmill must not contribute.
    expect(flow.processing).toHaveLength(1);
    expect(flow.processing[0].count).toBe(2);
  });

  it('adds NPC trader exports when policy is sell_surplus and a buy_price exists', () => {
    const withTrader = {
      ...ctx,
      tradePolicies: { lumber: { mode: 'sell_surplus', min_sell_price: 0 } },
      traders: { river: { name: 'River Traders', visit_capacity: 20, visit_interval_minutes: 10 } },
      allTraderPrices: { river: { lumber: { buy_price: 8, daily_buy_cap: null } } }
    };
    const flow = computeResourceFlow('lumber', withTrader, myId);
    expect(flow.exports).toHaveLength(1);
    expect(flow.exports[0]).toMatchObject({ trader: 'River Traders', price: 8 });
    expect(flow.exports[0].rate).toBeCloseTo(2, 5);   // 20/10 burst
  });

  it('caps trader rate at daily_buy_cap/1440 when set', () => {
    const withCap = {
      ...ctx,
      tradePolicies: { lumber: { mode: 'sell_surplus' } },
      traders: { river: { name: 'River Traders', visit_capacity: 20, visit_interval_minutes: 10 } },
      allTraderPrices: { river: { lumber: { buy_price: 8, daily_buy_cap: 144 } } }   // 0.1/min sustained
    };
    const flow = computeResourceFlow('lumber', withCap, myId);
    expect(flow.exports[0].rate).toBeCloseTo(0.1, 5);
  });

  it('returns empty flow when ctx is null', () => {
    const flow = computeResourceFlow('lumber', null, myId);
    expect(flow.production).toEqual([]);
    expect(flow.processing).toEqual([]);
    expect(flow.citizens).toBe(0);
  });
});

describe('tileHash', () => {
  it('returns a non-negative 32-bit integer', () => {
    const h = tileHash(5, 10);
    expect(Number.isInteger(h)).toBe(true);
    expect(h).toBeGreaterThanOrEqual(0);
    expect(h).toBeLessThan(2 ** 32);
  });

  it('is deterministic — same coords always return the same value', () => {
    expect(tileHash(7, 11)).toBe(tileHash(7, 11));
    expect(tileHash(-3, 4)).toBe(tileHash(-3, 4));
  });

  it('different coords return different values (with overwhelming probability)', () => {
    expect(tileHash(0, 0)).not.toBe(tileHash(1, 0));
    expect(tileHash(0, 0)).not.toBe(tileHash(0, 1));
    expect(tileHash(5, 5)).not.toBe(tileHash(5, 6));
  });

  it('handles negative coordinates', () => {
    expect(tileHash(-1, -1)).toBeGreaterThanOrEqual(0);
    expect(tileHash(-100, 50)).toBeGreaterThanOrEqual(0);
  });

  it('hashes uniformly enough for a small grid sample', () => {
    // 10×10 grid → 100 hashes. With a decent hash these should all
    // be distinct (no collisions in a sparse space).
    const seen = new Set();
    for (let x = 0; x < 10; x++) {
      for (let y = 0; y < 10; y++) seen.add(tileHash(x, y));
    }
    expect(seen.size).toBe(100);
  });
});

