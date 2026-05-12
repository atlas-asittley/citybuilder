// User-facing toggle in Settings — when off, body.anim-off disables
// every CSS animation + transition globally. Phaser-side animations
// (walkers, building anims) keep running because the JS tween loop
// is separate; but DOM-overlay animations stop, which is where the
// expensive ones live anyway.
//
// Persisted in localStorage so the choice survives reloads. Mirrors
// v1's perf escape hatch.
const KEY = 'city_animations_disabled';

export function applyAnimationsPreference() {
  let disabled = false;
  try { disabled = localStorage.getItem(KEY) === 'true'; } catch (_e) { /* ignore */ }
  document.body.classList.toggle('anim-off', disabled);
}

export function isAnimationsEnabled() {
  try { return localStorage.getItem(KEY) !== 'true'; } catch (_e) { return true; }
}

export function setAnimationsEnabled(enabled) {
  try { localStorage.setItem(KEY, enabled ? 'false' : 'true'); } catch (_e) { /* ignore */ }
  applyAnimationsPreference();
}
