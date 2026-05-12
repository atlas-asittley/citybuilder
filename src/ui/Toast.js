// Lightweight toast notification — small floating message at the
// top-center of the screen, auto-dismisses after a few seconds.
// Mirrors v1's showToast() shape: showToast(message, kind).
//
// Kinds:
//   'success'  — green
//   'error'    — red
//   'info'     — neutral (default)
//
// Per the bell-log policy memory, v1 reserves toasts for "action
// confirmation" feedback (placed, sold, expanded) — not for bell-log
// events. Same here.
let toastEl = null;
let toastTimer = null;

export function showToast(message, kind = 'info') {
  // Reuse the same element on repeat calls so a rapid sequence of
  // toasts replaces in place instead of stacking.
  if (!toastEl) {
    toastEl = document.createElement('div');
    toastEl.id = 'toast';
    document.getElementById('ui-root').appendChild(toastEl);
  }
  toastEl.className = 'toast toast-' + kind + ' visible';
  toastEl.textContent = message;

  if (toastTimer) clearTimeout(toastTimer);
  toastTimer = setTimeout(() => {
    if (toastEl) toastEl.classList.remove('visible');
  }, 2600);
}
