// Trade > Players subtab. Combines incoming + outgoing one-off
// trade offers + active agreements, plus a "Trade with N" launcher
// for each other player. Mirrors v1's panel-trade-players surface.
import { state } from '../../state/store.js';
import {
  listMyOffers, listTradeAgreements,
  acceptTrade, rejectTrade, cancelTrade,
  acceptTradeAgreement, cancelTradeAgreement,
  proposeTrade, proposeTradeAgreement,
  getPlayerTradeView
} from '../../api/trade.js';
import { sb } from '../../api/supabase.js';
import { escapeHtml } from '../util.js';

let composeTarget = null;
// Counterparty's tradeable stock — populated async after compose
// opens. Lets the receive-side annotate "they have N" + the Send
// button refuse to ask for more than they have.
let composeTargetView = null;

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
      composeTargetView = null;   // null = still loading
      // Kick off the trade-view fetch in parallel with the compose
      // render. When it lands, we re-render so the receive-side picks
      // up "they have N" annotations.
      const fetchedFor = composeTarget.id;
      getPlayerTradeView(composeTarget.id).then((view) => {
        if (composeTarget?.id !== fetchedFor) return;   // user closed / switched
        composeTargetView = view || { money: 0, inventory: {} };
        renderTradePlayers(parent);
      }).catch(() => {
        // Server error — leave view null. Compose still works, just
        // without availability annotations or pre-validation.
        if (composeTarget?.id === fetchedFor) composeTargetView = { money: 0, inventory: {} };
      });
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

  // For incoming offers, pre-check whether I can actually fulfill the
  // give-side. If not, the Accept button disables and we show what's
  // missing so the player doesn't tap, get a vague error, and lose
  // trust. The carve-out matches the server (`accept_trade` accepts
  // zero-money even with a negative-cash counterparty).
  let blockerHtml = '';
  let acceptDisabled = '';
  if (dir === 'incoming') {
    const blockers = computeInboxBlockers(o);
    if (blockers.length > 0) {
      acceptDisabled = 'disabled';
      blockerHtml = `<div class="to-offer-blocker">
        Can't accept yet: missing ${blockers.map(escapeHtml).join(', ')}
      </div>`;
    }
  }

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
    ${blockerHtml}
    <div class="to-offer-actions">
      ${dir === 'incoming'
        ? `<button class="ip-btn ip-btn-primary" data-act="accept" data-id="${o.id}" ${acceptDisabled}>Accept</button>
           <button class="ip-btn ip-btn-danger"  data-act="reject" data-id="${o.id}">Reject</button>`
        : `<button class="ip-btn ip-btn-danger"  data-act="cancel" data-id="${o.id}">Cancel</button>`}
    </div>
  </div>`;
}

// For an incoming offer, return labels of resources / money I'd need
// to fulfill the give-side but don't currently have. Empty array means
// I can accept. Money carve-out: the offer expects ME to send X cash —
// if I have less, that's a blocker. (No symmetric reverse — the server
// gates the counterparty's ability to deliver separately at accept.)
//
// Exported with ctx-bag so it's unit-testable. The render path uses
// the no-arg overload that reads from `state` directly.
export function computeInboxBlockers(offer, ctx) {
  const myMoney = Number((ctx?.money) ?? state.profile?.money ?? 0);
  const inv = ctx?.inventory ?? state.inventory ?? {};
  const resources = ctx?.resources ?? state.resourceNodes ?? {};

  const blockers = [];
  const askedMoney = Number(offer.receive_money || 0);
  if (askedMoney > myMoney) {
    blockers.push(`$${askedMoney - myMoney}`);
  }
  const askedResources = Array.isArray(offer.receive_resources) ? offer.receive_resources : [];
  for (const r of askedResources) {
    const have = Math.floor(Number(inv[r.resource_key] || 0));
    if (have < r.quantity) {
      const name = resources[r.resource_key]?.name || r.resource_key;
      blockers.push(`${r.quantity - have} ${name}`);
    }
  }
  return blockers;
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
  const targetLoaded = composeTargetView !== null;
  const targetInventory = composeTargetView?.inventory || {};
  const targetMoney = composeTargetView?.money;

  // Receive-side dropdown lists every resource but annotates with
  // "(they have N)" for ones the counterparty holds. While the view
  // is still loading, show "loading…" instead of bogus zeros.
  const receiveOptions = resourceOptions.map((r) => {
    const have = Math.floor(Number(targetInventory[r.key] || 0));
    const note = !targetLoaded ? ' (loading…)'
      : have > 0 ? ` (they have ${have})`
      : ' (they have 0)';
    return `<option value="${r.key}">${r.name}${note}</option>`;
  }).join('');

  // Give-side annotates with what *I* have so the player doesn't
  // accidentally promise more than they can deliver.
  const giveOptions = resourceOptions.map((r) => {
    const mine = Math.floor(Number(state.inventory?.[r.key] || 0));
    const note = mine > 0 ? ` (you have ${mine})` : ' (you have 0)';
    return `<option value="${r.key}">${r.name}${note}</option>`;
  }).join('');

  const moneyHint = !targetLoaded ? 'loading…'
    : targetMoney != null ? `they have $${targetMoney}`
    : '';

  parent.innerHTML = `
    <p class="to-hint">Trade with <strong>${escapeHtml(composeTarget.display_name)}</strong> — one-off or recurring.</p>
    <div class="to-compose">
      <div class="to-compose-half">
        <h3 class="to-section-title">You give</h3>
        <label class="to-field"><span>$ money <small class="to-avail">you have $${Math.floor(state.profile?.money || 0)}</small></span><input type="number" min="0" id="give-money" value="0"/></label>
        <label class="to-field"><span>Resource</span><select id="give-res"><option value="">(none)</option>${giveOptions}</select></label>
        <label class="to-field"><span>Quantity</span><input type="number" min="0" id="give-qty" value="0"/></label>
      </div>
      <div class="to-compose-half">
        <h3 class="to-section-title">You receive</h3>
        <label class="to-field"><span>$ money <small class="to-avail">${escapeHtml(moneyHint)}</small></span><input type="number" min="0" id="recv-money" value="0"/></label>
        <label class="to-field"><span>Resource</span><select id="recv-res"><option value="">(none)</option>${receiveOptions}</select></label>
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

    // If we have the counterparty view, refuse asking for more than
    // they actually have. Money check has a carve-out for receiveMoney
    // = 0 so a recipient with negative cash can still ACCEPT an offer
    // that asks them for goods only (matches accept_trade server gate).
    if (composeTargetView) {
      if (recvMoney > 0 && (composeTargetView.money || 0) < recvMoney) {
        alert(`${composeTarget.display_name} only has $${Math.max(0, composeTargetView.money || 0)} — lower the requested money.`);
        return;
      }
      for (const r of recvBundle) {
        const have = Math.floor(Number(composeTargetView.inventory?.[r.resource_key] || 0));
        if (have < r.quantity) {
          const name = state.resourceNodes?.[r.resource_key]?.name || r.resource_key;
          alert(`${composeTarget.display_name} only has ${have} ${name} — they can't fulfill this offer.`);
          return;
        }
      }
    }

    // Symmetric: refuse over-promising on the give side too. Server
    // catches this at accept time but client-side is faster + clearer.
    if (giveMoney > 0 && giveMoney > Math.floor(state.profile?.money || 0)) {
      alert(`You only have $${Math.floor(state.profile?.money || 0)} — lower the give amount.`);
      return;
    }
    for (const r of giveBundle) {
      const mine = Math.floor(Number(state.inventory?.[r.resource_key] || 0));
      if (mine < r.quantity) {
        const name = state.resourceNodes?.[r.resource_key]?.name || r.resource_key;
        alert(`You only have ${mine} ${name} — lower the give quantity.`);
        return;
      }
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
