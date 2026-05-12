// Settings panel — sign out, link to the v1 client during the
// migration window, clear local cache. Triggered from the top bar's
// gear button.
import { sb } from '../api/supabase.js';
import { openChangelog } from './ChangelogModal.js';
import { openHelp } from './HelpModal.js';

let mounted = false;

export function openSettings() {
  if (mounted) return;
  const root = document.getElementById('ui-root');
  const overlay = document.createElement('div');
  overlay.id = 'settings-overlay';
  overlay.innerHTML = `
    <div class="sp-card">
      <div class="sp-header">
        <h2>Settings</h2>
        <button class="sp-close" aria-label="Close">×</button>
      </div>
      <div class="sp-body">
        <button class="sp-row" id="sp-help">📖 Buildings reference</button>
        <button class="sp-row" id="sp-whats-new">What's new</button>
        <button class="sp-row" id="sp-reload">Force reload (cache-bust)</button>
        <button class="sp-row" id="sp-logout">Sign out</button>
        <a class="sp-row" href="https://atlas-asittley.github.io/city-builder-mvp/" target="_blank" rel="noopener">Open v1 client (legacy)</a>
        <button class="sp-row" id="sp-clear">Clear session &amp; reload</button>
        <p class="sp-info">v2 build · Phaser/WebGL renderer · same world as v1</p>
      </div>
    </div>
  `;
  root.appendChild(overlay);
  mounted = true;

  const close = () => {
    overlay.remove();
    mounted = false;
  };
  overlay.querySelector('.sp-close').addEventListener('click', close);
  overlay.addEventListener('click', (e) => {
    if (e.target === overlay) close();
  });

  document.getElementById('sp-help').addEventListener('click', () => {
    overlay.remove();
    mounted = false;
    openHelp();
  });

  document.getElementById('sp-whats-new').addEventListener('click', () => {
    overlay.remove();
    mounted = false;
    openChangelog();
  });

  document.getElementById('sp-reload').addEventListener('click', () => {
    // Append a unique query param so the browser bypasses its
    // HTTP cache for the document fetch. Vite already hashes JS/CSS
    // filenames per build, so once the new index.html lands,
    // assets follow. Keeps the Supabase session intact (no signOut).
    const u = new URL(window.location.href);
    u.searchParams.set('_t', Date.now().toString());
    window.location.href = u.toString();
  });

  document.getElementById('sp-logout').addEventListener('click', async () => {
    await sb.auth.signOut();
    location.reload();
  });

  document.getElementById('sp-clear').addEventListener('click', () => {
    try {
      for (let i = localStorage.length - 1; i >= 0; i--) {
        const k = localStorage.key(i);
        if (k && (k.startsWith('sb-') || k.includes('supabase'))) {
          localStorage.removeItem(k);
        }
      }
    } catch (_e) { /* storage disabled */ }
    location.reload();
  });
}
