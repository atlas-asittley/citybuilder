import { describe, it, expect } from 'vitest';
import { spriteIcons } from './sprites.js';

describe('spriteIcons', () => {
  it('uses data:image/svg+xml URIs', () => {
    for (const [key, uri] of Object.entries(spriteIcons)) {
      expect(uri, key).toMatch(/^data:image\/svg\+xml,/);
    }
  });

  // Regression: 2026-05-22 — sprites with `cx='50%'` rendered as gray
  // squares in Phaser because a bare `%` is invalid percent-encoding.
  // The literal must be encoded as `%25` (i.e. `cx='50%25'`).
  it('never contains an unencoded literal % in attribute values', () => {
    // After the data: prefix, percent followed by anything other than two
    // hex digits is malformed. Look for the canonical offending shape: a
    // digit immediately followed by `%` and then a non-hex character
    // (e.g. `50%'`, `50%c`, `50%)`).
    const offenderRe = /\d%[^0-9a-fA-F]/;
    for (const [key, uri] of Object.entries(spriteIcons)) {
      const m = uri.match(offenderRe);
      expect(m, `${key} has unencoded % near "${m?.[0]}"`).toBeNull();
    }
  });
});
