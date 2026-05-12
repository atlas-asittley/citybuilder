// Zoom + / − buttons as DOM elements. Originally I'd placed these as
// Phaser objects with setScrollFactor(0), but that only pins them
// against camera SCROLL — the camera's ZOOM still scales them, so
// they'd grow huge at high zoom. DOM elements live outside Phaser's
// transform, so they're truly fixed.
//
// (Reset button was here too — dropped 2026-05-13 per Atlas's call:
// the saved scroll/zoom restore + double-tap-to-reset gestures cover
// the "go home" use case without spending a button slot.)
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
