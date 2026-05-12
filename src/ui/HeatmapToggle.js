// Heatmap mode picker — single button that opens a small popup
// of the 4 modes (matches v1 exactly). Tap a mode to switch; tap
// "— Off —" to clear.
//
// Modes:
//   pollution    — red tint scaled by tile.pollution
//   crime        — red on tiles outside any staffed police coverage
//   issues       — red on tiles under problematic buildings
//                  (idle / unstaffed / paused)
//   desirability — red < 30, green > 70, neutral middle
let mounted = false;
let currentMode = 'none';
let sceneRef = null;

const MODES = [
  { key: 'none',         label: '— Off —',          swatch: null },
  { key: 'pollution',    label: 'Pollution',        swatch: '#e85a3a' },
  { key: 'crime',        label: 'Crime risk',       swatch: '#c84878' },
  { key: 'issues',       label: 'Building issues',  swatch: '#f0a838' },
  { key: 'desirability', label: 'Desirability',     swatch: '#3ac860' }
];

export function mountHeatmapToggle(scene) {
  sceneRef = scene;
  if (mounted) return;
  const root = document.getElementById('ui-root');

  const btn = document.createElement('button');
  btn.id = 'heatmap-toggle';
  btn.className = 'zc-btn';
  btn.textContent = '🗺';
  btn.title = 'Heatmap overlays';
  root.appendChild(btn);

  const popup = document.createElement('div');
  popup.id = 'heatmap-popup';
  popup.innerHTML = `
    <div class="hp-title">Heatmap</div>
    ${MODES.map((m) => `
      <button class="hp-option" data-mode="${m.key}">
        ${m.swatch ? `<span class="hp-swatch" style="background:${m.swatch};"></span>` : '<span class="hp-swatch hp-swatch-empty"></span>'}
        ${m.label}
      </button>
    `).join('')}
  `;
  root.appendChild(popup);

  mounted = true;

  btn.addEventListener('click', (e) => {
    popup.classList.toggle('open');
    e.stopPropagation();
  });
  document.addEventListener('click', (e) => {
    if (!e.target.closest('#heatmap-popup') && !e.target.closest('#heatmap-toggle')) {
      popup.classList.remove('open');
    }
  });

  popup.querySelectorAll('.hp-option').forEach((option) => {
    option.addEventListener('click', () => {
      const mode = option.dataset.mode;
      currentMode = mode;
      popup.classList.remove('open');
      btn.classList.toggle('zc-btn-active', mode !== 'none');
      if (sceneRef?.setHeatmapMode) sceneRef.setHeatmapMode(mode === 'none' ? 'normal' : mode);
    });
  });
}

export function getHeatmapMode() { return currentMode; }
