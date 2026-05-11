// Phase 0 perf sandbox. Goal: prove that a Phaser/WebGL scene with
// roughly the entity count of a busy v1 city (~500 buildings + ~100
// walkers on a 50x50 map) runs at 60 fps on Atlas's phone, before
// we commit to the full migration.
//
// Everything here is throwaway — solid-color rectangles, random
// motion, no game logic. Once Atlas confirms perf on real hardware
// this scene gets replaced with the real map renderer.
import Phaser from 'phaser';

const GRID_W = 50;
const GRID_H = 50;
const TILE_PX = 48;
const NUM_BUILDINGS = 500;
const NUM_WALKERS = 150;

// Pleasant earthy palette so it looks like terrain rather than a
// checkerboard. Each tile picks one of these on init and keeps it.
const TILE_COLORS = [0x3a4a2a, 0x4a5a36, 0x556640, 0x40503a, 0x36462c];
const BUILDING_COLORS = [0x8a6a4a, 0x9a7a52, 0x7a5a40, 0xb08858, 0x6a4f38];
const WALKER_COLOR = 0xe0d090;

export class SandboxScene extends Phaser.Scene {
  constructor() {
    super('SandboxScene');
  }

  preload() {
    // Generate textures programmatically. No asset files needed for
    // the perf test — Phaser's Graphics renders to a texture once,
    // then the actual scene only uses Sprite instances which are
    // GPU-batched. This is the same shape the real game will use
    // (one texture atlas, many sprite instances).
    this._makeRectTexture('tile', TILE_PX, TILE_PX, 0xffffff, 0x000000, 0);
    this._makeRectTexture('building', TILE_PX - 8, TILE_PX - 8, 0xffffff, 0x222222, 1);
    this._makeRectTexture('walker', 10, 10, WALKER_COLOR, 0x000000, 0);
  }

  _makeRectTexture(key, w, h, fill, stroke, strokeWidth) {
    const g = this.add.graphics({ x: 0, y: 0 });
    g.fillStyle(fill, 1);
    g.fillRect(0, 0, w, h);
    if (strokeWidth > 0) {
      g.lineStyle(strokeWidth, stroke, 1);
      g.strokeRect(0, 0, w, h);
    }
    g.generateTexture(key, w, h);
    g.destroy();
  }

  create() {
    const worldW = GRID_W * TILE_PX;
    const worldH = GRID_H * TILE_PX;

    // ── Terrain tiles ──
    // Plain Sprite instances tinted from the palette. Phaser batches
    // sprites that share a texture into a single draw call, so 2,500
    // terrain tiles is one draw.
    for (let gx = 0; gx < GRID_W; gx++) {
      for (let gy = 0; gy < GRID_H; gy++) {
        const tile = this.add.sprite(gx * TILE_PX + TILE_PX / 2, gy * TILE_PX + TILE_PX / 2, 'tile');
        tile.setTint(TILE_COLORS[(gx * 7 + gy * 13) % TILE_COLORS.length]);
      }
    }

    // ── Buildings ──
    // Randomly placed on the grid, tinted from the palette. Each is
    // a single sprite — same texture as tile, just a different tint.
    // (Real game would use a texture atlas with distinct sprites per
    // building type — same draw-call story.)
    const occupied = new Set();
    for (let i = 0; i < NUM_BUILDINGS; i++) {
      let gx, gy, key;
      do {
        gx = Phaser.Math.Between(0, GRID_W - 1);
        gy = Phaser.Math.Between(0, GRID_H - 1);
        key = gx + ',' + gy;
      } while (occupied.has(key));
      occupied.add(key);

      const b = this.add.sprite(gx * TILE_PX + TILE_PX / 2, gy * TILE_PX + TILE_PX / 2, 'building');
      b.setTint(BUILDING_COLORS[Phaser.Math.Between(0, BUILDING_COLORS.length - 1)]);
    }

    // ── Walkers ──
    // Small sprites moving randomly. Each gets a velocity assigned
    // once; we just integrate position every frame in update(). No
    // physics body — we don't need collision, just motion.
    this.walkers = [];
    for (let i = 0; i < NUM_WALKERS; i++) {
      const w = this.add.sprite(
        Phaser.Math.Between(0, worldW),
        Phaser.Math.Between(0, worldH),
        'walker'
      );
      w.vx = Phaser.Math.FloatBetween(-40, 40);
      w.vy = Phaser.Math.FloatBetween(-40, 40);
      this.walkers.push(w);
    }

    // ── Camera + input ──
    this.cameras.main.setBounds(0, 0, worldW, worldH);
    this.cameras.main.centerOn(worldW / 2, worldH / 2);

    // Drag-to-pan. pointermove fires while a finger / mouse button
    // is down on the canvas.
    this.input.on('pointermove', (pointer) => {
      if (!pointer.isDown) return;
      const cam = this.cameras.main;
      cam.scrollX -= (pointer.x - pointer.prevPosition.x) / cam.zoom;
      cam.scrollY -= (pointer.y - pointer.prevPosition.y) / cam.zoom;
    });

    // Wheel-to-zoom for desktop testing. Mobile uses the buttons (see
    // below) — pinch-zoom is intentionally not bound here because
    // browser-level pinch is fighting us anyway and the buttons are
    // a clearer affordance.
    this.input.on('wheel', (_pointer, _objs, _dx, dy) => {
      const cam = this.cameras.main;
      const next = Phaser.Math.Clamp(cam.zoom * (dy > 0 ? 0.9 : 1.1), 0.25, 3);
      cam.setZoom(next);
    });

    // ── FPS + entity counter overlay ──
    // Lives on a separate, fixed camera so it doesn't pan/zoom with
    // the world. This is the metric Atlas needs to see when testing
    // on his phone.
    this.fpsText = this.add.text(12, 12, '', {
      fontFamily: 'system-ui, sans-serif',
      fontSize: '14px',
      color: '#16c79a',
      backgroundColor: 'rgba(0,0,0,0.6)',
      padding: { x: 8, y: 6 }
    });
    this.fpsText.setScrollFactor(0).setDepth(1000);

    // ── Zoom buttons (mobile-friendly) ──
    this._makeButton(window.innerWidth - 56, window.innerHeight - 56, '+', () => {
      const cam = this.cameras.main;
      cam.setZoom(Phaser.Math.Clamp(cam.zoom * 1.2, 0.25, 3));
    });
    this._makeButton(window.innerWidth - 56, window.innerHeight - 112, '−', () => {
      const cam = this.cameras.main;
      cam.setZoom(Phaser.Math.Clamp(cam.zoom * 0.83, 0.25, 3));
    });
    this._makeButton(window.innerWidth - 56, window.innerHeight - 168, '⟳', () => {
      this.cameras.main.setZoom(1);
      this.cameras.main.centerOn(worldW / 2, worldH / 2);
    });

    // ── Description text ──
    const desc = this.add.text(12, window.innerHeight - 56,
      `${GRID_W * GRID_H} tiles · ${NUM_BUILDINGS} buildings · ${NUM_WALKERS} walkers — drag to pan, +/− to zoom`, {
      fontFamily: 'system-ui, sans-serif',
      fontSize: '11px',
      color: '#888',
      backgroundColor: 'rgba(0,0,0,0.6)',
      padding: { x: 8, y: 4 }
    });
    desc.setScrollFactor(0).setDepth(1000);

    this._worldW = worldW;
    this._worldH = worldH;
  }

  _makeButton(x, y, label, onTap) {
    const size = 48;
    const bg = this.add.rectangle(x, y, size, size, 0x16213e, 0.85)
      .setStrokeStyle(1, 0x16c79a)
      .setScrollFactor(0)
      .setDepth(1000)
      .setInteractive({ useHandCursor: true });
    const txt = this.add.text(x, y, label, {
      fontFamily: 'system-ui, sans-serif',
      fontSize: '24px',
      color: '#16c79a'
    }).setOrigin(0.5).setScrollFactor(0).setDepth(1001);

    // Phaser's hit events fire on the rectangle; we treat the whole
    // (rect + label) as the button. stopPropagation prevents the tap
    // from also kicking the camera pan handler.
    bg.on('pointerdown', (_p, _x, _y, event) => {
      onTap();
      if (event && event.stopPropagation) event.stopPropagation();
    });
    // Keep label aligned if buttons move on resize (not wired yet
    // but cheap to keep in lockstep).
    txt.parentButton = bg;
  }

  update(_time, delta) {
    // Walker motion. Reflect off bounds. Cheap per-entity work;
    // Phaser's renderer batches all walker sprites into one draw.
    const dt = delta / 1000;
    for (let i = 0; i < this.walkers.length; i++) {
      const w = this.walkers[i];
      w.x += w.vx * dt;
      w.y += w.vy * dt;
      if (w.x < 0 || w.x > this._worldW) w.vx = -w.vx;
      if (w.y < 0 || w.y > this._worldH) w.vy = -w.vy;
    }

    // FPS readout — sampled every frame, smoothed by the engine.
    const fps = Math.round(this.game.loop.actualFps);
    this.fpsText.setText(
      `${fps} FPS · ${this.children.length} display objects · zoom ${this.cameras.main.zoom.toFixed(2)}`
    );
  }
}
