// Settings panel — sign out, link to the v1 client during the
// migration window, clear local cache. Triggered from the top bar's
// gear button.
import { sb } from '../api/supabase.js';
import { state, setCityName } from '../state/store.js';
import { openChangelog } from './ChangelogModal.js';
import { openHelp } from './HelpModal.js';
import { isAnimationsEnabled, setAnimationsEnabled } from './animations.js';
import { refreshTopBar } from './TopBar.js';

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
        <a class="sp-row" href="${import.meta.env.BASE_URL}codex.html" target="_blank" rel="noopener">🗺️ Design Codex <small>(industries, tree &amp; systems)</small></a>
        <button class="sp-row" id="sp-whats-new">What's new</button>
        <button class="sp-row sp-row-toggle" id="sp-anims" aria-pressed="false">
          <span>Animations</span>
          <span class="sp-toggle-state" id="sp-anims-state">ON</span>
        </button>
        <button class="sp-row" id="sp-rename-district">✏️ Rename your district</button>
        <button class="sp-row" id="sp-rename-city">✏️ Rename the city <small>(everyone sees it)</small></button>
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

  // Animations toggle — flips a body class that disables all CSS
  // animations + tweens. Useful on low-perf phones (v1's escape
  // hatch). Persisted in localStorage so the choice survives
  // reloads.
  const animsRow = document.getElementById('sp-anims');
  const animsState = document.getElementById('sp-anims-state');
  const renderAnimsState = () => {
    const enabled = isAnimationsEnabled();
    animsState.textContent = enabled ? 'ON' : 'OFF';
    animsRow.setAttribute('aria-pressed', enabled ? 'false' : 'true');
    animsRow.classList.toggle('sp-row-toggle-on', enabled);
    animsRow.classList.toggle('sp-row-toggle-off', !enabled);
  };
  renderAnimsState();
  animsRow.addEventListener('click', () => {
    setAnimationsEnabled(!isAnimationsEnabled());
    renderAnimsState();
  });

  document.getElementById('sp-whats-new').addEventListener('click', () => {
    overlay.remove();
    mounted = false;
    openChangelog();
  });

  document.getElementById('sp-rename-district').addEventListener('click', async () => {
    const current = state.profile?.district_name || '';
    const name = prompt('Rename your district', current);
    if (name == null) return;
    const trimmed = name.trim();
    if (trimmed.length < 2 || trimmed.length > 40) {
      alert('District name must be 2–40 characters.');
      return;
    }
    try {
      const { data, error } = await sb.rpc('rename_district', { p_name: trimmed });
      if (error) throw error;
      state.profile.district_name = data || trimmed;
      refreshTopBar();
      close();
    } catch (err) {
      alert('Rename failed: ' + (err.message || err));
    }
  });

  document.getElementById('sp-rename-city').addEventListener('click', async () => {
    const current = state.cityName || '';
    if (!confirm(`Rename the shared city? Every player will see the new name.\n\nCurrent: ${current || '(none)'}`)) return;
    const name = prompt('Rename the city (shared with every player)', current);
    if (name == null) return;
    const trimmed = name.trim();
    if (trimmed.length < 2 || trimmed.length > 40) {
      alert('City name must be 2–40 characters.');
      return;
    }
    try {
      const { data, error } = await sb.rpc('rename_city', { p_name: trimmed });
      if (error) throw error;
      setCityName(data || trimmed);
      refreshTopBar();
      close();
    } catch (err) {
      alert('Rename failed: ' + (err.message || err));
    }
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
