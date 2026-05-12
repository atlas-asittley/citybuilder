// Tiny version badge anchored bottom-right. Carries the build hash
// (from Vite's asset filename) so Atlas can tell at a glance which
// deploy a player is on. Triple-tap fires a cache-bust reload —
// same gesture as v1's badge.
//
// Vite hashes asset filenames per build; we read the <script>'s src
// to extract the hash.
let mounted = false;
let tapCount = 0;
let tapTimer = null;

export function mountVersionBadge() {
  if (mounted) return;
  const badge = document.createElement('div');
  badge.id = 'version-badge';
  badge.textContent = detectBuildId();
  badge.title = 'Triple-tap for a cache-bust reload';
  document.getElementById('ui-root').appendChild(badge);
  mounted = true;

  badge.addEventListener('click', () => {
    tapCount++;
    if (tapTimer) clearTimeout(tapTimer);
    if (tapCount >= 3) {
      tapCount = 0;
      const u = new URL(window.location.href);
      u.searchParams.set('_t', Date.now().toString());
      window.location.href = u.toString();
      return;
    }
    tapTimer = setTimeout(() => { tapCount = 0; }, 600);
  });
}

function detectBuildId() {
  const scripts = document.querySelectorAll('script[src*="/assets/"]');
  for (const s of scripts) {
    const m = s.getAttribute('src')?.match(/index-([A-Za-z0-9_-]{6,})\./);
    if (m) return 'v2 · ' + m[1].slice(0, 7);
  }
  return 'v2 · dev';
}
