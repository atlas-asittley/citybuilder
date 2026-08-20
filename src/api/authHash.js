// Parsing for the URL fragment Supabase appends to auth redirect links.
//
// A password-recovery email sends the user to
//   <app>/#access_token=…&type=recovery&…
// and supabase-js (detectSessionInUrl, on by default) consumes that
// fragment and CLEARS it during createClient(). So the snapshot has to
// happen before the client is constructed — see api/supabase.js.
//
// Expired or already-used links come back as an error fragment instead:
//   <app>/#error=access_denied&error_code=otp_expired&error_description=…
// Those must be surfaced, not swallowed, or a stale link just dumps the
// user on the welcome screen with no explanation.

/**
 * @param {string} hash raw location.hash, with or without the leading '#'
 * @returns {{kind:'recovery'}|{kind:'error',code:string,message:string}|null}
 */
export function parseAuthHash(hash) {
  const raw = String(hash || '').replace(/^#/, '');
  if (!raw) return null;

  let params;
  try {
    params = new URLSearchParams(raw);
  } catch (_e) {
    return null;
  }

  if (params.get('error')) {
    return {
      kind: 'error',
      code: params.get('error_code') || params.get('error') || 'unknown',
      // Supabase sends error_description form-encoded ('+' for space).
      message: (params.get('error_description') || '').replace(/\+/g, ' '),
    };
  }

  if (params.get('type') === 'recovery') return { kind: 'recovery' };

  return null;
}

/** Human-readable copy for an auth error fragment. */
export function describeAuthError(err) {
  if (!err) return '';
  if (err.code === 'otp_expired') {
    return 'That reset link has expired. Reset links are single-use and time-limited — request a new one below.';
  }
  if (err.code === 'access_denied') {
    return 'That reset link is no longer valid. Request a new one below.';
  }
  return err.message || 'That link could not be used. Request a new one below.';
}
