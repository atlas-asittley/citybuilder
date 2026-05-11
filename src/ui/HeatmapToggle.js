// Heatmap mode toggle — bottom-right floating button that cycles
// through Normal / Pollution / Desirability. Mirrors v1's mode
// selector but as a single tap-to-cycle button (less UI for the
// same gameplay value).
//
// When mode changes, calls the scene's setHeatmapMode() which
// rebuilds the tile tints.
let mounted = false;
let currentMode = 'normal';
let sceneRef = null;

const MODES = ['normal', 'pollution', 'desirability'];
const LABELS = {
  normal: 'Map',
  pollution: 'Pollution',
  desirability: 'Desirability'
};

export function mountHeatmapToggle(scene) {
  sceneRef = scene;
  if (mounted) return;
  const root = document.getElementById('ui-root');
  const btn = document.createElement('button');
  btn.id = 'heatmap-toggle';
  btn.className = 'zc-btn';
  btn.textContent = LABELS[currentMode];
  root.appendChild(btn);
  mounted = true;

  btn.addEventListener('click', () => {
    const i = MODES.indexOf(currentMode);
    currentMode = MODES[(i + 1) % MODES.length];
    btn.textContent = LABELS[currentMode];
    btn.classList.toggle('zc-btn-active', currentMode !== 'normal');
    if (sceneRef?.setHeatmapMode) sceneRef.setHeatmapMode(currentMode);
  });
}

export function getHeatmapMode() { return currentMode; }
