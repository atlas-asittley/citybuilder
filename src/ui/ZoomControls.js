// Zoom +/-/reset buttons as DOM elements. Originally I'd placed
// these as Phaser objects with setScrollFactor(0), but that only
// pins them against camera SCROLL — the camera's ZOOM still scales
// them, so they'd grow huge at high zoom (Atlas 2026-05-11: "when
// I press the zoom buttons, it actually zooms into the zoom button
// itself as well"). DOM elements live outside Phaser's transform,
// so they're truly fixed.
import Phaser from 'phaser';

let mounted = false;
let sceneRef = null;

const Z_MIN = 0.25;
const Z_MAX = 3;

export function mountZoomControls(scene) {
  sceneRef = scene;
  if (mounted) return;
  const root = document.getElementById('ui-root');
  const ctrls = document.createElement('div');
  ctrls.id = 'zoom-controls';
  ctrls.innerHTML = `
    <button class="zc-btn" data-act="in" aria-label="Zoom in">+</button>
    <button class="zc-btn" data-act="out" aria-label="Zoom out">−</button>
    <button class="zc-btn" data-act="reset" aria-label="Reset zoom">⟳</button>
  `;
  root.appendChild(ctrls);
  mounted = true;

  ctrls.querySelectorAll('.zc-btn').forEach((btn) => {
    btn.addEventListener('click', (e) => {
      if (!sceneRef) return;
      const cam = sceneRef.cameras.main;
      const act = btn.dataset.act;
      if (act === 'in') cam.setZoom(Phaser.Math.Clamp(cam.zoom * 1.2, Z_MIN, Z_MAX));
      else if (act === 'out') cam.setZoom(Phaser.Math.Clamp(cam.zoom * 0.83, Z_MIN, Z_MAX));
      else if (act === 'reset') {
        cam.setZoom(1);
        const worldW = sceneRef._worldW || 0;
        const worldH = sceneRef._worldH || 0;
        if (worldW && worldH) cam.centerOn(worldW / 2, worldH / 2);
      }
      sceneRef._saveMapViewSoon?.();
      e.stopPropagation();
    });
  });
}

export function unmountZoomControls() {
  const el = document.getElementById('zoom-controls');
  if (el) el.remove();
  mounted = false;
  sceneRef = null;
}
