import { describe, it, expect } from 'vitest';
import { computeInboxBlockers } from './TradePlayersTab.js';

describe('computeInboxBlockers', () => {
  const resources = {
    timber: { name: 'Timber' },
    pottery: { name: 'Pottery' }
  };

  it('returns [] when I can fulfill the offer in full', () => {
    const offer = { receive_money: 50, receive_resources: [{ resource_key: 'timber', quantity: 10 }] };
    const ctx = { money: 100, inventory: { timber: 50 }, resources };
    expect(computeInboxBlockers(offer, ctx)).toEqual([]);
  });

  it('blocks on missing money with $-prefixed amount', () => {
    const offer = { receive_money: 200, receive_resources: [] };
    const ctx = { money: 50, inventory: {}, resources };
    expect(computeInboxBlockers(offer, ctx)).toEqual(['$150']);
  });

  it('blocks on every missing resource separately', () => {
    const offer = {
      receive_money: 0,
      receive_resources: [
        { resource_key: 'timber', quantity: 10 },
        { resource_key: 'pottery', quantity: 5 }
      ]
    };
    const ctx = { money: 0, inventory: { timber: 3 }, resources };
    expect(computeInboxBlockers(offer, ctx)).toEqual(['7 Timber', '5 Pottery']);
  });

  it('falls back to raw key when resource name is missing', () => {
    const offer = { receive_money: 0, receive_resources: [{ resource_key: 'mystery', quantity: 1 }] };
    const ctx = { money: 0, inventory: {}, resources };
    expect(computeInboxBlockers(offer, ctx)).toEqual(['1 mystery']);
  });

  it('treats zero money asks as non-blocking even with no cash', () => {
    const offer = { receive_money: 0, receive_resources: [] };
    const ctx = { money: 0, inventory: {}, resources };
    expect(computeInboxBlockers(offer, ctx)).toEqual([]);
  });

  it('treats missing receive_resources as empty array', () => {
    const offer = { receive_money: 0 };
    const ctx = { money: 100, inventory: {}, resources };
    expect(computeInboxBlockers(offer, ctx)).toEqual([]);
  });
});
