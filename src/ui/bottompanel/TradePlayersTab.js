// Trade > Players subtab. Combines incoming + outgoing one-off
// trade offers + active agreements, plus a "Trade with N" launcher
// for each other player. Mirrors v1's panel-trade-players surface.
import { state } from '../../state/store.js';
import {
  listMyOffers, listTradeAgreements,
  acceptTrade, rejectTrade, cancelTrade,
  acceptTradeAgreement, cancelTradeAgreement,
  proposeTrade, proposeTradeAgreement
} from '../../api/trade.js';
import { sb } from '../../api/supabase.js';

let composeTarget = null;

export async function renderTradePlayers(parent) {
  if (composeTarget) {
    return renderCompose(parent);
  }

  parent.innerHTML = '<p class="to-loading">Loading…</p>';

  let offers = [], agreements = [], players = [];
  try {
    const [offRes, agrRes, plRes] = await Promise.all([
      listMyOffers(),
      listTradeAgreements().catch(() => []),
      sb.from('player_profiles').select('id, display_name, color_hex, industry_key').order('display_name')
    ]);
    offers = offRes;
    agreements = agrRes;
    players = (plRes.data || []).filter((p) => p.id !== state.currentUser?.id);
  } catch (err) {
    parent.innerHTML = `<p class="to-error">Couldn't load: ${err.message || err}</p>`;
    return;
  }

  const myId = state.currentUser?.id;
  const incoming = offers.filter((o) => o.to_player_id === myId);
  const outgoing = offers.filter((o) => o.from_player_id === myId);
  const pendingAgrs = agreements.filter((a) => a.status === 'pending');
  const activeAgrs  = agreements.filter((a) => a.status === 'active');

  parent.innerHTML = `
    ${incoming.length ? `
      <h3 class="to-section-title">Incoming offers (${incoming.length})</h3>
      ${incoming.map((o) => renderOfferRow(o, 'incoming')).join('')}
    ` : ''}
    ${outgoing.length ? `
      <h3 class="to-section-title">Outgoing offers (${outgoing.length})</h3>
      ${outgoing.map((o) => renderOfferRow(o, 'outgoing')).join('')}
    ` : ''}
    ${pendingAgrs.length ? `
      <h3 class="to-section-title">Pending agreements (${pendingAgrs.length})</h3>
      ${pendingAgrs.map((a) => renderAgreementRow(a, myId, 'pending')).join('')}
    ` : ''}
    ${activeAgrs.length ? `
      <h3 class="to-section-title">Active agreements (${activeAgrs.length})</h3>
      ${activeAgrs.map((a) => renderAgreementRow(a, myId, 'active')).join('')}
    ` : ''}
    <h3 class="to-section-title">Players in this world</h3>
    ${players.length ? players.map(renderPlayerRow).join('') :
      '<p class="to-empty">No other players yet.</p>'}
  `;

  wireOfferHandlers(parent);
  parent.querySelectorAll('.tp-roster-trade').forEach((btn) => {
    btn.addEventListener('click', () => {
      composeTarget = { id: btn.dataset.pid, display_name: btn.dataset.name };
      renderTradePlayers(parent);
    });
  });
}

function renderPlayerRow(p) {
  const color = p.color_hex || '#16c79a';
  return `<div class="tp-roster-row">
    <span class="tp-roster-dot" style="background:${color};"></span>
    <span class="tp-roster-name">${escapeHtml(p.display_name || '(unnamed)')}</span>
    <span class="tp-roster-industry">${escapeHtml(p.industry_key || '—')}</span>
    <button class="tp-roster-trade" data-pid="${p.id}" data-name="${escapeHtml(p.display_name || '')}">Trade</button>
  </div>`;
}

function renderOfferRow(o, dir) {
  const give = describeBundle(o.give_money, o.give_resources);
  const receive = describeBundle(o.receive_money, o.receive_resources);
  const otherName = dir === 'incoming'
    ? (o.from_player?.display_name || 'someone')
    : (o.to_player?.display_name || 'someone');
  const youGet = dir === 'incoming' ? give : receive;
  const youGive = dir === 'incoming' ? receive : give;
  return `<div class="to-offer">
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
      ${dir === 'incoming'
        ? `<button class="ip-btn ip-btn-primary" data-act="accept" data-id="${o.id}">Accept</button>
           <button class="ip-btn ip-btn-danger"  data-act="reject" data-id="${o.id}">Reject</button>`
        : `<button class="ip-btn ip-btn-danger"  data-act="cancel" data-id="${o.id}">Cancel</button>`}
    </div>
  </div>`;
}

function renderAgreementRow(a, myId, status) {
  const give = describeBundle(a.give_money, a.give_resources);
  const receive = describeBundle(a.receive_money, a.receive_resources);
  const isIncoming = a.to_player_id === myId;
  const otherName = isIncoming
    ? (a.from_player?.display_name || a.from_player_name || 'someone')
    : (a.to_player?.display_name || a.to_player_name || 'someone');
  const youGet = isIncoming ? give : receive;
  const youGive = isIncoming ? receive : give;
  let actions;
  if (status === 'active') {
    actions = `<button class="ip-btn ip-btn-danger" data-act="cancel-agr" data-id="${a.id}">Cancel agreement</button>`;
  } else if (isIncoming) {
    actions = `<button class="ip-btn ip-btn-primary" data-act="accept-agr" data-id="${a.id}">Accept</button>
               <button class="ip-btn ip-btn-danger"  data-act="cancel-agr" data-id="${a.id}">Reject</button>`;
  } else {
    actions = `<button class="ip-btn ip-btn-danger" data-act="cancel-agr" data-id="${a.id}">Cancel</button>`;
  }
  return `<div class="to-offer to-agreement">
    <div class="to-offer-head">
      <span class="to-offer-who">${isIncoming ? 'from' : 'to'} ${escapeHtml(otherName)}</span>
      <span class="to-offer-when">every ${a.interval_minutes}m</span>
    </div>
    <div class="to-offer-body">
      <div class="to-bundle to-bundle-give"><span class="to-bundle-label">${isIncoming ? 'They want' : 'You give'}</span>${youGive}</div>
      <div class="to-bundle to-bundle-get"><span class="to-bundle-label">${isIncoming ? 'You get' : 'You receive'}</span>${youGet}</div>
    </div>
    ${a.message ? `<div class="to-offer-msg">"${escapeHtml(a.message)}"</div>` : ''}
    <div class="to-offer-actions">${actions}</div>
  </div>`;
}

function renderCompose(parent) {
  const resourceOptions = Object.values(state.resourceNodes)
    .filter((r) => r.is_active && r.base_price)
    .sort((a, b) => a.name.localeCompare(b.name));

  parent.innerHTML = `
    <p class="to-hint">Trade with <strong>${escapeHtml(composeTarget.display_name)}</strong> — one-off or recurring.</p>
    <div class="to-compose">
      <div class="to-compose-half">
        <h3 class="to-section-title">You give</h3>
        <label class="to-field"><span>$ money</span><input type="number" min="0" id="give-money" value="0"/></label>
        <label class="to-field"><span>Resource</span><select id="give-res"><option value="">(none)</option>${resourceOptions.map((r) => `<option value="${r.key}">${r.name}</option>`).join('')}</select></label>
        <label class="to-field"><span>Quantity</span><input type="number" min="0" id="give-qty" value="0"/></label>
      </div>
      <div class="to-compose-half">
        <h3 class="to-section-title">You receive</h3>
        <label class="to-field"><span>$ money</span><input type="number" min="0" id="recv-money" value="0"/></label>
        <label class="to-field"><span>Resource</span><select id="recv-res"><option value="">(none)</option>${resourceOptions.map((r) => `<option value="${r.key}">${r.name}</option>`).join('')}</select></label>
        <label class="to-field"><span>Quantity</span><input type="number" min="0" id="recv-qty" value="0"/></label>
      </div>
    </div>
    <label class="to-field"><span>Message (optional)</span><input type="text" id="compose-msg" maxlength="240"/></label>
    <label class="to-field to-field-recurring"><input type="checkbox" id="compose-recurring"/><span>Make recurring (agreement)</span></label>
    <label class="to-field" id="compose-interval-wrap" style="display:none;"><span>Repeat every (minutes)</span><input type="number" min="1" max="1440" id="compose-interval" value="10"/></label>
    <div class="to-compose-actions">
      <button class="ip-btn" id="compose-back">← Back</button>
      <button class="ip-btn ip-btn-primary" id="compose-send">Send offer</button>
    </div>
  `;

  document.getElementById('compose-back').addEventListener('click', () => {
    composeTarget = null;
    renderTradePlayers(parent);
  });
  const recBox = document.getElementById('compose-recurring');
  recBox.addEventListener('change', () => {
    document.getElementById('compose-interval-wrap').style.display = recBox.checked ? '' : 'none';
    document.getElementById('compose-send').textContent = recBox.checked ? 'Propose agreement' : 'Send offer';
  });
  document.getElementById('compose-send').addEventListener('click', async (e) => {
    const btn = e.currentTarget;
    const giveMoney = parseInt(document.getElementById('give-money').value, 10) || 0;
    const giveRes = document.getElementById('give-res').value;
    const giveQty = parseInt(document.getElementById('give-qty').value, 10) || 0;
    const recvMoney = parseInt(document.getElementById('recv-money').value, 10) || 0;
    const recvRes = document.getElementById('recv-res').value;
    const recvQty = parseInt(document.getElementById('recv-qty').value, 10) || 0;
    const msg = document.getElementById('compose-msg').value.trim();
    const recurring = recBox.checked;
    const interval = parseInt(document.getElementById('compose-interval').value, 10);

    const giveBundle = giveRes && giveQty > 0 ? [{ resource_key: giveRes, quantity: giveQty }] : [];
    const recvBundle = recvRes && recvQty > 0 ? [{ resource_key: recvRes, quantity: recvQty }] : [];

    if (giveMoney === 0 && !giveBundle.length && recvMoney === 0 && !recvBundle.length) {
      alert('An offer needs at least one thing to give or receive.');
      return;
    }
    if (recurring && (!Number.isFinite(interval) || interval <= 0)) {
      alert('Enter a positive interval in minutes.');
      return;
    }

    btn.disabled = true; btn.textContent = 'Sending…';
    try {
      const fn = recurring ? proposeTradeAgreement : proposeTrade;
      await fn({
        toPlayerId: composeTarget.id,
        giveMoney, giveResources: giveBundle,
        receiveMoney: recvMoney, receiveResources: recvBundle,
        intervalMinutes: interval, message: msg
      });
      composeTarget = null;
      renderTradePlayers(parent);
    } catch (err) {
      alert(err.message || 'Send failed.');
      btn.disabled = false; btn.textContent = recurring ? 'Propose agreement' : 'Send offer';
    }
  });
}

function wireOfferHandlers(root) {
  const fns = {
    'accept': acceptTrade, 'reject': rejectTrade, 'cancel': cancelTrade,
    'accept-agr': acceptTradeAgreement, 'cancel-agr': cancelTradeAgreement
  };
  root.querySelectorAll('button[data-act]').forEach((btn) => {
    btn.addEventListener('click', async () => {
      const act = btn.dataset.act;
      const fn = fns[act];
      if (!fn) return;
      btn.disabled = true; btn.textContent = '…';
      try { await fn(btn.dataset.id); renderTradePlayers(root); }
      catch (err) { alert(err.message || act + ' failed'); btn.disabled = false; }
    });
  });
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
function escapeHtml(s) {
  return String(s || '').replace(/[&<>"]/g, (c) => ({
    '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;'
  }[c]));
}
