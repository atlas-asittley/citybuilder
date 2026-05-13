// The main game scene. Reads from state.tileMap + state.allBuildings
// (populated by state/loader.js after auth) and renders them as
// Phaser sprites. Handles input: drag-pan, wheel-zoom, tap to
// inspect, tap-to-place / drag-paint roads in placement mode, and
// inspector AoE highlights.
import Phaser from 'phaser';
import { state } from '../state/store.js';
import { openInspector, closeInspector } from '../ui/InspectorPanel.js';
import { openResourceTileInspector } from '../ui/ResourceTileInspector.js';
import { openWalkerInfo, tagWalkerSpriteKind } from '../ui/WalkerInfoModal.js';
import { placeBuilding } from '../api/buildings.js';
import { clearBuildTabSelection as clearBuildSelection } from '../ui/bottompanel/BuildTabPanel.js';
import { spriteIcons } from '../sprites.js';
import { WALKER_SPRITES } from '../walker_sprites.js';
import { showToast } from '../ui/Toast.js';
import { showPlacementBar, hidePlacementBar, showDragCost, hideDragCost } from '../ui/PlacementBar.js';
import {
  buildingSignature,
  resourceKindFor,
  pickWalkerVariant,
  getBuildingAoeRange,
  heatmapTintFor,
  computeWorldBounds as _computeWorldBounds,
  sizeWalkerSvg,
  computePoliceCoverage as _computePoliceCoverage,
  computeProblemTiles as _computeProblemTiles,
  computeBuildingIssue,
  tileHash
} from './helpers.js';

const TILE_PX = 48;
// Walker cap scales with population to keep big cities feeling
// populated without overwhelming small ones. v1 formula was
// floor(pop / 10) capped at 80; v2 lowers the cap to 60 because
// Phaser sprites are still a per-frame cost even when offscreen-
// pause is on. Floor of 12 so a fresh city always has some life.
const WALKER_CAP_MIN = 12;
const WALKER_CAP_MAX = 60;
const WALKER_SPAWN_MS = 800;

function maxWalkers() {
  // state import is local to file — function reads through it lazily.
  const pop = Math.floor(state.profile?.population || 0);
  return Math.max(WALKER_CAP_MIN, Math.min(WALKER_CAP_MAX, Math.floor(pop / 10)));
}
// v1 displayed walkers at 10×14 px on a 34px tile (~30% of tile).
// v2's tile is TILE_PX=48 so the proportional size is ~14×20. Phaser
// rasterizes the SVG at whatever the browser's default svg→image
// size is (much larger), so setDisplaySize keeps them legible.
const WALKER_PX_W = 14;
const WALKER_PX_H = 20;

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

// World bounds (state-bound wrapper around the pure helper).
function computeWorldBounds() {
  return _computeWorldBounds(state.tileMap, state.allBuildings);
}

// Building animations. Mirror v1's CSS pseudo-element effects but as
// Phaser sprites + tweens. Gated on (status='active' AND is_staffed)
// — idle / unstaffed buildings should look quiet, not smoking.
//
// Profile shape:
//   { smoke?: true, glow?: <tint hex> }
//
// Looked up first by building_type_key (specific overrides), then by
// bt.category (category default). null/missing = no animation.
const BUILDING_ANIM_PROFILES = {
  // Specific keys with distinctive looks
  // Kept glow on actual-fire / forge buildings only. Dropped on
  // admin offices + brewery + toolmaker where the in-fiction
  // rationale was thin (a desk lamp doesn't justify a full-tile
  // pulsing wash).
  smelter:        { smoke: true, glow: 0xff7028 },
  glassworks:     { smoke: true, glow: 0xffc858 },
  iron_mine:      { glow: 0xffa040 },
  mine_office:    {},
  foreman_office: {},
  charcoal_kiln:  { smoke: true },
  lime_kiln:      { smoke: true },
  pottery_kiln:   { smoke: true, glow: 0xff8848 },
  bakery:         { smoke: true },
  brewery:        {},
  distillery:     { smoke: true, glow: 0xffa848 },
  smokehouse:     { smoke: true },
  cannery:        { smoke: true },
  watch_house:    { glow: 0xfff088 },
  mill:           { smoke: true },
  sawmill:        { smoke: true },
  mason_workshop: { smoke: true },
  tile_maker:     { smoke: true, glow: 0xff8848 },
  spicery:        { smoke: true },
  curing_house:   { smoke: true },
  nail_forge:     { smoke: true, glow: 0xff7028 },
  toolmaker:      {},

  // Services + police — small bobbing figure on top of the building
  // (a citizen / officer / priest going about their work). Same
  // pattern as smoke, just a single sprite tweening up-down instead
  // of a three-puff plume.
  well:           { figure: 0xa0c0e0 },
  school:         { figure: 0xa07050 },
  temple:         { figure: 0xa89870 },
  bathhouse:      { figure: 0x587088 },
  tavern:         { figure: 0x9a5028 },
  tax_man:        { figure: 0x8a8a3a },
  watch_house:    { glow: 0xfff088, figure: 0x2a3a5a },
  police_station: { figure: 0x2a3a5a },
  constabulary:   { figure: 0x1a2a48 }
};

// AoE highlight color per kind. Mirrors v1's per-kind .aoe-<kind> CSS.
const AOE_TINTS = {
  police: 0x4060a0,
  park: 0x4a8a4a,
  booster: 0xa868a8,
  well: 0x70a0c0,
  school: 0xa07050,
  temple: 0xa89870,
  bathhouse: 0x587088
};


export class MainScene extends Phaser.Scene {
  constructor() {
    super('MainScene');
  }

  preload() {
    // Queue every building sprite. Each value in `spriteIcons` is a
    // data:image/svg+xml URI which Phaser's loader handles natively.
    // We use the building_type_key as the texture key so render code
    // can look it up directly with no extra mapping table.
    for (const key in spriteIcons) {
      // Skip if already loaded (scene.restart() re-runs preload).
      if (this.textures.exists(key)) continue;
      this.load.image(key, spriteIcons[key]);
    }
    // Walker variants — 19 detailed humanoid sprites lifted from v1.
    // Keyed 'walker-citizen', 'walker-timber', etc.
    //
    // The source SVGs have a viewBox but no explicit width/height,
    // so the browser rasterizes them at its default surface size
    // (~300px) which blows up texture memory on a city with ~80
    // active walkers (Atlas 2026-05-11: "started to lag a little bit
    // with those walkers"). Inject width/height = 4× viewBox so the
    // browser rasterizes at a small but supersampled size — crisp
    // when displayed at the final ~14×20.
    for (const key in WALKER_SPRITES) {
      const texKey = 'walker-' + key;
      if (this.textures.exists(texKey)) continue;
      this.load.image(texKey, sizeWalkerSvg(WALKER_SPRITES[key]));
    }
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
    // Per-resource-kind icons drawn as small graphics into named
    // textures, so resource tiles read at a glance instead of looking
    // like generic colored dots (Atlas 2026-05-11). Sized so a tile
    // shows the icon plus the underlying terrain color.
    this._ensureResourceIconTextures();
    // Fallback walker texture used by code paths that don't pick a
    // specific variant (e.g., bare 'walker' key). The v1 SVG citizen
    // is loaded as 'walker-citizen' in preload; alias 'walker' to
    // the same image so any sprite created with key 'walker' gets
    // the detailed sprite. textures.addImage clones the source.
    if (!this.textures.exists('walker') && this.textures.exists('walker-citizen')) {
      this.textures.addImage('walker', this.textures.get('walker-citizen').getSourceImage());
    }
    // Soft white puff for chimney smoke — radial gradient faked with
    // two stacked circles since Phaser's Graphics doesn't do gradients.
    if (!this.textures.exists('puff')) {
      const g = this.add.graphics();
      g.fillStyle(0xffffff, 0.2);
      g.fillCircle(12, 12, 12);
      g.fillStyle(0xffffff, 0.6);
      g.fillCircle(12, 12, 6);
      g.generateTexture('puff', 24, 24);
      g.destroy();
    }

    // Road autotile — 16 textures, one per NSEW connectivity bitmask
    // (n=8, s=4, e=2, w=1). Cheap to pre-generate; lookup per tile is
    // O(1). Renders a dirt road body with arms extending toward
    // neighboring roads and shoulders blending into the grass.
    this._ensureRoadTextures();

    // Map from "x,y" anchor → building, so a tap on any cell can
    // find the building (multi-tile buildings register their anchor).
    this._buildingAtAnchor = new Map();
    this._placementMode = null;   // { buildingType, ghostSprite, fw, fh }
    this._aoeOverlays = [];       // sprites for the inspector AoE highlight
    this._heatmapOverlays = [];   // sprites for the active heatmap layer
    this._heatmapMode = 'normal';
    this._dragPaintActive = false;
    this._dragPaintPlaced = new Set();
    this._tileSprites = new Map(); // "x,y" → tile sprite, for re-tint on tick

    this._renderTiles();
    this._renderBuildings();
    this._setupCamera();
    this._setupTapToInspect();
    this._setupWalkers();
  }

  // Cosmetic walker simulation. Every WALKER_SPAWN_MS, pick a random
  // staffed building owned by the current player and spawn a small
  // colored circle at that building. Each walker has a target
  // position (a few tiles away in a random direction) and a constant
  // velocity. When it reaches the target — or after a lifetime cap —
  // it despawns. Capped at MAX_WALKERS so a busy city doesn't pile
  // up sprites. Zero gameplay impact, pure visual.
  _setupWalkers() {
    this._walkers = [];
    this._walkerSpawnTimer = 0;
    this.events.on('update', this._tickWalkers, this);
  }

  _tickWalkers(_time, delta) {
    // Clamp dt to ~50ms (Atlas 2026-05-11: "walkers slow down like
    // they're lagging, then speed up"). When the main thread is
    // blocked (rerenderBuildings, realtime bursts, etc.), Phaser's
    // next update fires with a `delta` reflecting the full pause.
    // Without clamping, walkers would multiply that delta by their
    // speed and teleport forward. Capping at 50ms means the walker
    // just appears to hold still during the block, then resumes
    // smoothly — no jarring catch-up jump.
    const dt = Math.min(delta, 50) / 1000;
    this._walkerSpawnTimer += dt;

    if (this._walkerSpawnTimer >= WALKER_SPAWN_MS / 1000) {
      this._walkerSpawnTimer = 0;
      this._spawnRandomWalker();
    }

    for (let i = this._walkers.length - 1; i >= 0; i--) {
      const w = this._walkers[i];
      w.life -= dt;
      if (w.life <= 0) {
        w.sprite.destroy();
        if (w.accessory) w.accessory.destroy();
        this._walkers.splice(i, 1);
        continue;
      }
      // trueX/trueY follow the straight-line path. sprite.x/y get
      // trueX/Y plus a small perpendicular sine offset so the walker
      // visibly sways as it moves instead of gliding in a stiff line.
      // Older walkers (spawned before this commit) without trueX/Y
      // fall back to sprite position so they don't snap.
      if (w.trueX === undefined) { w.trueX = w.sprite.x; w.trueY = w.sprite.y; }
      const dx = w.targetX - w.trueX;
      const dy = w.targetY - w.trueY;
      const dist = Math.hypot(dx, dy);
      const speed = w.speed || 28;

      // Pause state for collector walkers — they sit at an endpoint
      // for a beat before flipping direction, mimicking "loading up
      // the resource" or "dropping it off".
      if (w.pauseUntil && performance.now() < w.pauseUntil) continue;
      if (w.pauseUntil) w.pauseUntil = 0;

      if (dist < 2) {
        // Arrived at the current target. Behavior depends on walker
        // kind:
        //   'road'      — pick the next connected road tile
        //   'collector' — short pause, then flip direction
        //   'immigrant' — despawn on arrival at the destination
        //   'emigrant'  — despawn on arrival at the parcel edge
        if (w.kind === 'road') {
          this._advanceWalkerToNextRoad(w);
          if (!w.targetX && !w.targetY) {
            w.sprite.destroy();
            if (w.accessory) w.accessory.destroy();
            this._walkers.splice(i, 1);
            continue;
          }
        } else if (w.kind === 'collector') {
          // Pause for ~700ms then flip toward the other endpoint.
          w.pauseUntil = performance.now() + 700;
          const tmpX = w.homeX, tmpY = w.homeY;
          w.homeX = w.targetX; w.homeY = w.targetY;
          w.targetX = tmpX; w.targetY = tmpY;
        } else if (w.kind === 'collector-path') {
          // Step through a precomputed road-network path. Flip at
          // each end of the path with a brief pause.
          if (w.goingForward) {
            if (w.wpIdx < w.path.length - 1) {
              w.wpIdx++;
              w.targetX = w.path[w.wpIdx][0];
              w.targetY = w.path[w.wpIdx][1];
            } else {
              w.pauseUntil = performance.now() + 1000;
              w.goingForward = false;
            }
          } else {
            if (w.wpIdx > 0) {
              w.wpIdx--;
              w.targetX = w.path[w.wpIdx][0];
              w.targetY = w.path[w.wpIdx][1];
            } else {
              w.pauseUntil = performance.now() + 500;
              w.goingForward = true;
            }
          }
        } else {
          // immigrant or emigrant — destination reached
          w.sprite.destroy();
          if (w.accessory) w.accessory.destroy();
          this._walkers.splice(i, 1);
          continue;
        }
      } else {
        // Advance true (path) position linearly toward target.
        w.trueX += (dx / dist) * speed * dt;
        w.trueY += (dy / dist) * speed * dt;
      }

      // Compute final rendered position: trueX/Y + a perpendicular
      // sine offset (~1.6px amplitude) so the walker sways across
      // its path. Per-walker phase keeps the flock desynced.
      const ux = dist > 0.01 ? dx / dist : 0;
      const uy = dist > 0.01 ? dy / dist : 0;
      const t = performance.now() / 1000;
      const wob = Math.sin(t * 4 + (w.phase || 0)) * 1.6;
      w.sprite.x = w.trueX + (-uy) * wob;
      w.sprite.y = w.trueY + (ux)  * wob;

      // Keep accessory locked to walker if one is attached.
      if (w.accessory && !w.accessory.scene) {
        w.accessory = null;   // stale ref from a prior scene
      }
      if (w.accessory) {
        w.accessory.x = w.sprite.x + 6;
        w.accessory.y = w.sprite.y + 1;
      }
    }
  }

  // Pick a neighboring road tile to walk to from the walker's current
  // tile. Prefer NOT to backtrack to the tile we just came from so
  // the walker actually traverses the network instead of pacing one
  // segment.
  _advanceWalkerToNextRoad(w) {
    const roads = this._roadSet;
    if (!roads || roads.size === 0) {
      w.targetX = 0; w.targetY = 0;
      return;
    }
    const candidates = [];
    for (const [dx, dy] of [[0, -1], [0, 1], [1, 0], [-1, 0]]) {
      const nx = w.curTileX + dx;
      const ny = w.curTileY + dy;
      if (!roads.has(nx + ',' + ny)) continue;
      if (nx === w.prevTileX && ny === w.prevTileY) continue;   // avoid backtrack
      candidates.push([nx, ny]);
    }
    let next;
    if (candidates.length) {
      next = candidates[Math.floor(Math.random() * candidates.length)];
    } else {
      // Dead end — only neighbor is the one we came from. Allow
      // backtrack so we don't just disappear at the stub.
      const fallback = [];
      for (const [dx, dy] of [[0, -1], [0, 1], [1, 0], [-1, 0]]) {
        if (roads.has((w.curTileX + dx) + ',' + (w.curTileY + dy))) {
          fallback.push([w.curTileX + dx, w.curTileY + dy]);
        }
      }
      if (!fallback.length) {
        w.targetX = 0; w.targetY = 0;
        return;
      }
      next = fallback[0];
    }
    w.prevTileX = w.curTileX;
    w.prevTileY = w.curTileY;
    w.curTileX = next[0];
    w.curTileY = next[1];
    w.targetX = (next[0] - state.gridMinX) * TILE_PX + TILE_PX / 2;
    w.targetY = (next[1] - state.gridMinY) * TILE_PX + TILE_PX / 2;
  }

  _spawnRandomWalker() {
    if (this._walkers.length >= maxWalkers()) return;
    const myId = state.currentUser?.id;

    // Build the set of extractor ids that already have a live
    // collector walker — exactly one collector per extractor at a
    // time, matching v1's "each active extractor owns one collector
    // walker" rule. Without this, multiple walkers from the same
    // extractor pile up visually, looking like several walkers are
    // headed to the same resource tile.
    const busyExtractors = new Set();
    for (const w of this._walkers) {
      if ((w.kind === 'collector' || w.kind === 'collector-path') && w.extractorId) {
        busyExtractors.add(w.extractorId);
      }
    }

    const candidates = state.allBuildings.filter((b) => {
      // Walkers spawn from any player's staffed buildings — the
      // shared map should show everyone's foot traffic, not just
      // yours. Building sprite alpha (0.7 for neighbors) is what
      // carries the ownership signal.
      if (!b.is_staffed || b.status !== 'active') return false;
      const bt = state.buildingTypes[b.building_type_key];
      if (!bt) return false;
      const isExt = bt.category === 'extractor' || bt.category === 'food_extractor';
      if (isExt && busyExtractors.has(b.id)) return false;   // already has a walker
      return true;
    });
    if (!candidates.length) return;
    const b = candidates[Math.floor(Math.random() * candidates.length)];
    const bt = state.buildingTypes[b.building_type_key];
    if (!bt) return;

    const isExtractor = bt.category === 'extractor' || bt.category === 'food_extractor';
    if (isExtractor && Number.isFinite(b.target_x) && Number.isFinite(b.target_y)) {
      this._spawnCollectorWalker(b, bt);
    } else {
      this._spawnRoadWalker(b, bt);
    }
  }

  _spawnRoadWalker(b, bt) {
    const fw = bt.footprint_w || 1;
    const fh = bt.footprint_h || 1;
    const roads = this._roadSet || new Set();
    const adjacent = [];
    for (let dx = 0; dx < fw; dx++) {
      for (let dy = 0; dy < fh; dy++) {
        const fx = b.x + dx, fy = b.y + dy;
        for (const [nx, ny] of [[fx, fy - 1], [fx, fy + 1], [fx + 1, fy], [fx - 1, fy]]) {
          if (roads.has(nx + ',' + ny)) adjacent.push([nx, ny]);
        }
      }
    }
    // No adjacent road = no road-walker. This is fine: an isolated
    // house just doesn't emit foot traffic until you connect a road.
    if (!adjacent.length) return;
    const [startTileX, startTileY] = adjacent[Math.floor(Math.random() * adjacent.length)];

    const startX = (startTileX - state.gridMinX) * TILE_PX + TILE_PX / 2;
    const startY = (startTileY - state.gridMinY) * TILE_PX + TILE_PX / 2;
    const sprite = this._makeWalkerSprite(b, bt, startX, startY);

    const speedJitter = 0.85 + Math.random() * 0.30;
    tagWalkerSpriteKind(sprite, 'road');
    const w = {
      kind: 'road', sprite, speed: 28 * speedJitter,
      curTileX: startTileX, curTileY: startTileY,
      prevTileX: b.x, prevTileY: b.y,
      targetX: startX, targetY: startY,
      trueX: startX, trueY: startY, phase: Math.random() * Math.PI * 2,
      life: 24
    };
    this._advanceWalkerToNextRoad(w);
    this._walkers.push(w);
  }

  _spawnCollectorWalker(b, bt) {
    const fw = bt.footprint_w || 1;
    const fh = bt.footprint_h || 1;
    const homeX = (b.x - state.gridMinX) * TILE_PX + (fw * TILE_PX) / 2;
    const homeY = (b.y - state.gridMinY) * TILE_PX + (fh * TILE_PX) / 2;
    const sprite = this._makeWalkerSprite(b, bt, homeX, homeY);
    const speed = 24 * (0.85 + Math.random() * 0.30);

    // Find a road path from building perimeter to a road tile adjacent
    // to the target. If found, walk waypoint-by-waypoint; if not, fall
    // back to the straight-line-through-grass animation (covers fresh
    // cities with no road network yet).
    const tilePath = this._findRoadPath(b, bt, b.target_x, b.target_y);
    tagWalkerSpriteKind(sprite, tilePath ? 'collector-path' : 'collector');
    const phase = Math.random() * Math.PI * 2;
    if (tilePath && tilePath.length > 0) {
      const worldPath = [];
      worldPath.push([homeX, homeY]);
      for (const [x, y] of tilePath) {
        worldPath.push([
          (x - state.gridMinX) * TILE_PX + TILE_PX / 2,
          (y - state.gridMinY) * TILE_PX + TILE_PX / 2
        ]);
      }
      worldPath.push([
        (b.target_x - state.gridMinX) * TILE_PX + TILE_PX / 2,
        (b.target_y - state.gridMinY) * TILE_PX + TILE_PX / 2
      ]);
      this._walkers.push({
        kind: 'collector-path', sprite, speed,
        path: worldPath, wpIdx: 1, goingForward: true,
        targetX: worldPath[1][0], targetY: worldPath[1][1],
        trueX: homeX, trueY: homeY, phase,
        extractorId: b.id,
        life: 30
      });
      return;
    }

    const resourceX = (b.target_x - state.gridMinX) * TILE_PX + TILE_PX / 2;
    const resourceY = (b.target_y - state.gridMinY) * TILE_PX + TILE_PX / 2;
    this._walkers.push({
      kind: 'collector', sprite, speed,
      homeX, homeY,
      targetX: resourceX, targetY: resourceY,
      trueX: homeX, trueY: homeY, phase,
      extractorId: b.id,
      life: 20
    });
  }

  // BFS from building footprint perimeter to a road tile adjacent to
  // the resource. Returns the tile-space path (array of [x, y]) or
  // null if no road-network route exists. Cheap on player-sized
  // parcels — bounded by the number of road tiles, typically tens.
  _findRoadPath(b, bt, targetX, targetY) {
    const roads = this._roadSet;
    if (!roads || roads.size === 0) return null;
    const fw = bt.footprint_w || 1, fh = bt.footprint_h || 1;

    // Start set: any road tile orthogonally adjacent to the footprint.
    const startSet = new Set();
    for (let dx = 0; dx < fw; dx++) {
      for (let dy = 0; dy < fh; dy++) {
        const fx = b.x + dx, fy = b.y + dy;
        for (const [nx, ny] of [[fx, fy - 1], [fx, fy + 1], [fx + 1, fy], [fx - 1, fy]]) {
          if (roads.has(nx + ',' + ny)) startSet.add(nx + ',' + ny);
        }
      }
    }
    if (startSet.size === 0) return null;

    // Goal set: any road tile orthogonally adjacent to the target.
    const goalSet = new Set();
    for (const [nx, ny] of [[targetX, targetY - 1], [targetX, targetY + 1],
                            [targetX + 1, targetY], [targetX - 1, targetY]]) {
      if (roads.has(nx + ',' + ny)) goalSet.add(nx + ',' + ny);
    }
    if (goalSet.size === 0) return null;

    // BFS.
    const visited = new Map();
    const queue = [];
    for (const s of startSet) { visited.set(s, null); queue.push(s); }
    while (queue.length > 0) {
      const cur = queue.shift();
      if (goalSet.has(cur)) {
        const path = [];
        let n = cur;
        while (n !== null) {
          const [x, y] = n.split(',').map(Number);
          path.unshift([x, y]);
          n = visited.get(n);
        }
        return path;
      }
      const [cx, cy] = cur.split(',').map(Number);
      for (const [dx, dy] of [[0, -1], [0, 1], [1, 0], [-1, 0]]) {
        const k = (cx + dx) + ',' + (cy + dy);
        if (!roads.has(k)) continue;
        if (visited.has(k)) continue;
        visited.set(k, cur);
        queue.push(k);
      }
    }
    return null;
  }

  // Public: spawn an emigrant walker. Called from the tick loop
  // when population goes down. Walks straight through grass from
  // a random house OUT to a random parcel edge, then despawns.
  spawnEmigrantWalker() {
    if (this._walkers.length >= maxWalkers()) return;
    const myId = state.currentUser?.id;
    const houses = state.allBuildings.filter((b) =>
      b.player_id === myId && state.buildingTypes[b.building_type_key]?.category === 'housing'
    );
    if (!houses.length) return;
    const house = houses[Math.floor(Math.random() * houses.length)];
    const bt = state.buildingTypes[house.building_type_key];
    const fw = bt.footprint_w || 1, fh = bt.footprint_h || 1;
    const houseX = (house.x - state.gridMinX) * TILE_PX + (fw * TILE_PX) / 2;
    const houseY = (house.y - state.gridMinY) * TILE_PX + (fh * TILE_PX) / 2;

    // Heading off the visible map in a random cardinal direction.
    const cam = this.cameras.main;
    const edges = [
      { x: cam.worldView.x - 40,                              y: houseY },
      { x: cam.worldView.x + cam.worldView.width + 40,        y: houseY },
      { x: houseX, y: cam.worldView.y - 40 },
      { x: houseX, y: cam.worldView.y + cam.worldView.height + 40 }
    ];
    const dest = edges[Math.floor(Math.random() * edges.length)];

    const sprite = this.add.sprite(houseX, houseY, 'walker-citizen');
    sprite.setDisplaySize(WALKER_PX_W, WALKER_PX_H);
    sprite.setDepth(10);
    sprite.setAlpha(0.85);    // slightly faded — they're leaving
    sprite.setInteractive({ useHandCursor: true });
    sprite.walkerInfo = { variant: 'citizen', kind: 'emigrant' };
    // Bindle marker beside the emigrant — signals "carrying their
    // belongings out". Brown circle with a stick poking up; small
    // enough to read as a satchel at walker scale.
    const accessory = this._makeWalkerAccessory(houseX, houseY, 'bindle');
    this._walkers.push({
      kind: 'emigrant', sprite, accessory, speed: 32,
      targetX: dest.x, targetY: dest.y,
      trueX: houseX, trueY: houseY, phase: Math.random() * Math.PI * 2,
      life: 60
    });
  }

  // Public: spawn an immigrant walker. Called from the tick loop
  // when population goes up. Walks straight through grass from the
  // edge of the player's parcel to a random house, then despawns.
  spawnImmigrantWalker() {
    if (this._walkers.length >= maxWalkers()) return;
    const myId = state.currentUser?.id;
    const houses = state.allBuildings.filter((b) =>
      b.player_id === myId && state.buildingTypes[b.building_type_key]?.category === 'housing'
    );
    if (!houses.length) return;
    const house = houses[Math.floor(Math.random() * houses.length)];
    const bt = state.buildingTypes[house.building_type_key];
    const fw = bt.footprint_w || 1, fh = bt.footprint_h || 1;
    const houseX = (house.x - state.gridMinX) * TILE_PX + (fw * TILE_PX) / 2;
    const houseY = (house.y - state.gridMinY) * TILE_PX + (fh * TILE_PX) / 2;

    // Pick a random edge of the camera's world bounds to come in from.
    const cam = this.cameras.main;
    const edges = [
      { x: cam.worldView.x - 40,                              y: houseY },                  // from left
      { x: cam.worldView.x + cam.worldView.width + 40,        y: houseY },                  // from right
      { x: houseX, y: cam.worldView.y - 40 },                                                // from top
      { x: houseX, y: cam.worldView.y + cam.worldView.height + 40 }                          // from bottom
    ];
    const start = edges[Math.floor(Math.random() * edges.length)];

    const sprite = this.add.sprite(start.x, start.y, 'walker-citizen');
    sprite.setDisplaySize(WALKER_PX_W, WALKER_PX_H);
    sprite.setDepth(10);
    sprite.setInteractive({ useHandCursor: true });
    sprite.walkerInfo = { variant: 'citizen', kind: 'immigrant' };
    // Luggage marker beside the immigrant — rolls one of three
    // accessory variants for variety.
    const variants = ['luggage', 'backpack', 'bindle'];
    const accessory = this._makeWalkerAccessory(start.x, start.y,
      variants[Math.floor(Math.random() * variants.length)]);
    this._walkers.push({
      kind: 'immigrant', sprite, accessory, speed: 32,
      targetX: houseX, targetY: houseY,
      trueX: start.x, trueY: start.y, phase: Math.random() * Math.PI * 2,
      life: 60
    });
  }

  // Build a small accessory shape (luggage / backpack / bindle) and
  // return the sprite so the tick loop can keep it next to its
  // walker. Drawn into a one-shot texture so subsequent walkers can
  // reuse the same atlas entry — cheap.
  _makeWalkerAccessory(x, y, variant) {
    const texKey = 'wacc-' + variant;
    if (!this.textures.exists(texKey)) {
      const g = this.add.graphics();
      if (variant === 'luggage') {
        // brown rectangle with a small handle on top
        g.fillStyle(0x6a4a2c, 1);
        g.fillRoundedRect(0, 2, 6, 6, 1);
        g.fillStyle(0x4a3018, 1);
        g.fillRect(2, 0, 2, 2);
      } else if (variant === 'backpack') {
        g.fillStyle(0x586a3a, 1);
        g.fillRoundedRect(0, 0, 5, 7, 1.5);
        g.fillStyle(0x3e4828, 1);
        g.fillRect(0, 3, 5, 1);
      } else {   // bindle
        g.lineStyle(1, 0x6a4a2c, 1);
        g.beginPath(); g.moveTo(0, 0); g.lineTo(2, 5); g.strokePath();
        g.fillStyle(0xb87848, 1);
        g.fillCircle(3, 6, 2.5);
      }
      g.generateTexture(texKey, 8, 8);
      g.destroy();
    }
    const acc = this.add.sprite(x + 6, y, texKey);
    acc.setDepth(11);
    return acc;
  }

  _makeWalkerSprite(b, bt, x, y) {
    const variant = pickWalkerVariant(b, bt);
    const sprite = this.add.sprite(x, y, 'walker-' + variant);
    // Per-walker visual jitter — small scale variance + occasional
    // tint shift so a stream of citizens reads as different people
    // instead of an army of clones. Range matches v1's CSS jitter.
    const scaleJitter = 0.92 + Math.random() * 0.16;
    sprite.setDisplaySize(WALKER_PX_W * scaleJitter, WALKER_PX_H * scaleJitter);
    sprite.setDepth(10);
    // 60% of walkers get a subtle tint roll — caps channel-shift
    // small enough that the underlying sprite art still reads.
    if (Math.random() < 0.6) {
      const tints = [0xffd8c0, 0xc8e0ff, 0xe0ffe0, 0xfff0c8, 0xf0d0e0];
      sprite.setTint(tints[Math.floor(Math.random() * tints.length)]);
    }
    sprite.setInteractive({ useHandCursor: true });
    // Stash the originating building + walker variant so tap-to-
    // inspect can show "this is a worker from <Sawmill>" context.
    sprite.walkerInfo = { variant, originBuilding: b, originType: bt };
    return sprite;
  }

  // Public: highlight tiles in a building's area-of-effect. Called by
  // the inspector when a service/police/park/booster building is opened
  // so the player can see exactly which tiles benefit. Clearing is just
  // calling this with null.
  showAoe(building) {
    this.clearAoe();
    if (!building) return;
    const bt = state.buildingTypes[building.building_type_key];
    if (!bt) return;
    const aoe = getBuildingAoeRange(building, bt);
    if (!aoe) return;

    const fw = bt.footprint_w || 1;
    const fh = bt.footprint_h || 1;
    const cells = new Set();
    // Manhattan disk around every footprint cell, then unioned.
    for (let dx = 0; dx < fw; dx++) {
      for (let dy = 0; dy < fh; dy++) {
        for (let rx = -aoe.range; rx <= aoe.range; rx++) {
          for (let ry = -aoe.range; ry <= aoe.range; ry++) {
            if (Math.abs(rx) + Math.abs(ry) <= aoe.range) {
              cells.add((building.x + dx + rx) + ',' + (building.y + dy + ry));
            }
          }
        }
      }
    }
    const tint = AOE_TINTS[aoe.kind] || 0x16c79a;
    for (const k of cells) {
      const [x, y] = k.split(',').map(Number);
      // Only paint tiles in this player's parcel for clarity.
      if (!state.tileMap[k]) continue;
      const wx = (x - state.gridMinX) * TILE_PX + TILE_PX / 2;
      const wy = (y - state.gridMinY) * TILE_PX + TILE_PX / 2;
      const overlay = this.add.sprite(wx, wy, 'square');
      overlay.setTint(tint);
      overlay.setAlpha(0.32);
      overlay.setDepth(3);   // below res-dot (5), above tiles (default 0)
      this._aoeOverlays.push(overlay);
    }
  }

  // Public: draw a gold outline around the inspected building's
  // footprint + (for extractors) mark the resource tile they're
  // harvesting from. Called from the inspector on open; cleared on
  // close. Separate from showAoe — showAoe paints the AFFECTED tiles
  // for service/police/park/booster; this marks the SELECTED building
  // itself + its resource target.
  showSelection(building) {
    this.clearSelection();
    if (!building) return;
    const bt = state.buildingTypes[building.building_type_key];
    if (!bt) return;
    const fw = bt.footprint_w || 1, fh = bt.footprint_h || 1;
    const x = (building.x - state.gridMinX) * TILE_PX;
    const y = (building.y - state.gridMinY) * TILE_PX;
    const w = fw * TILE_PX, h = fh * TILE_PX;
    // Gold rectangle outline. Drawn with a Graphics object so the
    // stroke is crisp and doesn't tint underlying sprites.
    const g = this.add.graphics();
    g.lineStyle(3, 0xffd060, 1);
    g.strokeRect(x + 1, y + 1, w - 2, h - 2);
    g.setDepth(15);   // above building sprites (depth 0-12)
    this._selectionOverlay = g;
    // Extractor: also mark the resource tile being harvested. Different
    // tint (amber-orange) + small inset so it reads as "this is the
    // target of the selected building" rather than the selection itself.
    if ((bt.category === 'extractor' || bt.category === 'food_extractor')
        && Number.isFinite(building.target_x) && Number.isFinite(building.target_y)) {
      const tx = (building.target_x - state.gridMinX) * TILE_PX;
      const ty = (building.target_y - state.gridMinY) * TILE_PX;
      const g2 = this.add.graphics();
      g2.lineStyle(3, 0xff9028, 1);
      g2.strokeRect(tx + 2, ty + 2, TILE_PX - 4, TILE_PX - 4);
      // Pulsing alpha so it draws the eye to the resource tile.
      g2.setDepth(15);
      this.tweens.add({
        targets: g2,
        alpha: { from: 1, to: 0.4 },
        duration: 700, yoyo: true, repeat: -1, ease: 'Sine.easeInOut'
      });
      this._selectionTargetOverlay = g2;
    }
  }

  clearSelection() {
    if (this._selectionOverlay) {
      this._selectionOverlay.destroy();
      this._selectionOverlay = null;
    }
    if (this._selectionTargetOverlay) {
      this._selectionTargetOverlay.destroy();
      this._selectionTargetOverlay = null;
    }
  }

  clearAoe() {
    for (const s of this._aoeOverlays) s.destroy();
    this._aoeOverlays = [];
  }

  // Generate the 16 NSEW road autotile textures into Phaser's
  // texture manager. Keys are 'road-0' .. 'road-15'. Each is
  // TILE_PX × TILE_PX with grass background, dirt road surface,
  // and a lighter worn track in the middle. Cheap one-time cost
  // at scene boot; per-tile lookup at render time is O(1).
  // Per-kind resource icons. Each is a small graphic drawn into a
  // named texture: wood = tree shape, stone = rock cluster, metal =
  // angular ore, clay = mound, food = wheat strands, fish = water
  // ripple. Rendered ~28×28 so they sit on a 48px tile with grass
  // shoulder showing. Tints applied at draw time, not via setTint at
  // render time, so each icon's silhouette is distinct.
  _ensureResourceIconTextures() {
    if (this.textures.exists('res-wood')) return;
    const SZ = 28;

    // wood — tree with brown trunk, green leaves
    let g = this.add.graphics();
    g.fillStyle(0x4a2f1a, 1);
    g.fillRect(SZ/2 - 2, SZ - 8, 4, 8);
    g.fillStyle(0x3a7a3a, 1);
    g.fillCircle(SZ/2, SZ/2 + 2, 9);
    g.fillStyle(0x4a8a4a, 1);
    g.fillCircle(SZ/2 - 3, SZ/2 - 1, 6);
    g.fillCircle(SZ/2 + 3, SZ/2, 6);
    g.generateTexture('res-wood', SZ, SZ);
    g.destroy();

    // stone — three grey rocks at different sizes
    g = this.add.graphics();
    g.fillStyle(0x6a6a78, 1);
    g.fillCircle(SZ/2 - 4, SZ/2 + 4, 6);
    g.fillStyle(0x8a8aa0, 1);
    g.fillCircle(SZ/2 + 4, SZ/2 - 2, 7);
    g.fillStyle(0x7a7a90, 1);
    g.fillCircle(SZ/2 - 6, SZ/2 - 5, 4);
    g.generateTexture('res-stone', SZ, SZ);
    g.destroy();

    // metal/iron — dark angular ore boulder with metallic highlight
    g = this.add.graphics();
    g.fillStyle(0x3a3030, 1);
    g.fillTriangle(SZ/2 - 9, SZ/2 + 7, SZ/2 + 10, SZ/2 + 8, SZ/2, SZ/2 - 8);
    g.fillStyle(0x6a5a5a, 1);
    g.fillTriangle(SZ/2 - 5, SZ/2 + 5, SZ/2 + 6, SZ/2 + 5, SZ/2, SZ/2 - 4);
    g.fillStyle(0xa89090, 1);
    g.fillCircle(SZ/2 - 1, SZ/2 - 1, 2);
    g.generateTexture('res-metal', SZ, SZ);
    g.destroy();

    // clay — flatter brown earthy mound
    g = this.add.graphics();
    g.fillStyle(0x8a5430, 1);
    g.fillEllipse(SZ/2, SZ/2 + 3, 22, 12);
    g.fillStyle(0xa07050, 1);
    g.fillEllipse(SZ/2, SZ/2, 16, 7);
    g.fillStyle(0xc08858, 1);
    g.fillEllipse(SZ/2 - 1, SZ/2 - 2, 8, 3);
    g.generateTexture('res-clay', SZ, SZ);
    g.destroy();

    // grain — 5 vertical wheat strands of varying heights, gold-yellow
    g = this.add.graphics();
    const strandColors = [0xd8b840, 0xc8a838, 0xe0c050];
    for (let i = 0; i < 5; i++) {
      const x = 4 + i * 5;
      const h = 12 + (i % 3) * 3;
      g.fillStyle(strandColors[i % strandColors.length], 1);
      g.fillRect(x, SZ - h - 2, 2, h);
      // small grain head on top
      g.fillCircle(x + 1, SZ - h - 2, 2);
    }
    g.generateTexture('res-grain', SZ, SZ);
    g.destroy();
    // Keep `res-food` as an alias for back-compat with any code that
    // still references it during rollout — drops out once verified.
    g = this.add.graphics();
    for (let i = 0; i < 5; i++) {
      const x = 4 + i * 5;
      const h = 12 + (i % 3) * 3;
      g.fillStyle(strandColors[i % strandColors.length], 1);
      g.fillRect(x, SZ - h - 2, 2, h);
      g.fillCircle(x + 1, SZ - h - 2, 2);
    }
    g.generateTexture('res-food', SZ, SZ);
    g.destroy();

    // orchard — apple tree: brown trunk + green canopy + 3 red fruits
    // dotted across the canopy. Visually distinct from plain timber
    // (no fruits) so a player can tell food tiles from industry tiles.
    g = this.add.graphics();
    g.fillStyle(0x4a2f1a, 1);
    g.fillRect(SZ/2 - 2, SZ - 8, 4, 8);
    g.fillStyle(0x2a6a2a, 1);
    g.fillCircle(SZ/2, SZ/2 + 2, 10);
    g.fillStyle(0x3a8a3a, 1);
    g.fillCircle(SZ/2 - 4, SZ/2, 6);
    g.fillCircle(SZ/2 + 4, SZ/2 + 1, 6);
    // Apples — red dots scattered through the canopy.
    g.fillStyle(0xd03830, 1);
    g.fillCircle(SZ/2 - 3, SZ/2 + 4, 2);
    g.fillCircle(SZ/2 + 4, SZ/2 - 2, 2);
    g.fillCircle(SZ/2 + 1, SZ/2 + 6, 1.8);
    g.fillStyle(0xff6050, 1);
    g.fillCircle(SZ/2 - 4, SZ/2 + 3, 0.8);
    g.generateTexture('res-orchard', SZ, SZ);
    g.destroy();

    // vegetables (garden plot) — carrot + 2 leafy greens layout.
    // Orange triangle (carrot pointing down) flanked by darker green
    // bushes; reads clearly as "garden" vs the wheat strands.
    g = this.add.graphics();
    // carrot tops (green frilly leaves)
    g.fillStyle(0x4a8838, 1);
    g.fillTriangle(SZ/2 - 4, SZ/2 - 3, SZ/2 + 4, SZ/2 - 3, SZ/2, SZ/2 - 10);
    g.fillStyle(0x6aa848, 1);
    g.fillTriangle(SZ/2 - 2, SZ/2 - 4, SZ/2 + 2, SZ/2 - 4, SZ/2, SZ/2 - 8);
    // carrot body (orange triangle pointing down)
    g.fillStyle(0xe07028, 1);
    g.fillTriangle(SZ/2 - 4, SZ/2 - 2, SZ/2 + 4, SZ/2 - 2, SZ/2, SZ/2 + 8);
    g.fillStyle(0xf08840, 1);
    g.fillTriangle(SZ/2 - 2, SZ/2 - 2, SZ/2 + 2, SZ/2 - 2, SZ/2, SZ/2 + 4);
    // small leafy bushes left + right
    g.fillStyle(0x3a7028, 1);
    g.fillCircle(4, SZ - 5, 3);
    g.fillCircle(SZ - 4, SZ - 5, 3);
    g.fillStyle(0x4a8838, 1);
    g.fillCircle(4, SZ - 6, 2);
    g.fillCircle(SZ - 4, SZ - 6, 2);
    g.generateTexture('res-vegetables', SZ, SZ);
    g.destroy();

    // fish/water — blue oval with a ripple line
    g = this.add.graphics();
    g.fillStyle(0x4488b8, 1);
    g.fillEllipse(SZ/2, SZ/2, 22, 14);
    g.fillStyle(0x70a8c8, 1);
    g.fillEllipse(SZ/2, SZ/2 - 2, 16, 6);
    g.lineStyle(1, 0x305878, 1);
    g.beginPath();
    g.arc(SZ/2, SZ/2 - 2, 5, 0, Math.PI, false);
    g.strokePath();
    g.generateTexture('res-fish', SZ, SZ);
    g.destroy();

    // default — generic amber dot for any kind we forgot to handle
    g = this.add.graphics();
    g.fillStyle(0xe0c060, 1);
    g.fillCircle(SZ/2, SZ/2, 7);
    g.fillStyle(0xfff0a0, 1);
    g.fillCircle(SZ/2 - 2, SZ/2 - 2, 2);
    g.generateTexture('res-default', SZ, SZ);
    g.destroy();
  }

  // Generate 4 base grass variants + 8 decoration overlays. Each
  // grass variant is a tile-sized texture filled with the base owned-
  // grass color plus pseudo-random pixel speckles in slightly darker /
  // lighter green so the surface looks like noisy turf instead of
  // flat color. Variant tints stay close to the base color so adjacent
  // tiles still read as a continuous field. Decoration overlays
  // (dandelion / daisies / clover / dirt patch / pebbles / poppies /
  // mossy log / tall grass) are smaller graphics composited on top of
  // ~30% of tiles per hash(x,y).
  _ensureGrassTextures() {
    if (this.textures.exists('grass-v0')) return;
    const SZ = TILE_PX;

    // All 4 variants share the SAME base color so adjacent tiles
    // blend into a continuous field. Variation lives only inside an
    // inner box (5..SZ-5) so the outer 5px ring is always the same
    // exact green across every tile — no seam visible at the join.
    const BASE = 0x4a6440;
    const ACCENT_DARK  = 0x3e5836;
    const ACCENT_LIGHT = 0x547248;
    const MARGIN = 5;
    const INNER_W = SZ - MARGIN * 2;
    for (let v = 0; v < 4; v++) {
      const g = this.add.graphics();
      g.fillStyle(BASE, 1);
      g.fillRect(0, 0, SZ, SZ);
      // 80 single-pixel speckles, confined to the inner box.
      for (let i = 0; i < 80; i++) {
        const seed = (v * 9301 + i * 49297 + 233280) % 233280;
        const x = MARGIN + (seed % INNER_W);
        const y = MARGIN + (((seed / INNER_W) | 0) % INNER_W);
        const accent = ((seed >> 4) & 1) ? ACCENT_LIGHT : ACCENT_DARK;
        g.fillStyle(accent, 0.55);
        g.fillRect(x, y, 1, 1);
      }
      // 6 darker 2x2 clumps inside the same inner box.
      const INNER_W_2 = INNER_W - 2;
      for (let i = 0; i < 6; i++) {
        const seed = (v * 5701 + i * 67891 + 887) % 233280;
        const x = MARGIN + (seed % INNER_W_2);
        const y = MARGIN + (((seed / INNER_W_2) | 0) % INNER_W_2);
        g.fillStyle(ACCENT_DARK, 0.40);
        g.fillRect(x, y, 2, 2);
      }
      g.generateTexture('grass-v' + v, SZ, SZ);
      g.destroy();
    }

    // 8 decoration overlays. All drawn into a 16x16 box so the
    // composite stays small + readable at tile scale. Each rendered
    // around the center point of the sprite.
    const DECO_SZ = 16;
    const drawDeco = (key, fn) => {
      const g = this.add.graphics();
      fn(g);
      g.generateTexture(key, DECO_SZ, DECO_SZ);
      g.destroy();
    };
    // 0: dandelion — single yellow flower on a thin green stem
    drawDeco('gdeco-0', (g) => {
      g.lineStyle(1, 0x3a6028, 0.9);
      g.beginPath(); g.moveTo(8, 12); g.lineTo(8, 6); g.strokePath();
      g.fillStyle(0xf0c050, 1);
      g.fillCircle(8, 5, 2.2);
      g.fillStyle(0xfff080, 1);
      g.fillCircle(8, 5, 1.0);
    });
    // 1: daisies — three small white dots in a cluster
    drawDeco('gdeco-1', (g) => {
      g.fillStyle(0xf8f8ee, 1);
      g.fillCircle(6, 8, 1.4);
      g.fillCircle(10, 6, 1.4);
      g.fillCircle(9, 11, 1.4);
      g.fillStyle(0xf0d030, 1);
      g.fillCircle(6, 8, 0.5);
      g.fillCircle(10, 6, 0.5);
      g.fillCircle(9, 11, 0.5);
    });
    // 2: clover — 3 darker green rounded leaves
    drawDeco('gdeco-2', (g) => {
      g.fillStyle(0x2c5a28, 0.85);
      g.fillCircle(6, 7, 2.2);
      g.fillCircle(10, 7, 2.2);
      g.fillCircle(8, 10, 2.2);
      g.fillStyle(0x3a7030, 0.7);
      g.fillCircle(6, 7, 1);
      g.fillCircle(10, 7, 1);
      g.fillCircle(8, 10, 1);
    });
    // 3: red poppies — 2 red dots with darker centers
    drawDeco('gdeco-3', (g) => {
      g.fillStyle(0xb83018, 1);
      g.fillCircle(6, 9, 1.8);
      g.fillCircle(11, 7, 1.8);
      g.fillStyle(0x401810, 1);
      g.fillCircle(6, 9, 0.5);
      g.fillCircle(11, 7, 0.5);
    });
    // 4: bare-dirt patch — irregular brown blob
    drawDeco('gdeco-4', (g) => {
      g.fillStyle(0x6a5030, 0.85);
      g.fillCircle(8, 8, 3.5);
      g.fillStyle(0x8a6840, 0.7);
      g.fillCircle(9, 7, 1.5);
      g.fillCircle(7, 9, 1.2);
    });
    // 5: pebbles — 3 grey dots at varying sizes
    drawDeco('gdeco-5', (g) => {
      g.fillStyle(0x7a7a78, 1);
      g.fillCircle(5, 9, 1.4);
      g.fillCircle(10, 7, 1.7);
      g.fillCircle(9, 11, 1.0);
      g.fillStyle(0x9a9a98, 0.7);
      g.fillCircle(5, 8.5, 0.5);
      g.fillCircle(10, 6.5, 0.6);
    });
    // 6: mossy log — short horizontal brown bar with a green moss line
    drawDeco('gdeco-6', (g) => {
      g.fillStyle(0x5a3a20, 1);
      g.fillRoundedRect(3, 7, 10, 3, 1);
      g.fillStyle(0x3a6028, 0.85);
      g.fillRect(4, 7, 8, 1);
      g.fillStyle(0x2a4818, 1);
      g.fillCircle(4, 8.5, 0.4);
      g.fillCircle(11, 8.5, 0.4);
    });
    // 7: tall grass — 3 darker green vertical strokes
    drawDeco('gdeco-7', (g) => {
      g.lineStyle(1, 0x2c5028, 0.9);
      g.beginPath(); g.moveTo(5, 13); g.lineTo(5,  6); g.strokePath();
      g.beginPath(); g.moveTo(8, 13); g.lineTo(7,  4); g.strokePath();
      g.beginPath(); g.moveTo(11, 13); g.lineTo(11, 7); g.strokePath();
    });
  }

  _ensureRoadTextures() {
    if (this.textures.exists('road-0')) return;
    const SZ = TILE_PX;
    const L = Math.floor(SZ * 0.18);      // inner margin (grass shoulder)
    const R = SZ - L;                     // inner road right/bottom edge
    const RW = R - L;                     // road body width

    // Deterministic pseudo-random: same mask + index always picks the
    // same gravel/pebble positions so the texture stays stable.
    const rng = (mask, i, span) => {
      const seed = (mask * 9301 + i * 49297 + 233280) % 233280;
      return Math.floor((seed / 233280) * span);
    };
    // Is a pixel (px,py) on the road surface for the given NSEW mask?
    // Used to gate gravel/pebble placement so dots never spill onto
    // grass.
    const onRoad = (px, py, n, s, e, w) => {
      if (px >= L && px <= R && py >= L && py <= R) return true;
      if (n && px >= L && px <= R && py < L) return true;
      if (s && px >= L && px <= R && py > R) return true;
      if (e && px > R && py >= L && py <= R) return true;
      if (w && px < L && py >= L && py <= R) return true;
      if (n && w && px < L && py < L) return true;
      if (n && e && px > R && py < L) return true;
      if (s && w && px < L && py > R) return true;
      if (s && e && px > R && py > R) return true;
      return false;
    };

    for (let mask = 0; mask < 16; mask++) {
      const n = !!(mask & 8), s = !!(mask & 4), e = !!(mask & 2), w = !!(mask & 1);
      const g = this.add.graphics();

      // 1. Grass background — dark earthy green
      g.fillStyle(0x4a6440, 1);
      g.fillRect(0, 0, SZ, SZ);

      // 2. Road body (always centered) + arms toward connected neighbors.
      //    Slightly warmer brown than before so the road reads as
      //    packed earth, not asphalt.
      g.fillStyle(0x7a5e3a, 1);
      g.fillRect(L, L, RW, RW);
      if (n) g.fillRect(L, 0, RW, L);
      if (s) g.fillRect(L, R, RW, SZ - R);
      if (e) g.fillRect(R, L, SZ - R, RW);
      if (w) g.fillRect(0, L, L, RW);
      if (n && w) g.fillRect(0, 0, L, L);
      if (n && e) g.fillRect(R, 0, SZ - R, L);
      if (s && w) g.fillRect(0, R, L, SZ - R);
      if (s && e) g.fillRect(R, R, SZ - R, SZ - R);

      // 3. Worn center track — broader, softer "well-trodden middle".
      //    Lighter brown with alpha so the underlying packed-earth
      //    colour shows through; reads as a path within the path.
      const CT = Math.max(4, Math.floor(RW * 0.45));
      const co = Math.floor((RW - CT) / 2);
      g.fillStyle(0x9a7a52, 0.6);
      if (n || s) {
        g.fillRect(L + co, L, CT, RW);
        if (n) g.fillRect(L + co, 0, CT, L);
        if (s) g.fillRect(L + co, R, CT, SZ - R);
      }
      if (e || w) {
        g.fillRect(L, L + co, RW, CT);
        if (e) g.fillRect(R, L + co, SZ - R, CT);
        if (w) g.fillRect(0, L + co, L, CT);
      }
      // 1-tile islands (no connections): tighter worn ring rather
      // than just the wide center strip.
      if (!n && !s && !e && !w) {
        g.fillStyle(0x8a6a48, 0.5);
        g.fillCircle(SZ / 2, SZ / 2, RW * 0.32);
      }

      // 4. Grass-shoulder softening — light dirt strip along the inside
      //    edge of every grass/road boundary. Makes the transition
      //    look organic instead of a stamped border.
      g.fillStyle(0x584028, 0.30);
      const SHOULD = 2;
      if (!n) g.fillRect(L, L, RW, SHOULD);
      if (!s) g.fillRect(L, R - SHOULD, RW, SHOULD);
      if (!w) g.fillRect(L, L, SHOULD, RW);
      if (!e) g.fillRect(R - SHOULD, L, SHOULD, RW);

      // 5. Wheel ruts — two faint parallel dark strokes along the
      //    direction of travel. Skipped on isolated single tiles so
      //    they don't look streaked.
      const r1 = L + Math.floor(RW * 0.32);
      const r2 = L + Math.floor(RW * 0.62);
      g.lineStyle(1, 0x3a2a18, 0.30);
      if (n || s) {
        const y1 = n ? 0 : L;
        const y2 = s ? SZ : R;
        g.beginPath(); g.moveTo(r1, y1); g.lineTo(r1, y2); g.strokePath();
        g.beginPath(); g.moveTo(r2, y1); g.lineTo(r2, y2); g.strokePath();
      }
      if (e || w) {
        const x1 = w ? 0 : L;
        const x2 = e ? SZ : R;
        g.beginPath(); g.moveTo(x1, r1); g.lineTo(x2, r1); g.strokePath();
        g.beginPath(); g.moveTo(x1, r2); g.lineTo(x2, r2); g.strokePath();
      }

      // 6. Gravel scatter — small light dots across the road surface.
      //    Deterministic per-tile so identical autotiles have identical
      //    texture (no flicker on re-renders).
      g.fillStyle(0xa68a64, 0.45);
      for (let i = 0; i < 14; i++) {
        const px = rng(mask, i * 3 + 7, SZ);
        const py = rng(mask, i * 5 + 13, SZ);
        if (onRoad(px, py, n, s, e, w)) g.fillCircle(px, py, 0.7);
      }

      // 7. Larger pebbles — fewer, darker, deeper into the surface.
      g.fillStyle(0x4a3820, 0.55);
      for (let i = 0; i < 5; i++) {
        const px = rng(mask, i * 11 + 2, SZ);
        const py = rng(mask, i * 7 + 5, SZ);
        if (onRoad(px, py, n, s, e, w)) g.fillCircle(px, py, 1.1);
      }

      // 8. Edge border lines — darker stroke where road meets grass.
      g.lineStyle(1, 0x2e1f10, 0.55);
      if (!n) { g.beginPath(); g.moveTo(L, L); g.lineTo(R, L); g.strokePath(); }
      if (!s) { g.beginPath(); g.moveTo(L, R); g.lineTo(R, R); g.strokePath(); }
      if (!w) { g.beginPath(); g.moveTo(L, L); g.lineTo(L, R); g.strokePath(); }
      if (!e) { g.beginPath(); g.moveTo(R, L); g.lineTo(R, R); g.strokePath(); }
      // Also stroke the arm/corner outer edges for connected sides
      // so the road doesn't dissolve into the grass at the tile seam.
      if (n && !w) { g.beginPath(); g.moveTo(L, 0); g.lineTo(L, L); g.strokePath(); }
      if (n && !e) { g.beginPath(); g.moveTo(R, 0); g.lineTo(R, L); g.strokePath(); }
      if (s && !w) { g.beginPath(); g.moveTo(L, R); g.lineTo(L, SZ); g.strokePath(); }
      if (s && !e) { g.beginPath(); g.moveTo(R, R); g.lineTo(R, SZ); g.strokePath(); }
      if (e && !n) { g.beginPath(); g.moveTo(R, L); g.lineTo(SZ, L); g.strokePath(); }
      if (e && !s) { g.beginPath(); g.moveTo(R, R); g.lineTo(SZ, R); g.strokePath(); }
      if (w && !n) { g.beginPath(); g.moveTo(0, L); g.lineTo(L, L); g.strokePath(); }
      if (w && !s) { g.beginPath(); g.moveTo(0, R); g.lineTo(L, R); g.strokePath(); }

      // 9. Grass tufts at the road edges — small angled green flecks
      //    so the grass-road boundary feels alive rather than stamped.
      g.lineStyle(0.8, 0x2a5028, 0.7);
      const tuft = (x1, y1, x2, y2) => {
        g.beginPath(); g.moveTo(x1, y1); g.lineTo(x2, y2); g.strokePath();
      };
      if (!n) {
        tuft(L + 4, L,     L + 3, L - 3);
        tuft(L + 5, L,     L + 6, L - 3);
        tuft(R - 6, L,     R - 7, L - 4);
        tuft(R - 5, L,     R - 4, L - 3);
      }
      if (!s) {
        tuft(L + 5, R,     L + 4, R + 3);
        tuft(L + 6, R,     L + 7, R + 4);
        tuft(R - 7, R,     R - 8, R + 3);
        tuft(R - 5, R,     R - 4, R + 3);
      }
      if (!w) {
        tuft(L, L + 4,     L - 3, L + 3);
        tuft(L, L + 5,     L - 4, L + 6);
        tuft(L, R - 6,     L - 3, R - 7);
        tuft(L, R - 5,     L - 3, R - 4);
      }
      if (!e) {
        tuft(R, L + 5,     R + 3, L + 4);
        tuft(R, L + 6,     R + 4, L + 7);
        tuft(R, R - 6,     R + 3, R - 8);
        tuft(R, R - 4,     R + 3, R - 3);
      }

      g.generateTexture('road-' + mask, SZ, SZ);
      g.destroy();
    }
  }

  // Highlight candidate expansion chunks. Each row is { chunk_x,
  // chunk_y }; chunks are 15×15 tiles (matches the server's
  // allocate_district_chunk and design doc — earlier "10" guess
  // was wrong, candidates were painting at half-offsets).
  //
  // onPick is invoked with the candidate when the player taps one.
  showExpansionCandidates(candidates, onPick) {
    this.clearExpansionCandidates();
    this._expansionOverlays = this._expansionOverlays || [];
    const CHUNK = 15;
    candidates.forEach((c, i) => {
      const tlx = c.chunk_x * CHUNK;
      const tly = c.chunk_y * CHUNK;
      const wx = (tlx - state.gridMinX) * TILE_PX;
      const wy = (tly - state.gridMinY) * TILE_PX;
      const size = CHUNK * TILE_PX;
      const fill = this.add.sprite(wx + size / 2, wy + size / 2, 'square');
      fill.setDisplaySize(size, size);
      fill.setTint(0x16c79a);
      fill.setAlpha(0.20);
      fill.setDepth(4);
      // Make the candidate tap-targetable. Use a wider interactive
      // area than the sprite's visual edges so the player doesn't
      // have to be pixel-precise.
      fill.setInteractive({ useHandCursor: true });
      fill.candidateCoords = { chunk_x: c.chunk_x, chunk_y: c.chunk_y };
      fill.on('pointerdown', (pointer, _lx, _ly, event) => {
        if (event && event.stopPropagation) event.stopPropagation();
        if (onPick) onPick({ chunk_x: c.chunk_x, chunk_y: c.chunk_y });
      });
      // Pulse the fill so the candidates are visibly inviting.
      this.tweens.add({
        targets: fill,
        alpha: { from: 0.20, to: 0.42 },
        duration: 900,
        yoyo: true,
        repeat: -1,
        ease: 'Sine.easeInOut'
      });
      const label = this.add.text(wx + size / 2, wy + size / 2, '#' + (i + 1), {
        fontFamily: 'system-ui, sans-serif',
        fontSize: '32px',
        color: '#16c79a',
        fontStyle: 'bold'
      }).setOrigin(0.5).setDepth(5);
      // A gold border around each candidate so it reads as "selectable
      // patch of land" rather than a vague tint.
      const border = this.add.graphics();
      border.lineStyle(2, 0x16c79a, 0.7);
      border.strokeRect(wx + 1, wy + 1, size - 2, size - 2);
      border.setDepth(5);
      this._expansionOverlays.push(fill, label, border);
    });
  }

  clearExpansionCandidates() {
    if (!this._expansionOverlays) return;
    for (const s of this._expansionOverlays) s.destroy();
    this._expansionOverlays = [];
  }

  // Public: switch the heatmap overlay between Normal / Pollution /
  // Desirability. Rebuilds the overlay sprites from state.tileMap
  // (which carries the per-tile metric values pulled from
  // map_tiles). When mode === 'normal' the overlay is cleared
  // entirely.
  setHeatmapMode(mode) {
    this._heatmapMode = mode;
    this._renderHeatmap();
  }

  // Re-apply the current heatmap, called after each tick when the
  // server's pollution recompute may have changed tile values.
  refreshHeatmap() {
    if (this._heatmapMode !== 'normal') this._renderHeatmap();
  }

  _renderHeatmap() {
    for (const s of this._heatmapOverlays) s.destroy();
    this._heatmapOverlays = [];
    if (this._heatmapMode === 'normal') return;

    // 'crime' needs the set of police-covered tiles (red on uncovered).
    // 'issues' needs the set of problematic-building tiles (red overlay).
    let policeCovered = null;
    let problemTiles = null;
    if (this._heatmapMode === 'crime') policeCovered = this._computePoliceCoverage();
    if (this._heatmapMode === 'issues') problemTiles = this._computeProblemTiles();

    // Pollution + desirability paint the city-wide metric set
    // (loaded separately by refreshCityTileMetrics so a fetch error
    // doesn't break boot). Crime + building-issues stay scoped to
    // YOUR tiles — your police only cover your land. If the city-wide
    // fetch hasn't landed yet, fall back to local tiles.
    const isCityWide = this._heatmapMode === 'pollution' || this._heatmapMode === 'desirability';
    const cityMetrics = state.cityTileMetrics || {};
    const cityWideHasData = Object.keys(cityMetrics).length > 0;
    const source = (isCityWide && cityWideHasData) ? cityMetrics : state.tileMap;

    for (const k in source) {
      const t = source[k];
      let value;
      if (this._heatmapMode === 'pollution') value = Number(t.pollution || 0);
      else if (this._heatmapMode === 'desirability') value = Number(t.desirability || 0);
      else if (this._heatmapMode === 'crime') value = policeCovered.has(k) ? 0 : 100;
      else if (this._heatmapMode === 'issues') value = problemTiles.has(k) ? 100 : 0;
      else value = 0;

      const { tint, alpha } = heatmapTintFor(this._heatmapMode, value);
      if (alpha <= 0) continue;
      const worldX = (t.x - state.gridMinX) * TILE_PX + TILE_PX / 2;
      const worldY = (t.y - state.gridMinY) * TILE_PX + TILE_PX / 2;
      const overlay = this.add.sprite(worldX, worldY, 'square');
      overlay.setTint(tint);
      overlay.setAlpha(alpha);
      overlay.setDepth(2);
      this._heatmapOverlays.push(overlay);
    }
  }

  // Set of "x,y" tile keys that fall inside any of THIS player's
  // staffed active police buildings' manhattan coverage radius.
  // Used by the crime-risk heatmap to red-tint uncovered tiles.
  _computePoliceCoverage() {
    return _computePoliceCoverage(state.allBuildings, state.buildingTypes, state.currentUser?.id);
  }
  _computeProblemTiles() {
    return _computeProblemTiles(state.allBuildings, state.buildingTypes, state.currentUser?.id);
  }

  // Called by BuildMenu when the player picks a building type to
  // place. Pass null to cancel placement.
  setPlacementMode(buildingType) {
    // Tear down any prior ghost + AoE preview.
    if (this._placementMode?.ghostSprite) {
      this._placementMode.ghostSprite.destroy();
    }
    this._clearPlacementAoe();
    if (!buildingType) {
      this._placementMode = null;
      hidePlacementBar();
      hideDragCost();
      return;
    }
    showPlacementBar(buildingType, () => {
      this.setPlacementMode(null);
      clearBuildSelection();
    });
    const fw = buildingType.footprint_w || 1;
    const fh = buildingType.footprint_h || 1;
    const ghost = this.add.sprite(0, 0, 'square');
    ghost.setScale(fw - 0.15, fh - 0.15);
    ghost.setTint(0x16c79a);
    ghost.setAlpha(0.55);
    ghost.setDepth(900);
    // Compute AoE for buildings whose coverage matters during
    // placement — service / police / park / booster. The preview
    // overlay re-positions as the ghost moves so the player can
    // see exactly which tiles a candidate placement would cover.
    const aoe = getBuildingAoeRange({ x: 0, y: 0 }, buildingType);
    this._placementMode = {
      buildingType, ghostSprite: ghost, fw, fh,
      aoeRange: aoe?.range || 0,
      aoeKind: aoe?.kind || null,
      aoeSprites: []
    };
  }

  // Update the AoE preview to ring the current ghost tile. Called
  // from pointermove. Allocates sprites lazily (only when needed)
  // and reuses them across pointermove ticks to avoid churn.
  _updatePlacementAoe(anchorX, anchorY) {
    const pm = this._placementMode;
    if (!pm || !pm.aoeRange) return;

    // Footprint-aware disk: union of manhattan disks around every
    // footprint cell. Same formula the inspector uses.
    const cells = new Set();
    for (let dx = 0; dx < pm.fw; dx++) {
      for (let dy = 0; dy < pm.fh; dy++) {
        for (let rx = -pm.aoeRange; rx <= pm.aoeRange; rx++) {
          for (let ry = -pm.aoeRange; ry <= pm.aoeRange; ry++) {
            if (Math.abs(rx) + Math.abs(ry) <= pm.aoeRange) {
              cells.add((anchorX + dx + rx) + ',' + (anchorY + dy + ry));
            }
          }
        }
      }
    }

    const tint = AOE_TINTS[pm.aoeKind] || 0x16c79a;
    let idx = 0;
    for (const k of cells) {
      const [x, y] = k.split(',').map(Number);
      const wx = (x - state.gridMinX) * TILE_PX + TILE_PX / 2;
      const wy = (y - state.gridMinY) * TILE_PX + TILE_PX / 2;
      let sprite = pm.aoeSprites[idx];
      if (!sprite) {
        sprite = this.add.sprite(wx, wy, 'square');
        sprite.setTint(tint);
        sprite.setAlpha(0.22);
        sprite.setDepth(890);   // below ghost (900)
        pm.aoeSprites.push(sprite);
      } else {
        sprite.x = wx;
        sprite.y = wy;
        sprite.setVisible(true);
      }
      idx++;
    }
    // Hide any leftover sprites from previous ticks (size-varying
    // is rare since the AoE radius is constant, but keeps things clean).
    for (let i = idx; i < pm.aoeSprites.length; i++) {
      pm.aoeSprites[i].setVisible(false);
    }
  }

  _clearPlacementAoe() {
    if (!this._placementMode?.aoeSprites) return;
    for (const s of this._placementMode.aoeSprites) s.destroy();
    this._placementMode.aoeSprites = [];
  }

  // Re-render hook for the tick / realtime layers. Calls into the
  // diff-based _renderBuildings, which only touches sprites whose
  // visual state actually changed. Stable buildings keep their
  // existing sprite + animations — no churn, no walker stutter
  // (Atlas 2026-05-11).
  rerenderBuildings() {
    this._renderBuildings();
  }

  // Re-render only the tile layer. Used after a tile-state change
  // (e.g. clear_resource_tile RPC) to refresh the resource icon
  // without rebuilding buildings or the heatmap.
  rerenderTiles() {
    for (const s of this._tileSprites.values()) s.destroy();
    this._tileSprites.clear();
    this._renderTiles();
    if (this._heatmapMode !== 'normal') this._renderHeatmap();
  }

  // Full world rerender — tiles, buildings, heatmap, camera bounds.
  // Used after expand_district adds new chunks to the parcel. The
  // grid origin (state.gridMinX/Y) can shift when the new parcel
  // extends past the previous min — building world-pixel coords are
  // (b.x - gridMinX) * TILE_PX, so a shifted origin means every
  // existing sprite is at the WRONG screen position. The diff-based
  // _renderBuildings keys on b.x/b.y in the signature, NOT on the
  // origin, so a stale entry won't trigger rebuild on its own.
  //
  // Solution: force-destroy every cached building entry so the next
  // _renderBuildings rebuilds them all from scratch against the new
  // origin. One-shot cost; happens only on expansion (not per-tick).
  rerenderWorld() {
    for (const s of this._tileSprites.values()) s.destroy();
    this._tileSprites.clear();
    for (const s of this._heatmapOverlays) s.destroy();
    this._heatmapOverlays = [];
    this.clearAoe();
    this.clearSelection();
    // Nuke the building entry cache so _renderBuildings recomputes
    // every sprite's world position against the (possibly shifted)
    // state.gridMinX/Y.
    if (this._buildingEntries) {
      for (const entry of this._buildingEntries.values()) {
        this._destroyBuildingEntry(entry, /*keepSprite*/ false);
      }
      this._buildingEntries.clear();
    }
    this._renderTiles();
    this._renderBuildings();
    if (this._heatmapMode !== 'normal') this._renderHeatmap();

    // Update camera bounds to the new world size, with the same
    // slack as _setupCamera so the player can still pan past the
    // bottom edge under the inspector + bottom panel.
    this._worldW = state.gridCols * TILE_PX;
    this._worldH = state.gridRows * TILE_PX;
    this._applyCameraBounds();
  }

  // Sets camera.setBounds with the wilderness slack on all sides plus
  // an extra-tall bottom slack to clear the bottom panel + inspector
  // when the player is zoomed all the way out. Shared between scene
  // boot (_setupCamera) and post-expansion rebuild (rerenderWorld).
  _applyCameraBounds() {
    const bounds = computeWorldBounds();
    const camLeft = (bounds.minX - state.gridMinX) * TILE_PX;
    const camTop  = (bounds.minY - state.gridMinY) * TILE_PX;
    const camW = bounds.cols * TILE_PX;
    const camH = bounds.rows * TILE_PX;
    const SLACK = 10 * TILE_PX;
    const BOTTOM_PANEL_SLACK = 24 * TILE_PX;
    this.cameras.main.setBounds(
      camLeft - SLACK,
      camTop - SLACK,
      camW + SLACK * 2,
      camH + SLACK + BOTTOM_PANEL_SLACK
    );
  }

  _renderTiles() {
    // Wilderness backdrop covering the entire bounded world. Without
    // this, neighbors' buildings would float on the page background.
    // One big sprite — cheap, one draw call.
    const bounds = computeWorldBounds();
    if (bounds.cols > 0) {
      const camLeft = (bounds.minX - state.gridMinX) * TILE_PX;
      const camTop  = (bounds.minY - state.gridMinY) * TILE_PX;
      const back = this.add.sprite(camLeft + bounds.cols * TILE_PX / 2,
                                   camTop + bounds.rows * TILE_PX / 2,
                                   'square');
      back.setDisplaySize(bounds.cols * TILE_PX, bounds.rows * TILE_PX);
      back.setTint(TERRAIN_TINTS.wilderness);
      back.setDepth(-1);
    }

    this._ensureGrassTextures();

    // Render every owned tile, plus a small dot for tiles that
    // carry a resource node (timber grove, stone outcrop, iron
    // deposit, etc.). Players need to see resource tiles so they
    // know where to place extractors. v1 used a `<div class="res-dot">`
    // for this; Phaser equivalent is a tinted circle sprite on top.
    for (const k in state.tileMap) {
      const t = state.tileMap[k];
      const worldX = (t.x - state.gridMinX) * TILE_PX + TILE_PX / 2;
      const worldY = (t.y - state.gridMinY) * TILE_PX + TILE_PX / 2;

      let tile;
      if (t.terrain_type === 'grass' || !TERRAIN_TINTS[t.terrain_type]) {
        // Grass — pick one of 4 noise variants by hash(x,y) so
        // adjacent tiles read as a continuous textured field rather
        // than a stamped checkerboard. Same hash always returns the
        // same variant so tiles don't flicker on re-renders.
        const h = tileHash(t.x, t.y);
        const variant = h % 4;
        tile = this.add.sprite(worldX, worldY, 'grass-v' + variant);

        // ~30% of tiles get a small decoration overlay (flower,
        // pebble, clover, poppy, dirt patch, etc). Position offset
        // also derived from hash so each tile's decoration sits in
        // a stable spot rather than centered every time.
        if ((h % 100) < 30) {
          const decoIdx = (h >> 4) & 7;     // 0..7
          const dx = ((h >> 9)  & 15) - 7;  // -7..+8 px offset
          const dy = ((h >> 13) & 15) - 7;
          // Decorations render at default depth (0) — same as both
          // tiles and buildings. _renderTiles runs before
          // _renderBuildings, so insertion order keeps decorations
          // under buildings but above the wilderness backdrop (-1).
          const deco = this.add.sprite(worldX + dx, worldY + dy, 'gdeco-' + decoIdx);
          this._tileSprites.set(t.x + ',' + t.y + ':deco', deco);
        }
      } else {
        tile = this.add.sprite(worldX, worldY, 'square');
        tile.setTint(TERRAIN_TINTS[t.terrain_type]);
      }
      this._tileSprites.set(t.x + ',' + t.y, tile);

      if (t.resource_node_key) {
        const res = state.resourceNodes[t.resource_node_key];
        const kind = resourceKindFor(t.resource_node_key, res);
        const tex = `res-${kind}`;
        const iconKey = this.textures.exists(tex) ? tex : 'res-default';
        const icon = this.add.sprite(worldX, worldY, iconKey);
        icon.setDepth(5);
      }
    }
  }

  // Diff-based building render. Maintains a Map keyed by building.id
  // of { sprite, anims, sig } entries. On each call we recompute the
  // signature for every building in state and only touch sprites
  // whose sig actually changed. Stable buildings (the vast majority
  // on a per-tick UPDATE) keep their existing sprite + animations
  // — no GameObject churn, no stutter.
  //
  // Cost model:
  //   - N = total buildings in shared world
  //   - K = buildings whose visual state changed since last render
  //   The old version did O(N) destroys + O(N) creates every call.
  //   This does O(N) signature compares + O(K) creates/updates.
  //   K is usually 0–3 (the buildings touched by the realtime UPDATE).
  _renderBuildings() {
    const myId = state.currentUser?.id;

    // Initialize the entry index lazily; persists across re-renders.
    if (!this._buildingEntries) this._buildingEntries = new Map();
    const entries = this._buildingEntries;

    // Road set (used for autotile lookups + the walker pathfinder).
    // Need to compute first so each road's signature can include its
    // NSEW mask — a road tile re-textures whenever a neighbor lands.
    const roadSet = new Set();
    for (const b of state.allBuildings) {
      const bt = state.buildingTypes[b.building_type_key];
      if (bt && bt.category === 'road') roadSet.add(b.x + ',' + b.y);
    }
    this._roadSet = roadSet;

    // Rebuild the anchor map every render — cheap O(N) Map populate,
    // and tap-to-inspect needs an up-to-date b reference at each
    // (x,y) for tier/status changes to read correctly.
    this._buildingAtAnchor.clear();

    const seen = new Set();
    for (const b of state.allBuildings) {
      const bt = state.buildingTypes[b.building_type_key];
      if (!bt) continue;
      seen.add(b.id);
      this._buildingAtAnchor.set(b.x + ',' + b.y, b);

      // Compute operational issue (paused / idle / unstaffed / no-road /
      // no-input) once and use it both for the signature (so the diff
      // detects transitions) and for the per-building render (fade +
      // `!` badge). null for healthy and for other players' buildings.
      const issue = computeBuildingIssue(b, bt, roadSet, state.inventory, myId);
      const sig = buildingSignature(b, bt, roadSet, myId, issue?.kind);
      const prev = entries.get(b.id);
      if (prev && prev.sig === sig) {
        // No visual change. Still refresh buildingRef so taps read
        // the latest row (status / tier / paused might have shifted
        // even when the signature happens to collide).
        prev.sprite.buildingRef = b;
        continue;
      }

      // Either new or changed — (re)build the sprite + animations.
      if (prev) this._destroyBuildingEntry(prev, /*keepSprite*/ true);
      const entry = prev || { sprite: null, anims: [], sig };
      this._renderOneBuilding(entry, b, bt, roadSet, myId, issue);
      entry.sig = sig;
      entries.set(b.id, entry);
    }

    // Drop sprites for buildings that disappeared from state.
    for (const [id, entry] of entries) {
      if (!seen.has(id)) {
        this._destroyBuildingEntry(entry, /*keepSprite*/ false);
        entries.delete(id);
      }
    }
  }

  // Build (or update in place) the sprite + animations for a single
  // building. Called from _renderBuildings only. `issue` is the result
  // of computeBuildingIssue (null when healthy) — drives the fade +
  // `!` badge for own-player buildings that aren't operational.
  _renderOneBuilding(entry, b, bt, roadSet, myId, issue) {
    const fw = bt.footprint_w || 1;
    const fh = bt.footprint_h || 1;
    const worldX = (b.x - state.gridMinX) * TILE_PX + (fw * TILE_PX) / 2;
    const worldY = (b.y - state.gridMinY) * TILE_PX + (fh * TILE_PX) / 2;

    const isRoad = bt.category === 'road';
    let texKey;
    if (isRoad) {
      const n = roadSet.has(b.x + ',' + (b.y - 1)) ? 8 : 0;
      const s = roadSet.has(b.x + ',' + (b.y + 1)) ? 4 : 0;
      const e = roadSet.has((b.x + 1) + ',' + b.y) ? 2 : 0;
      const w = roadSet.has((b.x - 1) + ',' + b.y) ? 1 : 0;
      texKey = 'road-' + (n | s | e | w);
    } else if (bt.category === 'housing' && b.housing_tier !== undefined) {
      // Housing tier evolves the sprite (Shanty t0 → Mud Hut t1 → ...
      // → Palace t8). 9 tier-specific textures are loaded at boot.
      const tierKey = 'house-t' + Math.max(0, Math.min(8, b.housing_tier));
      texKey = this.textures.exists(tierKey) ? tierKey : 'square';
    } else {
      texKey = this.textures.exists(b.building_type_key) ? b.building_type_key : 'square';
    }

    // Re-use the existing sprite if one's there (avoids the destroy/
    // create roundtrip when only e.g. is_staffed changed). Update
    // its texture if the type/autotile shifted, then re-apply scale/
    // tint/alpha/interactive every time so the visual matches.
    let sprite = entry.sprite;
    if (!sprite) {
      sprite = this.add.sprite(worldX, worldY, texKey);
      entry.sprite = sprite;
    } else {
      sprite.setPosition(worldX, worldY);
      if (sprite.texture.key !== texKey) sprite.setTexture(texKey);
      sprite.clearTint();
    }

    if (isRoad || texKey !== 'square') {
      sprite.setScale(1);
      sprite.setDisplaySize(fw * TILE_PX, fh * TILE_PX);
    } else {
      sprite.setScale(fw - 0.15, fh - 0.15);
      sprite.setTint(CATEGORY_TINTS[bt.category] || 0x888888);
    }
    // Alpha precedence: neighbor (0.7) > issue (0.55) > healthy (1.0).
    // Roads stay fully opaque regardless of issue state — they're
    // infrastructure, the badge would just clutter the network.
    let alpha = 1;
    if (b.player_id !== myId) alpha = 0.7;
    else if (issue && !isRoad) alpha = 0.55;
    sprite.setAlpha(alpha);
    sprite.setInteractive({ useHandCursor: true });
    sprite.buildingRef = b;

    // Old animation sprites belonged to the previous incarnation —
    // destroy them and spawn a fresh set if the building qualifies.
    for (const a of entry.anims) a.destroy();
    entry.anims = [];
    this._spawnBuildingAnimations(b, bt, worldX, worldY, fw, fh, entry.anims, issue);
  }

  // Tear down a building entry. `keepSprite=true` leaves the main
  // sprite in place so the next _renderOneBuilding can re-use it
  // (avoiding a destroy+create roundtrip for a same-position update).
  _destroyBuildingEntry(entry, keepSprite) {
    for (const a of entry.anims) a.destroy();
    entry.anims = [];
    if (!keepSprite && entry.sprite) {
      entry.sprite.destroy();
      entry.sprite = null;
    }
  }

  // Spawn smoke / glow / figure sprites for a building based on its
  // animation profile + active-staffed gate. Spawned sprites are
  // pushed into the `sink` array (the entry's `anims` list) so the
  // diff-render can tear them down individually when the building's
  // signature changes.
  //
  // When `issue` is non-null, the building is in a problem state
  // (paused / idle / unstaffed / no-road / missing-input). We skip
  // the happy animations entirely and draw a red `!` badge in the
  // top-right corner so the player can scan for broken chains on a
  // busy map without opening every inspector. Roads suppress the
  // badge so the network doesn't get visually noisy.
  _spawnBuildingAnimations(b, bt, worldX, worldY, fw, fh, sink, issue) {
    if (issue && bt.category !== 'road') {
      const badgeX = worldX + (fw * TILE_PX) / 2 - 10;
      const badgeY = worldY - (fh * TILE_PX) / 2 + 10;
      // Paused gets a softer gray ⏸ badge; everything else is the
      // attention-grabbing red `!` so players can scan urgent issues
      // separately from "I deliberately turned this off".
      const isPaused = issue.kind === 'paused';
      const badge = this.add.text(badgeX, badgeY, issue.symbol || '!', {
        fontFamily: 'system-ui, sans-serif',
        fontSize: '13px',
        color: '#ffffff',
        backgroundColor: isPaused ? '#888888' : '#e94560',
        padding: { left: 5, right: 5, top: 1, bottom: 1 },
        fontStyle: 'bold'
      }).setOrigin(0.5).setDepth(12);
      badge.issueLabel = issue.label;
      sink.push(badge);
      return;
    }
    if (b.status !== 'active' || !b.is_staffed) return;
    const profile = BUILDING_ANIM_PROFILES[b.building_type_key];
    if (!profile) return;

    if (profile.glow) {
      // Smaller focal sprite (~70% of tile) instead of a full-tile
      // wash, and a much gentler alpha range so the pulse reads as
      // "fire visible through a window" rather than "the whole
      // building tinting on and off". Atlas's report on charcoal_kiln
      // was that the wider tween read as a "darker to lighter on the
      // background" effect — same root cause across every glow.
      const glow = this.add.sprite(worldX, worldY, 'square');
      glow.setDisplaySize(fw * TILE_PX * 0.7, fh * TILE_PX * 0.7);
      glow.setTint(profile.glow);
      glow.setAlpha(0.04);
      glow.setDepth(7);
      glow.setBlendMode(Phaser.BlendModes.ADD);
      this.tweens.add({
        targets: glow,
        alpha: 0.14,
        duration: 1400 + Math.random() * 600,
        yoyo: true,
        repeat: -1,
        ease: 'Sine.easeInOut'
      });
      sink.push(glow);
    }

    if (profile.smoke) {
      // Smoke rises from the building's roughly-top-center, drifts
      // randomly, and fades. Three puffs offset in time give a
      // continuous plume without a particle system.
      const baseX = worldX;
      const baseY = worldY - fh * TILE_PX * 0.45;
      for (let i = 0; i < 3; i++) {
        const puff = this.add.sprite(baseX, baseY, 'puff');
        puff.setScale(0.6);
        puff.setAlpha(0);
        puff.setDepth(9);
        const drift = (Math.random() - 0.5) * 12;
        const duration = 2400 + Math.random() * 800;
        this.tweens.add({
          targets: puff,
          y: baseY - 36,
          x: baseX + drift,
          alpha: { from: 0.55, to: 0 },
          scale: { from: 0.5, to: 1.0 },
          duration,
          delay: i * (duration / 3),
          repeat: -1,
          onRepeat: () => {
            puff.x = baseX;
            puff.y = baseY;
          }
        });
        sink.push(puff);
      }
    }

    if (profile.figure) {
      // A small bobbing person on top of the building — the "worker
      // figure" effect for services + police. Uses the building-
      // specific walker variant so a temple shows a priest, a school
      // shows a scholar, etc.
      const figX = worldX + (Math.random() - 0.5) * fw * TILE_PX * 0.4;
      const figY = worldY + fh * TILE_PX * 0.2;
      const variant = pickWalkerVariant(b, bt);
      const fig = this.add.sprite(figX, figY, 'walker-' + variant);
      fig.setDisplaySize(WALKER_PX_W, WALKER_PX_H);
      fig.setDepth(11);
      this.tweens.add({
        targets: fig,
        y: figY - 4,
        duration: 500 + Math.random() * 300,
        yoyo: true,
        repeat: -1,
        ease: 'Sine.easeInOut'
      });
      this.tweens.add({
        targets: fig,
        x: figX + (Math.random() < 0.5 ? -12 : 12),
        duration: 2400 + Math.random() * 1000,
        yoyo: true,
        repeat: -1,
        ease: 'Sine.easeInOut'
      });
      sink.push(fig);
    }
  }

  _setupCamera() {
    // Tile rendering uses state.gridMinX/Y as world origin (own
    // parcel anchored at 0,0). Other players' buildings render at
    // negative or out-of-parcel coordinates relative to that origin.
    // Set the camera bounds to the rectangle that wraps the union
    // of every visible tile + building so the player can pan to
    // neighbors south/east/etc of their own land.
    const bounds = computeWorldBounds();
    const camLeft = (bounds.minX - state.gridMinX) * TILE_PX;
    const camTop  = (bounds.minY - state.gridMinY) * TILE_PX;
    const camW = bounds.cols * TILE_PX;
    const camH = bounds.rows * TILE_PX;
    // Expose for ZoomControls' reset button (centers on own parcel).
    this._worldW = state.gridCols * TILE_PX;
    this._worldH = state.gridRows * TILE_PX;

    const cam = this.cameras.main;
    this._applyCameraBounds();
    // Restore saved scroll + zoom for this player if we have it.
    // localStorage key is scoped per user so different accounts on the
    // same browser don't clobber each other. If nothing saved, center
    // on the player's own parcel — they expect to see their city on
    // load, not the world centroid.
    const restored = this._loadSavedMapView();
    if (restored) {
      cam.setZoom(Phaser.Math.Clamp(restored.zoom, 0.25, 3));
      cam.scrollX = restored.scrollX;
      cam.scrollY = restored.scrollY;
    } else {
      cam.centerOn(this._worldW / 2, this._worldH / 2);
    }

    // Drag-to-pan, but only when we're not drag-painting roads.
    // Otherwise the same drag motion both paints AND scrolls and the
    // road never goes down because the cursor's world position is
    // being pulled out from under it (Atlas 2026-05-11).
    this.input.on('pointermove', (pointer) => {
      if (!pointer.isDown) return;
      if (this._dragPaintActive) return;
      cam.scrollX -= (pointer.x - pointer.prevPosition.x) / cam.zoom;
      cam.scrollY -= (pointer.y - pointer.prevPosition.y) / cam.zoom;
      this._saveMapViewSoon();
    });

    // Wheel zoom (desktop). Preserves the world point under the
    // cursor across the zoom — without this, the camera's setZoom
    // anchor on the camera centroid and the visible content slides
    // away from where the player was pointing.
    this.input.on('wheel', (pointer, _o, _dx, dy) => {
      const before = cam.getWorldPoint(pointer.x, pointer.y);
      cam.setZoom(Phaser.Math.Clamp(cam.zoom * (dy > 0 ? 0.9 : 1.1), 0.25, 3));
      const after = cam.getWorldPoint(pointer.x, pointer.y);
      cam.scrollX -= (after.x - before.x);
      cam.scrollY -= (after.y - before.y);
      this._saveMapViewSoon();
    });
    // Mobile zoom UI lives in DOM (ZoomControls.js) so it isn't
    // affected by the camera's zoom transform.

    // Escape cancels placement + expansion preview. Useful muscle
    // memory from v1 (and just standard "I changed my mind" affordance).
    // Bound at document scope so it works even if the canvas hasn't
    // grabbed focus; ignored if a panel input has focus.
    this._escHandler = (e) => {
      if (e.key !== 'Escape') return;
      const t = document.activeElement;
      if (t && ['INPUT', 'TEXTAREA', 'SELECT'].includes(t.tagName)) return;
      if (this._placementMode) {
        this.setPlacementMode(null);
        e.preventDefault();
      } else if (this._expansionOverlays?.length > 0) {
        this.clearExpansionCandidates();
        e.preventDefault();
      }
    };
    document.addEventListener('keydown', this._escHandler);
  }

  // ── Map view persistence ──────────────────────────────────────
  //
  // Saves scroll + zoom to localStorage so a page reload lands the
  // player on the same view they left. Keyed per Supabase user id so
  // multiple accounts on the same browser keep separate views.
  //
  // Debounced to ~400ms because pan generates a flood of pointermove
  // events — we only need the steady-state result.
  _mapViewKey() {
    const uid = state.currentUser?.id;
    return uid ? 'city_map_view_v2_' + uid : null;
  }

  _saveMapViewSoon() {
    if (this._saveViewTimer) clearTimeout(this._saveViewTimer);
    this._saveViewTimer = setTimeout(() => this._saveMapView(), 400);
  }

  _saveMapView() {
    const key = this._mapViewKey();
    if (!key) return;
    const cam = this.cameras.main;
    try {
      localStorage.setItem(key, JSON.stringify({
        scrollX: cam.scrollX, scrollY: cam.scrollY, zoom: cam.zoom
      }));
    } catch (_e) {
      // Storage disabled / quota exceeded — silent. View persistence
      // is a convenience, not a contract.
    }
  }

  _loadSavedMapView() {
    const key = this._mapViewKey();
    if (!key) return null;
    try {
      const raw = localStorage.getItem(key);
      if (!raw) return null;
      const parsed = JSON.parse(raw);
      if (typeof parsed?.scrollX !== 'number' || typeof parsed?.scrollY !== 'number'
          || typeof parsed?.zoom !== 'number') return null;
      return parsed;
    } catch (_e) {
      return null;
    }
  }

  _setupTapToInspect() {
    // Differentiate tap from drag-pan: if the pointer moved more than
    // a few pixels between down and up, it was a drag; otherwise a
    // tap. Only taps trigger inspector or placement.
    let downX = 0, downY = 0, downAtMs = 0;
    this.input.on('pointerdown', (p) => {
      downX = p.x; downY = p.y; downAtMs = performance.now();

      // Drag-paint for roads: if placement mode is active and the
      // selected type is road (1x1, no resource gating), start a
      // paint sequence so the player can lay a long road in one
      // sweep instead of tapping each tile.
      if (this._placementMode?.buildingType.category === 'road') {
        this._dragPaintActive = true;
        this._dragPaintPlaced.clear();
        this._paintAtPointer(p);
      }
    });

    // Ghost sprite follows the cursor when placement mode is active.
    // For multi-tile buildings the anchor is the top-left footprint
    // tile, so the player sees the building exactly where it will
    // be placed (matches the server's `place_building` semantics
    // which use the clicked tile as the anchor).
    this.input.on('pointermove', (p) => {
      if (this._placementMode) {
        const world = this.cameras.main.getWorldPoint(p.x, p.y);
        const gx = Math.floor(world.x / TILE_PX);
        const gy = Math.floor(world.y / TILE_PX);
        const { fw, fh, ghostSprite } = this._placementMode;
        ghostSprite.x = gx * TILE_PX + (fw * TILE_PX) / 2;
        ghostSprite.y = gy * TILE_PX + (fh * TILE_PX) / 2;

        // Anchor coords in world tile space (add gridMinX back, since
        // the inner ghost rendering used pure render coordinates).
        this._updatePlacementAoe(gx + state.gridMinX, gy + state.gridMinY);

        if (this._dragPaintActive && p.isDown) this._paintAtPointer(p);
      }
    });

    this.input.on('pointerup', async (p, currentlyOver) => {
      // Drag-paint always ends on pointerup, regardless of distance.
      if (this._dragPaintActive) {
        this._dragPaintActive = false;
        this._dragPaintPlaced.clear();
        hideDragCost();
        return;
      }

      const dx = p.x - downX, dy = p.y - downY;
      const moved = Math.hypot(dx, dy);
      const heldMs = performance.now() - downAtMs;
      if (moved > 8 || heldMs > 500) return;

      // Placement mode: tap = try to place the building here.
      if (this._placementMode) {
        const tile = this._tileAtPointer(p);
        if (!tile) {
          showToast("That tile isn't in your parcel.", 'error');
          return;
        }
        const btKey = this._placementMode.buildingType.key;
        try {
          await placeBuilding(tile.id, btKey);
          showToast('Placed.', 'success');
          if (this._placementMode.buildingType.category !== 'road') {
            this.setPlacementMode(null);
            clearBuildSelection();
          }
        } catch (err) {
          showToast(err.message || 'Could not place building.', 'error');
        }
        return;
      }

      // Inspect mode (default): tap on a building → building inspector;
      // tap on a walker → walker info card; tap on a resource tile →
      // tile inspector. Building > walker priority because a walker
      // standing on a building cell would otherwise eat the building tap.
      if (currentlyOver && currentlyOver.length > 0) {
        for (const obj of currentlyOver) {
          if (obj.buildingRef) {
            openInspector(obj.buildingRef);
            return;
          }
        }
        for (const obj of currentlyOver) {
          if (obj.walkerInfo) {
            openWalkerInfo(obj, this._walkers);
            return;
          }
        }
      }
      const tile = this._tileAtPointer(p);
      if (tile && tile.resource_node_key) {
        openResourceTileInspector(tile);
        return;
      }
      closeInspector();
    });
  }

  // Helper: return the tile (with id) at the current pointer position,
  // or null if the pointer is outside the player's parcel.
  _tileAtPointer(p) {
    const world = this.cameras.main.getWorldPoint(p.x, p.y);
    const gx = Math.floor(world.x / TILE_PX) + state.gridMinX;
    const gy = Math.floor(world.y / TILE_PX) + state.gridMinY;
    return state.tileMap[gx + ',' + gy] || null;
  }

  // Drag-paint helper. Fires place_building for the tile under the
  // cursor at most once per drag sequence — _dragPaintPlaced tracks
  // which tiles we've already submitted so revisiting one (e.g., the
  // user sweeps back over a tile) doesn't double-call the RPC.
  async _paintAtPointer(p) {
    const tile = this._tileAtPointer(p);
    if (!tile) return;
    const key = tile.id;
    if (this._dragPaintPlaced.has(key)) return;
    this._dragPaintPlaced.add(key);
    const bt = this._placementMode.buildingType;
    const total = this._dragPaintPlaced.size;
    showDragCost(total, total * (bt.build_cost || 0));
    try {
      await placeBuilding(tile.id, bt.key);
    } catch (_err) {
      // Silent during drag-paint — alerting on every failed tile
      // (already-occupied / not adjacent / no road) would spam.
      // The successful tiles still go down.
    }
  }
}
