// Settings panel — sign out, link to the v1 client during the
// migration window, clear local cache. Triggered from the top bar's
// gear button.
import { sb } from '../api/supabase.js';

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
        <button class="sp-row" id="sp-logout">Sign out</button>
        <a class="sp-row" href="https://atlas-asittley.github.io/city-builder-mvp/" target="_blank" rel="noopener">Open v1 client (legacy)</a>
        <button class="sp-row" id="sp-clear">Clear cached data &amp; reload</button>
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
