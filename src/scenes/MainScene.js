// The real game scene. Reads from state.tileMap + state.allBuildings
// (populated by state/loader.js after auth) and renders them as
// Phaser sprites.
//
// Phase 1b scope: terrain + buildings drawn as colored rectangles,
// camera with pan/zoom, no inspector / build menu / walkers yet.
// Those land in subsequent phases.
import Phaser from 'phaser';
import { state } from '../state/store.js';

const TILE_PX = 48;

// Mapping from server terrain_type to a tint color. Tints are picked
// to feel like terrain rather than a tech demo. Wilderness (the
// default for unowned tiles) leans dark; owned grass is brighter.
const TERRAIN_TINTS = {
  grass: 0x3e5638,
  wilderness: 0x202820,
  water: 0x2a4a68,
  rock: 0x4a4a4a,
  forest: 0x2a3e22
};
const OWNED_GRASS_TINT = 0x4a6440;

// Per-category tint for buildings. As the asset pipeline matures
// we replace this with a sprite atlas keyed by building_type_key.
const CATEGORY_TINTS = {
  housing: 0x9a7a52,
  extractor: 0x6a8aa8,
  food_extractor: 0x6aa86a,
  processor: 0xa86a6a,
  service: 0xc8a868,
  police: 0x6a6aa8,
  tax: 0x8a8a3a,
  booster: 0xa868a8,
  park: 0x4a8a4a,
  road: 0x4a4538,
  transport_hub: 0x8a4a8a,
  transport_connector: 0x6a4a6a
};

export class MainScene extends Phaser.Scene {
  constructor() {
    super('MainScene');
  }

  preload() {
    // Solid white rectangle reused as the base for every sprite —
    // each instance gets its color via setTint(). Single-texture =
    // single draw call for the whole map.
    const g = this.add.graphics();
    g.fillStyle(0xffffff, 1);
    g.fillRect(0, 0, TILE_PX, TILE_PX);
    g.generateTexture('square', TILE_PX, TILE_PX);
    g.destroy();
  }

  create() {
    // If we got booted before data loaded (e.g., scene started by
    // Phaser's autostart), show a polite placeholder and return.
    if (!state.profile) {
      this.add.text(this.scale.width / 2, this.scale.height / 2,
        'Waiting for data…', {
          fontFamily: 'system-ui, sans-serif',
          fontSize: '14px',
          color: '#888'
        }).setOrigin(0.5);
      return;
    }

    this._renderTiles();
    this._renderBuildings();
    this._setupCamera();
    this._setupTopBar();
  }

  _renderTiles() {
    // Render every owned tile + a slightly larger frame of wilderness
    // tiles around it for context. For now we just render the owned
    // ones; wilderness will come when we add the build-placement
    // preview that needs to highlight reachable tiles.
    for (const k in state.tileMap) {
      const t = state.tileMap[k];
      const worldX = (t.x - state.gridMinX) * TILE_PX + TILE_PX / 2;
      const worldY = (t.y - state.gridMinY) * TILE_PX + TILE_PX / 2;

      let tint = TERRAIN_TINTS[t.terrain_type] || OWNED_GRASS_TINT;
      // Override grass with a brighter shade for owned tiles so the
      // player's parcel stands out.
      if (t.terrain_type === 'grass') tint = OWNED_GRASS_TINT;

      const sprite = this.add.sprite(worldX, worldY, 'square');
      sprite.setTint(tint);
    }
  }

  _renderBuildings() {
    // Buildings rendered by category color, scaled to footprint size.
    // Buildings from other players still show up (shared world) but
    // get a slightly desaturated treatment so it's visually clear
    // they're not yours.
    const myId = state.currentUser?.id;
    for (const b of state.allBuildings) {
      const bt = state.buildingTypes[b.building_type_key];
      if (!bt) continue;
      const fw = bt.footprint_w || 1;
      const fh = bt.footprint_h || 1;

      const worldX = (b.x - state.gridMinX) * TILE_PX + (fw * TILE_PX) / 2;
      const worldY = (b.y - state.gridMinY) * TILE_PX + (fh * TILE_PX) / 2;

      const tint = CATEGORY_TINTS[bt.category] || 0x888888;
      const sprite = this.add.sprite(worldX, worldY, 'square');
      sprite.setScale(fw - 0.15, fh - 0.15);   // tiny inset for grid visibility
      sprite.setTint(tint);
      // Other players' buildings: render at 65% alpha so yours pop.
      if (b.player_id !== myId) sprite.setAlpha(0.65);
    }
  }

  _setupCamera() {
    const worldW = state.gridCols * TILE_PX;
    const worldH = state.gridRows * TILE_PX;
    const cam = this.cameras.main;
    cam.setBounds(0, 0, worldW, worldH);
    cam.centerOn(worldW / 2, worldH / 2);

    // Drag-to-pan.
    this.input.on('pointermove', (pointer) => {
      if (!pointer.isDown) return;
      cam.scrollX -= (pointer.x - pointer.prevPosition.x) / cam.zoom;
      cam.scrollY -= (pointer.y - pointer.prevPosition.y) / cam.zoom;
    });

    // Wheel zoom (desktop).
    this.input.on('wheel', (_p, _o, _dx, dy) => {
      cam.setZoom(Phaser.Math.Clamp(cam.zoom * (dy > 0 ? 0.9 : 1.1), 0.25, 3));
    });

    // Mobile-friendly zoom buttons.
    const w = window.innerWidth, h = window.innerHeight;
    this._makeButton(w - 56, h - 56, '+', () =>
      cam.setZoom(Phaser.Math.Clamp(cam.zoom * 1.2, 0.25, 3)));
    this._makeButton(w - 56, h - 112, '−', () =>
      cam.setZoom(Phaser.Math.Clamp(cam.zoom * 0.83, 0.25, 3)));
    this._makeButton(w - 56, h - 168, '⟳', () => {
      cam.setZoom(1);
      cam.centerOn(worldW / 2, worldH / 2);
    });
  }

  _makeButton(x, y, label, onTap) {
    const size = 48;
    const bg = this.add.rectangle(x, y, size, size, 0x16213e, 0.85)
      .setStrokeStyle(1, 0x16c79a)
      .setScrollFactor(0)
      .setDepth(1000)
      .setInteractive({ useHandCursor: true });
    this.add.text(x, y, label, {
      fontFamily: 'system-ui, sans-serif',
      fontSize: '24px',
      color: '#16c79a'
    }).setOrigin(0.5).setScrollFactor(0).setDepth(1001);
    bg.on('pointerdown', (_p, _x, _y, event) => {
      onTap();
      if (event?.stopPropagation) event.stopPropagation();
    });
  }

  _setupTopBar() {
    const profile = state.profile;
    const cityLabel = state.cityName ? `${state.cityName} · ` : '';
    const text = `${cityLabel}${profile.display_name || 'Unnamed'}  ·  $${Math.floor(profile.money || 0)}  ·  pop ${Math.floor(profile.population || 0)}`;

    this.add.rectangle(0, 0, this.scale.width, 36, 0x0a0e14, 0.85)
      .setOrigin(0, 0)
      .setScrollFactor(0)
      .setDepth(1000);
    this.add.text(12, 10, text, {
      fontFamily: 'system-ui, sans-serif',
      fontSize: '13px',
      color: '#e6e6e6'
    }).setScrollFactor(0).setDepth(1001);
  }
}
