import { describe, it, expect } from 'vitest';
import { formatNotification } from './BellLog.js';

describe('formatNotification', () => {
  it('singular phrasing when housing_ready_to_upgrade count == 1', () => {
    expect(formatNotification({ kind: 'housing_ready_to_upgrade', payload: { count: 1 } }))
      .toMatch(/^1 house is ready/);
  });
  it('plural phrasing when count > 1', () => {
    expect(formatNotification({ kind: 'housing_ready_to_upgrade', payload: { count: 5 } }))
      .toBe('5 houses are ready to upgrade.');
  });
  it('defaults count to 1 when payload missing', () => {
    expect(formatNotification({ kind: 'housing_ready_to_upgrade' }))
      .toMatch(/^1 house is ready/);
  });
  it('names the other party in trade_agreement_cancelled', () => {
    const msg = formatNotification({
      kind: 'trade_agreement_cancelled',
      payload: { other_party: 'Jill' }
    });
    expect(msg).toBe('A trade agreement with Jill was cancelled.');
  });
  it('falls back to "a partner" when other_party absent', () => {
    expect(formatNotification({ kind: 'trade_agreement_cancelled' }))
      .toBe('A trade agreement with a partner was cancelled.');
  });
  it('unknown kinds → JSON dump (so we notice unsigned-off events)', () => {
    const out = formatNotification({ kind: 'new_secret_event', payload: { foo: 'bar' } });
    expect(out).toContain('new_secret_event');
    expect(out).toContain('bar');
  });
});
