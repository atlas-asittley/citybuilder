// Tests for the deadlock-retry wrapper around Supabase RPCs.
// We override the rpcCaller + sleep so the test doesn't actually
// touch Supabase or wait 250ms.
import { describe, it, expect, vi } from 'vitest';
import { _callWithDeadlockRetry } from './buildings.js';

describe('callWithDeadlockRetry', () => {
  it('returns the data on first success', async () => {
    const rpc = vi.fn().mockResolvedValue({ data: { ok: true }, error: null });
    const sleep = vi.fn();
    const out = await _callWithDeadlockRetry('test_rpc', { a: 1 }, 1, {
      _rpcOverride: rpc, _sleepOverride: sleep
    });
    expect(out).toEqual({ ok: true });
    expect(rpc).toHaveBeenCalledTimes(1);
    expect(sleep).not.toHaveBeenCalled();
  });

  it('retries once on a deadlock error then succeeds', async () => {
    const rpc = vi.fn()
      .mockResolvedValueOnce({ data: null, error: { message: 'deadlock detected' } })
      .mockResolvedValueOnce({ data: 'ok', error: null });
    const sleep = vi.fn().mockResolvedValue(undefined);
    const out = await _callWithDeadlockRetry('test_rpc', {}, 1, {
      _rpcOverride: rpc, _sleepOverride: sleep
    });
    expect(out).toBe('ok');
    expect(rpc).toHaveBeenCalledTimes(2);
    expect(sleep).toHaveBeenCalledWith(250);
  });

  it('throws non-deadlock errors immediately without retry', async () => {
    const rpc = vi.fn().mockResolvedValue({ data: null, error: { message: 'permission denied' } });
    const sleep = vi.fn();
    await expect(_callWithDeadlockRetry('test_rpc', {}, 1, {
      _rpcOverride: rpc, _sleepOverride: sleep
    })).rejects.toMatchObject({ message: 'permission denied' });
    expect(rpc).toHaveBeenCalledTimes(1);
    expect(sleep).not.toHaveBeenCalled();
  });

  it('throws a final deadlock if retries exhausted', async () => {
    const rpc = vi.fn().mockResolvedValue({ data: null, error: { message: 'deadlock detected' } });
    const sleep = vi.fn().mockResolvedValue(undefined);
    await expect(_callWithDeadlockRetry('test_rpc', {}, 1, {
      _rpcOverride: rpc, _sleepOverride: sleep
    })).rejects.toMatchObject({ message: 'deadlock detected' });
    expect(rpc).toHaveBeenCalledTimes(2);   // initial + 1 retry
    expect(sleep).toHaveBeenCalledTimes(1);
  });

  it('treats null error message as non-deadlock', async () => {
    const rpc = vi.fn().mockResolvedValue({ data: null, error: { message: null } });
    const sleep = vi.fn();
    await expect(_callWithDeadlockRetry('test_rpc', {}, 1, {
      _rpcOverride: rpc, _sleepOverride: sleep
    })).rejects.toBeTruthy();
    expect(rpc).toHaveBeenCalledTimes(1);
  });
});
