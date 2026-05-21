// Changelog modal — auto-pops on game enter if there are unseen
// entries, also reachable manually from Settings (deferred — Settings
// just opens it via openChangelog()). Mirrors v1's "What's new"
// surface: drop a changelog_entries row when shipping a player-
// visible feature and players see it on next load.
import { sb } from '../api/supabase.js';
import { escapeHtml } from './util.js';

let mounted = false;

// Fired from main.js after the game scene is up. Quiet no-op if
// there's nothing unseen — most loads don't show anything.
export async function checkAndShowChangelogIfUnseen() {
  const { data, error } = await sb.rpc('get_unseen_changelog_entries');
  if (error || !data || !data.length) return;
  showEntries(data);
}

// Manual open — read recent entries regardless of seen state.
export async function openChangelog() {
  const { data, error } = await sb.rpc('list_changelog_entries', { p_limit: 30 });
  if (error) { alert('Could not load changelog: ' + error.message); return; }
  showEntries(data || [], { manual: true });
}

function showEntries(entries, opts = {}) {
  if (mounted) return;
  mounted = true;

  const root = document.getElementById('ui-root');
  const overlay = document.createElement('div');
  overlay.id = 'changelog-overlay';
  overlay.innerHTML = `
    <div class="cl-card">
      <div class="cl-header">
        <h2>${opts.manual ? 'What\'s new' : 'New since last visit'}</h2>
        <button class="cl-close" aria-label="Close">×</button>
      </div>
      <div class="cl-body">
        ${entries.map((e) => `
          <div class="cl-entry">
            <h3 class="cl-entry-title">${escapeHtml(e.title)}</h3>
            <p class="cl-entry-date">${formatDate(e.created_at || e.published_at)}</p>
            <div class="cl-entry-body">${escapeMultiline(e.body)}</div>
          </div>
        `).join('') || '<p class="cl-empty">No changelog entries.</p>'}
      </div>
      <div class="cl-actions">
        <button class="ui-btn-primary" id="cl-gotit">Got it</button>
      </div>
    </div>
  `;
  root.appendChild(overlay);

  const close = async () => {
    overlay.remove();
    mounted = false;
    // Mark seen on close. Fire-and-forget — if it fails the player
    // sees the same entries next load, which is the safer failure
    // mode than silently swallowing them.
    if (!opts.manual) {
      try { await sb.rpc('mark_changelog_seen'); } catch (_e) { /* ignore */ }
    }
  };

  overlay.querySelector('.cl-close').addEventListener('click', close);
  overlay.querySelector('#cl-gotit').addEventListener('click', close);
  overlay.addEventListener('click', (e) => {
    if (e.target === overlay) close();
  });
}

function formatDate(iso) {
  if (!iso) return '';
  const d = new Date(iso);
  if (!Number.isFinite(d.getTime())) return '';
  return d.toLocaleDateString([], { year: 'numeric', month: 'short', day: 'numeric' });
}


// Preserve newlines so multi-paragraph bodies render readably.
function escapeMultiline(s) {
  return escapeHtml(s).replace(/\n/g, '<br>');
}
