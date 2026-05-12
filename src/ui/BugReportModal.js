// Bug report modal. Captures a textual description plus the full
// client_state + server_state snapshot at submit time, INSERTs into
// public.bug_reports so Atlas can diagnose later via the
// `open_bug_reports` view + BUG_REPORTS.md workflow.
import { sb } from '../api/supabase.js';
import { state } from '../state/store.js';

let mounted = false;

export function openBugReport() {
  if (mounted) return;
  mounted = true;

  const root = document.getElementById('ui-root');
  const overlay = document.createElement('div');
  overlay.id = 'bug-overlay';
  overlay.innerHTML = `
    <div class="bug-card">
      <div class="bug-header">
        <h2>🐞 Report a bug</h2>
        <button class="bug-close" aria-label="Close">×</button>
      </div>
      <p class="bug-hint">
        Describe what went wrong. We snapshot your current state (money,
        inventory, recent buildings, last-tick stats) so the dev can
        repro from your real game.
      </p>
      <textarea id="bug-desc" rows="6" placeholder="What happened? What did you expect?"></textarea>
      <div class="bug-actions">
        <button class="ip-btn" id="bug-cancel">Cancel</button>
        <button class="ip-btn ip-btn-primary" id="bug-submit">Submit report</button>
      </div>
      <p class="bug-status" id="bug-status"></p>
    </div>
  `;
  root.appendChild(overlay);

  const close = () => { overlay.remove(); mounted = false; };
  overlay.querySelector('.bug-close').addEventListener('click', close);
  overlay.querySelector('#bug-cancel').addEventListener('click', close);
  overlay.addEventListener('click', (e) => { if (e.target === overlay) close(); });

  document.getElementById('bug-submit').addEventListener('click', async () => {
    const desc = document.getElementById('bug-desc').value.trim();
    if (!desc) {
      document.getElementById('bug-status').textContent = 'Add a description first.';
      return;
    }
    const submitBtn = document.getElementById('bug-submit');
    submitBtn.disabled = true;
    submitBtn.textContent = 'Submitting…';

    const clientState = {
      profile: state.profile,
      inventory: state.inventory,
      laborInfo: state.laborInfo,
      cityName: state.cityName,
      url: window.location.href,
      userAgent: navigator.userAgent,
      capturedAt: new Date().toISOString(),
      version: 'v2'
    };
    const serverState = {
      currentUser: state.currentUser?.id,
      buildingCount: state.allBuildings?.length || 0,
      tileCount: Object.keys(state.tileMap || {}).length,
      gridBounds: { minX: state.gridMinX, minY: state.gridMinY, cols: state.gridCols, rows: state.gridRows }
    };

    try {
      const { error } = await sb.from('bug_reports').insert({
        player_id: state.currentUser.id,
        display_name: state.profile.display_name,
        description: desc,
        client_state: clientState,
        server_state: serverState
      });
      if (error) throw error;
      document.getElementById('bug-status').textContent = '✓ Submitted. Thanks!';
      setTimeout(close, 1200);
    } catch (err) {
      document.getElementById('bug-status').textContent = 'Submit failed: ' + (err.message || err);
      submitBtn.disabled = false;
      submitBtn.textContent = 'Submit report';
    }
  });
}
