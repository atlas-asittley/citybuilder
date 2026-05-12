import { describe, it, expect } from 'vitest';
import { buildingVisuallyChanged } from './realtime.js';

// The realtime UPDATE handler uses this to decide whether to call
// onChangeCallback (which re-renders the scene). For per-tick
// `last_processed_at` updates it must return false; for anything
// the diff renderer's signature reads it must return true.
describe('buildingVisuallyChanged', () => {
  const base = {
    id: 'x', housing_tier: 1, status: 'active', is_staffed: true,
    paused: false, auto_upgrade: true, staffing_priority: 1,
    expansion_level: 0, x: 5, y: 5,
    last_devolve_reason: null, evolution_eligible_at: null,
    last_processed_at: '2026-05-11T22:00:00Z'
  };

  it('false when only last_processed_at changes', () => {
    const next = { ...base, last_processed_at: '2026-05-11T22:01:00Z' };
    expect(buildingVisuallyChanged(base, next)).toBe(false);
  });

  it('true when housing_tier flips', () => {
    expect(buildingVisuallyChanged(base, { ...base, housing_tier: 2 })).toBe(true);
  });
  it('true when status flips', () => {
    expect(buildingVisuallyChanged(base, { ...base, status: 'idle' })).toBe(true);
  });
  it('true when expansion_level changes', () => {
    expect(buildingVisuallyChanged(base, { ...base, expansion_level: 1 })).toBe(true);
  });
  it('true when is_staffed flips', () => {
    expect(buildingVisuallyChanged(base, { ...base, is_staffed: false })).toBe(true);
  });
  it('true when paused flips', () => {
    expect(buildingVisuallyChanged(base, { ...base, paused: true })).toBe(true);
  });
  it('true when auto_upgrade flips', () => {
    expect(buildingVisuallyChanged(base, { ...base, auto_upgrade: false })).toBe(true);
  });
  it('true when priority changes', () => {
    expect(buildingVisuallyChanged(base, { ...base, staffing_priority: 2 })).toBe(true);
  });
  it('true when devolve reason added/removed', () => {
    expect(buildingVisuallyChanged(base, { ...base, last_devolve_reason: 'no_food' })).toBe(true);
  });
  it('true when evolution_eligible_at flips null↔truthy', () => {
    expect(buildingVisuallyChanged(base, { ...base, evolution_eligible_at: '2026-05-11T22:00:00Z' })).toBe(true);
    expect(buildingVisuallyChanged({ ...base, evolution_eligible_at: '...' }, base)).toBe(true);
  });
  it('true when position changes (shouldn\'t happen but covered)', () => {
    expect(buildingVisuallyChanged(base, { ...base, x: 6 })).toBe(true);
    expect(buildingVisuallyChanged(base, { ...base, y: 6 })).toBe(true);
  });
});
