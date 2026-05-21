// Bell-log dropdown — shows the most recent in-game notifications
// (housing-ready-to-upgrade, trade-agreement-cancelled — the only
// two events that emit per the bell-log policy memory). Polled by
// the tick loop; click the bell to see them.
import { sb } from '../api/supabase.js';
import { state } from '../state/store.js';
import { escapeHtml } from './util.js';

let mounted = false;
let unreadCount = 0;
let onChangedCallback = null;

const KEEP = 50;   // cap history so the dropdown stays light

// Called from the tick loop after each process_production. Pulls
// recent notifications, marks them read on the server in the same
// call (the RPC is "fetch_unread_notifications" — fetch + mark in
// one round trip).
// Server-side notifications fire in bursts (e.g., multiple housing-
// ready events on one tick). Within DEDUP_MS, an incoming row whose
// (kind, payload signature) matches the most recent stored entry
// gets merged: the existing row's count bumps instead of stacking a
// duplicate. Matches v1's notifications.js dedup window.
const DEDUP_MS = 1500;

function notificationKey(n) {
  // kind + a coarse payload fingerprint. For housing-ready we group
  // by kind only so two simultaneous arrivals collapse to one row.
  if (n.kind === 'housing_ready_to_upgrade') return n.kind;
  return n.kind + '|' + JSON.stringify(n.payload || {});
}

export async function pollNotifications() {
  const { data, error } = await sb.rpc('fetch_unread_notifications');
  if (error || !data) return;
  if (!Array.isArray(data) || data.length === 0) return;

  const now = Date.now();
  let bumpUnread = 0;
  for (const incoming of data) {
    const incomingTs = incoming.created_at ? new Date(incoming.created_at).getTime() : now;
    const incomingKey = notificationKey(incoming);
    // Look at the head of the stored list; if it matches the key AND
    // is recent, bump count on it instead of pushing a new entry.
    const head = state.notifications[0];
    const headTs = head?.created_at ? new Date(head.created_at).getTime() : 0;
    if (head && notificationKey(head) === incomingKey && (incomingTs - headTs) < DEDUP_MS) {
      head.count = (head.count || 1) + 1;
      // Preserve original timestamp so the dedup window is anchored on
      // the first occurrence, not the latest — otherwise long bursts
      // would never close out.
    } else {
      state.notifications.unshift(incoming);
      bumpUnread++;
    }
  }
  if (state.notifications.length > KEEP) state.notifications.length = KEEP;
  unreadCount += bumpUnread;
  if (onChangedCallback) onChangedCallback();
  refreshBadge();
  // If the bell overlay happens to be open at this moment, refresh
  // its body too — otherwise the open card would show stale entries
  // until the player closed and re-opened it.
  const overlay = document.getElementById('bell-overlay');
  if (overlay) {
    const body = overlay.querySelector('.bl-body');
    if (body) body.innerHTML = renderRows();
  }
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

// Server fields vary by notification_kind; format the two we
// currently emit cleanly, fall back to a JSON dump for anything
// unfamiliar. Exported for unit tests.
export function formatNotification(n) {
  // Both the server payload (n.payload.count) AND the client-side
  // dedup bump (n.count) can contribute. Sum them so a 5-house batch
  // fired in one tick PLUS a follow-up burst dedups to one row showing
  // the right total.
  const payloadCount = Number(n.payload?.count || 0);
  const dedupCount = Number(n.count || 0);
  const c = Math.max(1, payloadCount + Math.max(0, dedupCount - 1));
  if (n.kind === 'housing_ready_to_upgrade') {
    return c === 1
      ? '1 house is ready to upgrade — open its inspector to step it up.'
      : `${c} houses are ready to upgrade.`;
  }
  if (n.kind === 'trade_agreement_cancelled') {
    const dups = dedupCount > 1 ? ` (×${dedupCount})` : '';
    return `A trade agreement with ${n.payload?.other_party || 'a partner'} was cancelled.${dups}`;
  }
  if (n.kind === 'supply_contract_bumped') {
    // Server emits one of these to every player who'd ever contributed
    // to this contract when it settles. Show what got better.
    const trader = n.payload?.trader_key || 'a trader';
    const resource = n.payload?.resource_key || 'a resource';
    const direction = n.payload?.direction === 'sell' ? 'sells' : 'buys';
    const oldCap = Number(n.payload?.old_cap || 0);
    const newCap = Number(n.payload?.new_cap || 0);
    return `Supply contract funded: ${trader} now ${direction} ${resource} at ${newCap}/day (was ${oldCap}).`;
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

