import { describe, it, expect } from 'vitest';
import {
  buildingSignature,
  resourceKindFor,
  pickWalkerVariant,
  getBuildingAoeRange,
  heatmapTintFor,
  computeWorldBounds,
  sizeWalkerSvg
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
    expect(sig).toBe('house|5,10|t3|sactive|w1|p0|e0|ome');
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
});
