// The real game scene. Reads from state.tileMap + state.allBuildings
// (populated by state/loader.js after auth) and renders them as
// Phaser sprites.
//
// Phase 1b scope: terrain + buildings drawn as colored rectangles,
// camera with pan/zoom, no inspector / build menu / walkers yet.
// Those land in subsequent phases.
import Phaser from 'phaser';
import { state } from '../state/store.js';
import { openInspector, closeInspector } from '../ui/InspectorPanel.js';
import { placeBuilding } from '../api/buildings.js';
import { clearSelection as clearBuildSelection } from '../ui/BuildMenu.js';

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

  create() {
    // Safety net: the scene is only registered as autoStart=false in
    // main.js, so this branch shouldn't fire in normal flow. If it
    // does, surface the cause loudly rather than displaying a vague
    // "waiting…" message that hides the real bug.
    if (!state.profile) {
      console.error('MainScene started without state.profile — main.js lifecycle bug');
      this.add.text(this.scale.width / 2, this.scale.height / 2,
        'Scene started before data loaded — check console.', {
          fontFamily: 'system-ui, sans-serif',
          fontSize: '13px',
          color: '#e94560'
        }).setOrigin(0.5);
      return;
    }

    // Generate the shared white-square texture every sprite reuses.
    // Done in create() (not preload) because Phaser's preload phase
    // is for async asset loads; in-place graphics belong in create.
    if (!this.textures.exists('square')) {
      const g = this.add.graphics();
      g.fillStyle(0xffffff, 1);
      g.fillRect(0, 0, TILE_PX, TILE_PX);
      g.generateTexture('square', TILE_PX, TILE_PX);
      g.destroy();
    }

    // Map from "x,y" anchor → building, so a tap on any cell can
    // find the building (multi-tile buildings register their anchor).
    this._buildingAtAnchor = new Map();
    this._placementMode = null;   // { buildingType, ghostSprite }

    this._renderTiles();
    this._renderBuildings();
    this._setupCamera();
    this._setupTapToInspect();
  }

  // Called by BuildMenu when the player picks a building type to
  // place. Pass null to cancel placement.
  setPlacementMode(buildingType) {
    // Tear down any prior ghost.
    if (this._placementMode?.ghostSprite) {
      this._placementMode.ghostSprite.destroy();
    }
    if (!buildingType) {
      this._placementMode = null;
      return;
    }
    const fw = buildingType.footprint_w || 1;
    const fh = buildingType.footprint_h || 1;
    const ghost = this.add.sprite(0, 0, 'square');
    ghost.setScale(fw - 0.15, fh - 0.15);
    ghost.setTint(0x16c79a);
    ghost.setAlpha(0.55);
    ghost.setDepth(900);
    this._placementMode = { buildingType, ghostSprite: ghost, fw, fh };
  }

  // Expose a re-render hook for the tick / realtime layers — they
  // call this when state.allBuildings changes. Cheap because we
  // rebuild only the sprite list; the camera + texture stay put.
  rerenderBuildings() {
    if (!this._buildingSprites) return;
    for (const s of this._buildingSprites) s.destroy();
    this._buildingSprites = [];
    this._buildingAtAnchor.clear();
    this._renderBuildings();
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
    this._buildingSprites = this._buildingSprites || [];
    for (const b of state.allBuildings) {
      const bt = state.buildingTypes[b.building_type_key];
      if (!bt) continue;
      const fw = bt.footprint_w || 1;
      const fh = bt.footprint_h || 1;

      const worldX = (b.x - state.gridMinX) * TILE_PX + (fw * TILE_PX) / 2;
      const worldY = (b.y - state.gridMinY) * TILE_PX + (fh * TILE_PX) / 2;

      const tint = CATEGORY_TINTS[bt.category] || 0x888888;
      const sprite = this.add.sprite(worldX, worldY, 'square');
      sprite.setScale(fw - 0.15, fh - 0.15);
      sprite.setTint(tint);
      if (b.player_id !== myId) sprite.setAlpha(0.65);

      // Make the sprite hit-testable so we can route taps back to
      // the building. setInteractive() with no args uses the sprite
      // bounds; that's fine for a rectangle.
      sprite.setInteractive({ useHandCursor: true });
      sprite.buildingRef = b;

      this._buildingSprites.push(sprite);
      this._buildingAtAnchor.set(b.x + ',' + b.y, b);
    }
  }

  _setupCamera() {
    const worldW = state.gridCols * TILE_PX;
    const worldH = state.gridRows * TILE_PX;
    // Expose world dims for ZoomControls' reset button.
    this._worldW = worldW;
    this._worldH = worldH;

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
    // Mobile zoom UI lives in DOM (ZoomControls.js) so it isn't
    // affected by the camera's zoom transform.
  }

  _setupTapToInspect() {
    // Differentiate tap from drag-pan: if the pointer moved more than
    // a few pixels between down and up, it was a drag; otherwise a
    // tap. Only taps trigger inspector or placement.
    let downX = 0, downY = 0, downAtMs = 0;
    this.input.on('pointerdown', (p) => {
      downX = p.x; downY = p.y; downAtMs = performance.now();
    });

    // Ghost sprite follows the cursor when placement mode is active.
    // Snap to the tile grid so the player can see exactly where the
    // building will land.
    this.input.on('pointermove', (p) => {
      if (!this._placementMode) return;
      const world = this.cameras.main.getWorldPoint(p.x, p.y);
      const gx = Math.floor(world.x / TILE_PX);
      const gy = Math.floor(world.y / TILE_PX);
      const { fw, fh, ghostSprite } = this._placementMode;
      ghostSprite.x = gx * TILE_PX + (fw * TILE_PX) / 2;
      ghostSprite.y = gy * TILE_PX + (fh * TILE_PX) / 2;
    });

    this.input.on('pointerup', async (p, currentlyOver) => {
      const dx = p.x - downX, dy = p.y - downY;
      const moved = Math.hypot(dx, dy);
      const heldMs = performance.now() - downAtMs;
      if (moved > 8 || heldMs > 500) return;

      // Placement mode: tap = try to place the building here.
      if (this._placementMode) {
        const world = this.cameras.main.getWorldPoint(p.x, p.y);
        const gx = Math.floor(world.x / TILE_PX) + state.gridMinX;
        const gy = Math.floor(world.y / TILE_PX) + state.gridMinY;
        const tile = state.tileMap[gx + ',' + gy];
        if (!tile) {
          alert("That tile isn't in your parcel.");
          return;
        }
        const btKey = this._placementMode.buildingType.key;
        try {
          await placeBuilding(tile.id, btKey);
          // Realtime sub will pick up the INSERT and re-render.
          // Exit placement mode after a successful place so the
          // player can pan / inspect again.
          this.setPlacementMode(null);
          clearBuildSelection();
        } catch (err) {
          alert(err.message || 'Could not place building.');
        }
        return;
      }

      // Inspect mode (default): tap on a building → open inspector.
      if (currentlyOver && currentlyOver.length > 0) {
        for (const obj of currentlyOver) {
          if (obj.buildingRef) {
            openInspector(obj.buildingRef);
            return;
          }
        }
      }
      closeInspector();
    });
  }
}
