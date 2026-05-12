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
    if (desc.length < 5) {
      document.getElementById('bug-status').textContent = 'Please write at least a few words about what went wrong.';
      return;
    }
    const submitBtn = document.getElementById('bug-submit');
    submitBtn.disabled = true;
    submitBtn.textContent = 'Submitting…';

    // Client snapshot — minimal UI context the server can't see. The
    // RPC's server-side capture (full profile / inventory / buildings /
    // 50 recent cash_transactions / recent trader_visits) is what
    // Atlas actually queries via open_bug_reports + BUG_REPORTS.md, so
    // we keep client_state tight and let the server pull the heavy
    // forensic data.
    const clientState = {
      ts: new Date().toISOString(),
      ua: (navigator.userAgent || '').slice(0, 200),
      viewport: { w: window.innerWidth, h: window.innerHeight, dpr: window.devicePixelRatio || 1 },
      active_panel: document.querySelector('.bp-tab.active')?.dataset.tab || null,
      active_subtab: document.querySelector('.bp-subtab.active')?.dataset.sub || null,
      city_name: state.cityName,
      version: 'v2',
      recent_notifications: (state.notifications || []).slice(-10).map((n) => ({
        kind: n.kind, msg: n.message || null, at: n.created_at
      }))
    };

    try {
      const { error } = await sb.rpc('submit_bug_report', {
        p_description: desc,
        p_client_state: clientState
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
