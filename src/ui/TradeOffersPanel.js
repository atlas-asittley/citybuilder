// Player-to-player trade offers. Two views:
//   - Inbox: list incoming + outgoing pending offers, accept/reject/cancel
//   - Compose: send a new one-off offer to a specific player
//
// One-off offers only for now — recurring "agreements" can layer in
// later (propose_trade_agreement RPC takes an interval).
import { state } from '../state/store.js';
import {
  listMyOffers, proposeTrade, acceptTrade, rejectTrade, cancelTrade
} from '../api/trade.js';

let mounted = false;
let composeTarget = null;   // { id, display_name } when in compose mode

export async function openTradeOffers() {
  if (mounted) return;
  mounted = true;

  const root = document.getElementById('ui-root');
  const overlay = document.createElement('div');
  overlay.id = 'offers-overlay';
  overlay.innerHTML = `
    <div class="to-card">
      <div class="to-header">
        <h2 id="to-title">Trade offers</h2>
        <button class="to-close" aria-label="Close">×</button>
      </div>
      <div class="to-body" id="to-body">
        <p class="to-loading">Loading…</p>
      </div>
    </div>
  `;
  root.appendChild(overlay);

  const close = () => {
    overlay.remove();
    mounted = false;
    composeTarget = null;
  };
  overlay.querySelector('.to-close').addEventListener('click', close);
  overlay.addEventListener('click', (e) => {
    if (e.target === overlay) close();
  });

  renderInbox();
}

// Called from the Players panel — opens this overlay directly into
// the compose form for the given player.
export function openComposeFor(player) {
  composeTarget = player;
  if (mounted) {
    renderCompose();
  } else {
    openTradeOffers().then(renderCompose);
  }
}

async function renderInbox() {
  const body = document.getElementById('to-body');
  document.getElementById('to-title').textContent = 'Trade offers';
  if (!body) return;

  let offers = [];
  try { offers = await listMyOffers(); }
  catch (err) {
    body.innerHTML = `<p class="to-error">Couldn't load offers: ${err.message}</p>`;
    return;
  }

  const myId = state.currentUser?.id;
  const incoming = offers.filter((o) => o.to_player_id === myId);
  const outgoing = offers.filter((o) => o.from_player_id === myId);

  body.innerHTML = `
    <p class="to-hint">
      Propose a one-off swap. From the Players panel, tap "Trade" next to anyone to compose.
    </p>
    ${incoming.length ? `
      <h3 class="to-section-title">Incoming (${incoming.length})</h3>
      ${incoming.map((o) => renderOfferRow(o, 'incoming')).join('')}
    ` : '<h3 class="to-section-title">Incoming</h3><p class="to-empty">No incoming offers.</p>'}
    ${outgoing.length ? `
      <h3 class="to-section-title">Outgoing (${outgoing.length})</h3>
      ${outgoing.map((o) => renderOfferRow(o, 'outgoing')).join('')}
    ` : ''}
  `;
  wireOfferHandlers(body);
}

function renderOfferRow(o, dir) {
  const give = describeBundle(o.give_money, o.give_resources);
  const receive = describeBundle(o.receive_money, o.receive_resources);
  const otherName = dir === 'incoming'
    ? (o.from_player?.display_name || 'someone')
    : (o.to_player?.display_name || 'someone');
  // For incoming: from THEIR perspective give→you, so flip the labels
  const youGet = dir === 'incoming' ? give : receive;
  const youGive = dir === 'incoming' ? receive : give;
  return `
    <div class="to-offer">
      <div class="to-offer-head">
        <span class="to-offer-who">${dir === 'incoming' ? 'from' : 'to'} ${escapeHtml(otherName)}</span>
        <span class="to-offer-when">${timeAgo(o.created_at)}</span>
      </div>
      <div class="to-offer-body">
        <div class="to-bundle to-bundle-give"><span class="to-bundle-label">${dir === 'incoming' ? 'They want' : 'You give'}</span>${youGive}</div>
        <div class="to-bundle to-bundle-get"><span class="to-bundle-label">${dir === 'incoming' ? 'You get' : 'You receive'}</span>${youGet}</div>
      </div>
      ${o.message ? `<div class="to-offer-msg">"${escapeHtml(o.message)}"</div>` : ''}
      <div class="to-offer-actions">
        ${dir === 'incoming' ? `
          <button class="ip-btn ip-btn-primary" data-act="accept" data-id="${o.id}">Accept</button>
          <button class="ip-btn ip-btn-danger"  data-act="reject" data-id="${o.id}">Reject</button>
        ` : `
          <button class="ip-btn ip-btn-danger"  data-act="cancel" data-id="${o.id}">Cancel</button>
        `}
      </div>
    </div>
  `;
}

function describeBundle(money, resources) {
  const parts = [];
  if (money && Number(money) > 0) parts.push(`$${money}`);
  if (Array.isArray(resources)) {
    for (const r of resources) {
      const res = state.resourceNodes[r.resource_key];
      parts.push(`${r.quantity} ${res?.name || r.resource_key}`);
    }
  }
  return parts.length ? parts.join(' + ') : '<em>nothing</em>';
}

function timeAgo(iso) {
  if (!iso) return '';
  const ms = Date.now() - new Date(iso).getTime();
  if (ms < 60_000) return 'just now';
  if (ms < 3600_000) return Math.floor(ms / 60_000) + 'm ago';
  if (ms < 86400_000) return Math.floor(ms / 3600_000) + 'h ago';
  return Math.floor(ms / 86400_000) + 'd ago';
}

function wireOfferHandlers(root) {
  root.querySelectorAll('button[data-act]').forEach((btn) => {
    btn.addEventListener('click', async () => {
      const act = btn.dataset.act;
      const id = btn.dataset.id;
      const fn = act === 'accept' ? acceptTrade : act === 'reject' ? rejectTrade : cancelTrade;
      btn.disabled = true;
      btn.textContent = act === 'accept' ? 'Accepting…' : act === 'reject' ? 'Rejecting…' : 'Canceling…';
      try {
        await fn(id);
        renderInbox();
      } catch (err) {
        alert(err.message || (act + ' failed'));
        btn.disabled = false;
        btn.textContent = act.charAt(0).toUpperCase() + act.slice(1);
      }
    });
  });
}

// ── Compose ──

function renderCompose() {
  const body = document.getElementById('to-body');
  document.getElementById('to-title').textContent = `Trade with ${composeTarget?.display_name || ''}`;
  if (!body || !composeTarget) return;

  const resourceOptions = Object.values(state.resourceNodes)
    .filter((r) => r.is_active && r.base_price)
    .sort((a, b) => a.name.localeCompare(b.name));

  body.innerHTML = `
    <p class="to-hint">Propose a one-off swap. They can accept or reject when they next open the game.</p>
    <div class="to-compose">
      <div class="to-compose-half">
        <h3 class="to-section-title">You give</h3>
        <label class="to-field">
          <span>$ money</span>
          <input type="number" min="0" id="give-money" value="0" />
        </label>
        <label class="to-field">
          <span>Resource</span>
          <select id="give-res">
            <option value="">(none)</option>
            ${resourceOptions.map((r) => `<option value="${r.key}">${r.name}</option>`).join('')}
          </select>
        </label>
        <label class="to-field">
          <span>Quantity</span>
          <input type="number" min="0" id="give-qty" value="0" />
        </label>
      </div>
      <div class="to-compose-half">
        <h3 class="to-section-title">You receive</h3>
        <label class="to-field">
          <span>$ money</span>
          <input type="number" min="0" id="recv-money" value="0" />
        </label>
        <label class="to-field">
          <span>Resource</span>
          <select id="recv-res">
            <option value="">(none)</option>
            ${resourceOptions.map((r) => `<option value="${r.key}">${r.name}</option>`).join('')}
          </select>
        </label>
        <label class="to-field">
          <span>Quantity</span>
          <input type="number" min="0" id="recv-qty" value="0" />
        </label>
      </div>
    </div>
    <label class="to-field">
      <span>Message (optional)</span>
      <input type="text" id="compose-msg" maxlength="240" placeholder="A note for them" />
    </label>
    <div class="to-compose-actions">
      <button class="ip-btn" id="compose-back">← Back to inbox</button>
      <button class="ip-btn ip-btn-primary" id="compose-send">Send offer</button>
    </div>
  `;

  document.getElementById('compose-back').addEventListener('click', renderInbox);
  document.getElementById('compose-send').addEventListener('click', async (e) => {
    const btn = e.currentTarget;
    const giveMoney = parseInt(document.getElementById('give-money').value, 10) || 0;
    const giveRes   = document.getElementById('give-res').value;
    const giveQty   = parseInt(document.getElementById('give-qty').value, 10) || 0;
    const recvMoney = parseInt(document.getElementById('recv-money').value, 10) || 0;
    const recvRes   = document.getElementById('recv-res').value;
    const recvQty   = parseInt(document.getElementById('recv-qty').value, 10) || 0;
    const msg       = document.getElementById('compose-msg').value.trim();

    const giveBundle = [];
    if (giveRes && giveQty > 0) giveBundle.push({ resource_key: giveRes, quantity: giveQty });
    const recvBundle = [];
    if (recvRes && recvQty > 0) recvBundle.push({ resource_key: recvRes, quantity: recvQty });

    if (giveMoney === 0 && giveBundle.length === 0 && recvMoney === 0 && recvBundle.length === 0) {
      alert('An offer needs at least one thing to give or receive.');
      return;
    }

    btn.disabled = true;
    btn.textContent = 'Sending…';
    try {
      await proposeTrade({
        toPlayerId: composeTarget.id,
        giveMoney, giveResources: giveBundle,
        receiveMoney: recvMoney, receiveResources: recvBundle,
        message: msg
      });
      renderInbox();
    } catch (err) {
      alert(err.message || 'Send failed.');
      btn.disabled = false;
      btn.textContent = 'Send offer';
    }
  });
}

function escapeHtml(s) {
  return String(s || '').replace(/[&<>"]/g, (c) => ({
    '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;'
  }[c]));
}
