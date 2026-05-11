// Players panel — list of every player profile in the shared world.
// v1 has a more elaborate version with trade-offer toggles; v2's
// first cut just shows who else is here, what industry they chose,
// and their custom color.
import { sb } from '../api/supabase.js';
import { state } from '../state/store.js';
import { openComposeFor } from './TradeOffersPanel.js';

let mounted = false;

export async function openPlayers() {
  if (mounted) return;
  mounted = true;

  const root = document.getElementById('ui-root');
  const overlay = document.createElement('div');
  overlay.id = 'players-overlay';
  overlay.innerHTML = `
    <div class="pp-card">
      <div class="pp-header">
        <h2>Players in this world</h2>
        <button class="pp-close" aria-label="Close">×</button>
      </div>
      <div class="pp-body" id="pp-body">
        <p class="pp-loading">Loading…</p>
      </div>
    </div>
  `;
  root.appendChild(overlay);

  const close = () => {
    overlay.remove();
    mounted = false;
  };
  overlay.querySelector('.pp-close').addEventListener('click', close);
  overlay.addEventListener('click', (e) => {
    if (e.target === overlay) close();
  });

  // Fetch a fresh roster each open so newcomers show up. Cheap —
  // tens of rows at most.
  const { data, error } = await sb
    .from('player_profiles')
    .select('id, display_name, industry_key, color_hex, population, money, chunks_owned')
    .order('population', { ascending: false });

  if (error) {
    document.getElementById('pp-body').innerHTML = `<p class="pp-error">Couldn't load players: ${error.message}</p>`;
    return;
  }

  const myId = state.currentUser?.id;
  const html = data.map((p) => {
    const color = p.color_hex || '#16c79a';
    const isMe = p.id === myId;
    return `
      <div class="pp-row${isMe ? ' pp-row-me' : ''}">
        <span class="pp-dot" style="background:${color};"></span>
        <div class="pp-info">
          <div class="pp-name">${escapeHtml(p.display_name || '(unnamed)')}${isMe ? ' <small>(you)</small>' : ''}</div>
          <div class="pp-meta">${escapeHtml(p.industry_key || '—')} · pop ${Math.floor(p.population || 0)} · $${Math.floor(p.money || 0)} · ${p.chunks_owned || 1} chunks</div>
        </div>
        ${isMe ? '' : `<button class="pp-trade" data-pid="${p.id}" data-name="${escapeHtml(p.display_name || '')}">Trade</button>`}
      </div>
    `;
  }).join('');

  document.getElementById('pp-body').innerHTML = html || '<p class="pp-loading">No players yet.</p>';

  document.querySelectorAll('.pp-trade').forEach((btn) => {
    btn.addEventListener('click', () => {
      openComposeFor({ id: btn.dataset.pid, display_name: btn.dataset.name });
    });
  });
}

function escapeHtml(s) {
  return String(s).replace(/[&<>"]/g, (c) => ({
    '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;'
  }[c]));
}
