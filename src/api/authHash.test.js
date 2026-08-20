import { describe, it, expect } from 'vitest';
import { parseAuthHash, describeAuthError } from './authHash.js';

describe('parseAuthHash', () => {
  it('detects a password-recovery fragment', () => {
    expect(parseAuthHash('#access_token=eyJ&expires_in=3600&type=recovery'))
      .toEqual({ kind: 'recovery' });
  });

  it('works without the leading hash', () => {
    expect(parseAuthHash('type=recovery')).toEqual({ kind: 'recovery' });
  });

  it('reports an expired link instead of swallowing it', () => {
    const r = parseAuthHash(
      '#error=access_denied&error_code=otp_expired' +
      '&error_description=Email+link+is+invalid+or+has+expired');
    expect(r.kind).toBe('error');
    expect(r.code).toBe('otp_expired');
    expect(r.message).toBe('Email link is invalid or has expired');
  });

  it('prefers the error branch when a fragment carries both', () => {
    // Supabase never sends both, but an error must never be mistaken
    // for a usable recovery session.
    expect(parseAuthHash('#type=recovery&error=access_denied').kind).toBe('error');
  });

  it('ignores unrelated and empty fragments', () => {
    expect(parseAuthHash('')).toBeNull();
    expect(parseAuthHash('#')).toBeNull();
    expect(parseAuthHash(null)).toBeNull();
    expect(parseAuthHash(undefined)).toBeNull();
    // A signup-confirmation link is a different flow — must not be
    // hijacked into the set-password screen.
    expect(parseAuthHash('#access_token=eyJ&type=signup')).toBeNull();
    expect(parseAuthHash('#some=unrelated')).toBeNull();
  });
});

describe('describeAuthError', () => {
  it('explains an expired one-time link in plain language', () => {
    const msg = describeAuthError({ kind: 'error', code: 'otp_expired', message: '' });
    expect(msg).toMatch(/expired/i);
    expect(msg).toMatch(/new one/i);
  });

  it('falls back to the server message for unknown codes', () => {
    expect(describeAuthError({ code: 'weird', message: 'Server said no' }))
      .toBe('Server said no');
  });

  it('still says something useful with no message at all', () => {
    expect(describeAuthError({ code: 'weird', message: '' })).toBeTruthy();
    expect(describeAuthError(null)).toBe('');
  });
});
