// Top bar — fixed strip across the top of the screen showing the
// city name, player name, money, population, and happiness. Updates
// reactively from state; called after every tick and any other event
// that might have changed the headline numbers.
//
// Lives in #ui-root (DOM overlay) rather than inside the Phaser
// scene because (a) it's text, which DOM does fluently and Phaser
// has to fake, and (b) we want to update it without touching the
// canvas.
import { state } from '../state/store.js';

let mounted = false;

export function mountTopBar() {
  if (mounted) return;
  const root = document.getElementById('ui-root');
  const bar = document.createElement('div');
  bar.id = 'topbar';
  bar.innerHTML = `
    <div class="topbar-left">
      <span class="tb-city" id="tb-city"></span>
      <span class="tb-name" id="tb-name"></span>
    </div>
    <div class="topbar-right">
      <span class="tb-chip" id="tb-money"></span>
      <span class="tb-chip" id="tb-pop"></span>
      <span class="tb-chip" id="tb-happy"></span>
    </div>
  `;
  root.appendChild(bar);
  mounted = true;
  refreshTopBar();
}

export function unmountTopBar() {
  const el = document.getElementById('topbar');
  if (el) el.remove();
  mounted = false;
}

export function refreshTopBar() {
  if (!mounted || !state.profile) return;
  const p = state.profile;
  document.getElementById('tb-city').textContent = state.cityName ? state.cityName + ' · ' : '';
  document.getElementById('tb-name').textContent = p.display_name || '(unnamed)';
  document.getElementById('tb-money').textContent = '$' + Math.floor(p.money || 0).toLocaleString();
  document.getElementById('tb-pop').textContent = '👥 ' + Math.floor(p.population || 0);
  document.getElementById('tb-happy').textContent = '😊 ' + Math.round((p.happiness || 0));
}
