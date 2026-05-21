// Small DOM/UI utilities reused across UI modules. Lives separately
// from scenes/helpers.js (which holds game-domain helpers like
// recipeOf / computeResourceFlow) — this file is UI-formatting only.

import { state } from '../state/store.js';

// Escape HTML-active characters so user-supplied strings can be
// inlined into innerHTML safely. null / undefined collapse to ''
// (so `escapeHtml(null)` returns ''), 0 / false stringify normally
// (so `escapeHtml(0)` returns '0'). Was duplicated in 10 UI files;
// consolidated 2026-05-21.
export function escapeHtml(s) {
  return String(s ?? '').replace(/[&<>"]/g, (c) => ({
    '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;'
  }[c]));
}

// Looks up a resource's display name from state.resourceNodes,
// falling back to the raw key if the catalog hasn't loaded yet or
// the key is unknown. Capitalized form for column headers,
// lowercased form for sentence-flow strings ("produces lumber").
export function resName(key) {
  return state.resourceNodes?.[key]?.name || key;
}

export function resNameLower(key) {
  return resName(key).toLowerCase();
}
