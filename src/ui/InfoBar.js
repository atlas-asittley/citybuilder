// Info-bar — thin strip directly below the topbar carrying:
//   Industry: <tag>
//   Player display name
//   🐞 Report bug button
//
// v1 puts industry and bug-report here so the topbar can stay
// focused on numeric stats. The tag style + button style come from
// v1's CSS.
import { state } from '../state/store.js';
import { openBugReport } from './BugReportModal.js';

let mounted = false;

export function mountInfoBar() {
  if (mounted) return;
  const root = document.getElementById('ui-root');
  const bar = document.createElement('div');
  bar.id = 'infobar';
  bar.innerHTML = `
    <span class="ib-left">
      <span class="ib-label">Industry:</span>
      <span class="ib-tag" id="ib-industry">—</span>
    </span>
    <span class="ib-name" id="ib-name"></span>
    <button class="ib-bug" id="ib-bug-report" title="Report a bug — captures your current state for forensics">🐞 Report bug</button>
  `;
  root.appendChild(bar);
  mounted = true;

  document.getElementById('ib-bug-report').addEventListener('click', openBugReport);
  refreshInfoBar();
}

export function refreshInfoBar() {
  if (!mounted || !state.profile) return;
  document.getElementById('ib-industry').textContent = state.profile.industry_key || '—';
  document.getElementById('ib-name').textContent = state.profile.display_name || '';
}

export function unmountInfoBar() {
  const el = document.getElementById('infobar');
  if (el) el.remove();
  mounted = false;
}
