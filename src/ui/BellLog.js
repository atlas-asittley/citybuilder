// Bell-log dropdown — shows the most recent in-game notifications
// (housing-ready-to-upgrade, trade-agreement-cancelled — the only
// two events that emit per the bell-log policy memory). Polled by
// the tick loop; click the bell to see them.
import { sb } from '../api/supabase.js';
import { state } from '../state/store.js';

let mounted = false;
let unreadCount = 0;
let onChangedCallback = null;

const KEEP = 50;   // cap history so the dropdown stays light

// Called from the tick loop after each process_production. Pulls
// recent notifications, marks them read on the server in the same
// call (the RPC is "fetch_unread_notifications" — fetch + mark in
// one round trip).
export async function pollNotifications() {
  const { data, error } = await sb.rpc('fetch_unread_notifications');
  if (error || !data) return;
  if (!Array.isArray(data) || data.length === 0) return;

  // Newest first. Cap at KEEP so the array doesn't grow forever.
  const next = data.concat(state.notifications).slice(0, KEEP);
  state.notifications = next;
  unreadCount += data.length;
  if (onChangedCallback) onChangedCallback();
  refreshBadge();
}

export function mountBellLog(onChanged) {
  if (mounted) return;
  onChangedCallback = onChanged || null;
  refreshBadge();
}

export function openBellLog() {
  const root = document.getElementById('ui-root');
  if (document.getElementById('bell-overlay')) return;

  const overlay = document.createElement('div');
  overlay.id = 'bell-overlay';
  overlay.innerHTML = `
    <div class="bl-card">
      <div class="bl-header">
        <h2>Notifications</h2>
        <button class="bl-close" aria-label="Close">×</button>
      </div>
      <div class="bl-body">${renderRows()}</div>
    </div>
  `;
  root.appendChild(overlay);

  const close = () => {
    overlay.remove();
    unreadCount = 0;
    refreshBadge();
  };
  overlay.querySelector('.bl-close').addEventListener('click', close);
  overlay.addEventListener('click', (e) => {
    if (e.target === overlay) close();
  });
}

function renderRows() {
  if (state.notifications.length === 0) {
    return '<p class="bl-empty">No notifications yet.</p>';
  }
  return state.notifications.map((n) => {
    const t = n.created_at ? new Date(n.created_at) : null;
    const when = t ? t.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' }) : '';
    const msg = formatNotification(n);
    return `<div class="bl-row">
      <span class="bl-msg">${escapeHtml(msg)}</span>
      <span class="bl-time">${when}</span>
    </div>`;
  }).join('');
}

function formatNotification(n) {
  // Server fields vary by notification_kind; format the two we
  // currently emit cleanly, fall back to a JSON dump for anything
  // unfamiliar.
  if (n.kind === 'housing_ready_to_upgrade') {
    const c = n.payload?.count || 1;
    return c === 1
      ? '1 house is ready to upgrade — open its inspector to step it up.'
      : `${c} houses are ready to upgrade.`;
  }
  if (n.kind === 'trade_agreement_cancelled') {
    return `A trade agreement with ${n.payload?.other_party || 'a partner'} was cancelled.`;
  }
  return JSON.stringify(n);
}

function refreshBadge() {
  const badge = document.getElementById('tb-bell-badge');
  if (!badge) return;
  if (unreadCount > 0) {
    badge.textContent = unreadCount > 9 ? '9+' : String(unreadCount);
    badge.classList.add('visible');
  } else {
    badge.classList.remove('visible');
  }
}

function escapeHtml(s) {
  return String(s).replace(/[&<>"]/g, (c) => ({
    '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;'
  }[c]));
}
