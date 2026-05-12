// Tests for the runway calc + formatter. Pure-logic units with no
// Phaser / Supabase / DOM dependency.
import { describe, it, expect, beforeEach } from 'vitest';
import { computeCityRunway, formatRunway } from './runway.js';
import { state } from './store.js';

function resetState() {
  state.currentUser = { id: 'me' };
  state.profile = {
    money: 1000, population: 50, chunks_owned: 1
  };
  state.allBuildings = [];
  state.buildingTypes = {};
  state.inventory = {};
  state.housingLifestyleDemands = {};
  state.buildingBuffers = {};
}

describe('formatRunway', () => {
  it('returns ∞ for non-finite minutes', () => {
    expect(formatRunway(Infinity)).toBe('∞');
  });

  it('returns "<1m" for fractional minutes', () => {
    expect(formatRunway(0.5)).toBe('<1m');
  });

  it('returns minutes for <1h', () => {
    expect(formatRunway(45)).toBe('45m');
  });

  it('returns hours+minutes for <1d', () => {
    expect(formatRunway(125)).toBe('2h 5m');
    expect(formatRunway(180)).toBe('3h');
  });

  it('returns days+hours for >1d', () => {
    expect(formatRunway(60 * 25)).toBe('1d 1h');
    expect(formatRunway(60 * 24 * 3)).toBe('3d');
  });
});

describe('computeCityRunway', () => {
  beforeEach(resetState);

  it('returns ∞ with no profile', () => {
    state.currentUser = null;
    state.profile = null;
    expect(computeCityRunway()).toEqual({ minutes: Infinity, bottleneck: null });
  });

  it('returns ∞ when no buildings exist', () => {
    expect(computeCityRunway()).toEqual({ minutes: Infinity, bottleneck: null });
  });

  it('returns ∞ when revenue >= upkeep', () => {
    state.buildingTypes = {
      tax_office: { category: 'tax', output_rate: 50, upkeep_per_minute: 0 },
      police: { category: 'police', upkeep_per_minute: 30, output_rate: 0 }
    };
    state.allBuildings = [
      { player_id: 'me', status: 'active', is_staffed: true, building_type_key: 'tax_office' },
      { player_id: 'me', status: 'active', is_staffed: true, building_type_key: 'police' }
    ];
    // tax = 50 × (50/100) = 25/min; upkeep = 30/min — money loss but
    // not infinite. Wait: 25 - 30 = -5/min. money = 1000 → 200 min.
    const r = computeCityRunway();
    expect(r.bottleneck).toBe('money');
    expect(r.minutes).toBeCloseTo(200, 0);
  });

  it('reports money runway when upkeep > tax', () => {
    state.buildingTypes = {
      police: { category: 'police', upkeep_per_minute: 100, output_rate: 0 }
    };
    state.allBuildings = [
      { player_id: 'me', status: 'active', is_staffed: true, building_type_key: 'police' }
    ];
    const r = computeCityRunway();
    expect(r.bottleneck).toBe('money');
    expect(r.minutes).toBeCloseTo(10, 0);   // 1000 / 100/min
  });

  it('reports lifestyle resource runway when shortest', () => {
    // Player has cottages that need pottery, no pottery production,
    // and 5 pottery in stock.
    state.profile.money = 100000;   // money runway ∞
    state.housingLifestyleDemands = {
      2: [{ resource_key: 'pottery', qty_per_minute: 0.05 }]
    };
    state.buildingTypes = {
      cottage: { category: 'housing' }
    };
    state.allBuildings = [
      { player_id: 'me', status: 'active', is_staffed: true, building_type_key: 'cottage', housing_tier: 2 },
      { player_id: 'me', status: 'active', is_staffed: true, building_type_key: 'cottage', housing_tier: 2 }
    ];
    state.inventory = { pottery: 5 };
    const r = computeCityRunway();
    // 2 houses × 0.05/min = 0.1/min drain. 5 / 0.1 = 50 min.
    expect(r.bottleneck).toBe('pottery');
    expect(r.minutes).toBeCloseTo(50, 0);
  });

  it('subtracts pottery production from drain', () => {
    state.profile.money = 100000;
    state.housingLifestyleDemands = {
      2: [{ resource_key: 'pottery', qty_per_minute: 0.1 }]
    };
    state.buildingTypes = {
      cottage: { category: 'housing' },
      pottery_kiln: { category: 'processor', output_resource_key: 'pottery', output_rate: 0.07 }
    };
    state.allBuildings = [
      { player_id: 'me', status: 'active', is_staffed: true, building_type_key: 'cottage', housing_tier: 2 },
      { player_id: 'me', status: 'active', is_staffed: true, building_type_key: 'pottery_kiln' }
    ];
    state.inventory = { pottery: 30 };
    // drain = 0.1, production = 0.07, net = 0.03/min. 30 / 0.03 = 1000 min.
    const r = computeCityRunway();
    expect(r.bottleneck).toBe('pottery');
    expect(r.minutes).toBeCloseTo(1000, 0);
  });

  it('picks the worst bottleneck when multiple resources drain', () => {
    state.profile.money = 100000;
    state.housingLifestyleDemands = {
      2: [
        { resource_key: 'pottery', qty_per_minute: 0.1 },
        { resource_key: 'bread', qty_per_minute: 0.2 }
      ]
    };
    state.buildingTypes = { cottage: { category: 'housing' } };
    state.allBuildings = [
      { player_id: 'me', status: 'active', is_staffed: true, building_type_key: 'cottage', housing_tier: 2 }
    ];
    state.inventory = { pottery: 100, bread: 10 };
    // pottery: 100 / 0.1 = 1000 min; bread: 10 / 0.2 = 50 min.
    // bread is the bottleneck.
    const r = computeCityRunway();
    expect(r.bottleneck).toBe('bread');
    expect(r.minutes).toBeCloseTo(50, 0);
  });

  it('ignores paused / unstaffed buildings for upkeep', () => {
    state.buildingTypes = {
      police: { category: 'police', upkeep_per_minute: 100, output_rate: 0 }
    };
    state.allBuildings = [
      { player_id: 'me', status: 'active', is_staffed: false, building_type_key: 'police' },
      { player_id: 'me', status: 'paused', is_staffed: true, building_type_key: 'police' }
    ];
    const r = computeCityRunway();
    expect(r.minutes).toBe(Infinity);
  });

  it('uses pantry buffers for lifestyle stock when buildingBuffers is loaded', () => {
    state.housingLifestyleDemands = { 2: [{ resource_key: 'pottery', qty_per_minute: 1 }] };
    state.buildingTypes = { cottage: { category: 'housing' } };
    state.allBuildings = [
      { id: 1, player_id: 'me', status: 'active', is_staffed: true, building_type_key: 'cottage', housing_tier: 2 }
    ];
    // City stock says we have plenty; pantry says 5 minutes left.
    state.inventory = { pottery: 9999 };
    state.buildingBuffers = { 1: { pottery: { quantity: 5, capacity: 30 } } };
    const r = computeCityRunway();
    expect(r.bottleneck).toBe('pottery');
    expect(r.minutes).toBeCloseTo(5, 0);
  });

  it('falls back to city inventory when pantry buffers absent', () => {
    state.housingLifestyleDemands = { 2: [{ resource_key: 'pottery', qty_per_minute: 1 }] };
    state.buildingTypes = { cottage: { category: 'housing' } };
    state.allBuildings = [
      { id: 1, player_id: 'me', status: 'active', is_staffed: true, building_type_key: 'cottage', housing_tier: 2 }
    ];
    state.inventory = { pottery: 12 };
    state.buildingBuffers = {};   // none loaded
    const r = computeCityRunway();
    expect(r.bottleneck).toBe('pottery');
    expect(r.minutes).toBeCloseTo(12, 0);
  });

  it('sums pantry across multiple houses for the same resource', () => {
    state.housingLifestyleDemands = { 2: [{ resource_key: 'bread', qty_per_minute: 1 }] };
    state.buildingTypes = { cottage: { category: 'housing' } };
    state.allBuildings = [
      { id: 1, player_id: 'me', status: 'active', is_staffed: true, building_type_key: 'cottage', housing_tier: 2 },
      { id: 2, player_id: 'me', status: 'active', is_staffed: true, building_type_key: 'cottage', housing_tier: 2 }
    ];
    state.inventory = {};
    state.buildingBuffers = {
      1: { bread: { quantity: 4, capacity: 30 } },
      2: { bread: { quantity: 6, capacity: 30 } }
    };
    // 2 houses × 1/min drain = 2/min; pantry sum = 10; 10 / 2 = 5 min.
    const r = computeCityRunway();
    expect(r.bottleneck).toBe('bread');
    expect(r.minutes).toBeCloseTo(5, 0);
  });
});
