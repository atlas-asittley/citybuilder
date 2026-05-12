// The main game scene. Reads from state.tileMap + state.allBuildings
// (populated by state/loader.js after auth) and renders them as
// Phaser sprites. Handles input: drag-pan, wheel-zoom, tap to
// inspect, tap-to-place / drag-paint roads in placement mode, and
// inspector AoE highlights.
import Phaser from 'phaser';
import { state } from '../state/store.js';
import { openInspector, closeInspector } from '../ui/InspectorPanel.js';
import { placeBuilding } from '../api/buildings.js';
import { clearSelection as clearBuildSelection } from '../ui/BuildMenu.js';
import { spriteIcons } from '../sprites.js';
import { WALKER_SPRITES } from '../walker_sprites.js';

const TILE_PX = 48;
// Lower cap + slightly slower spawn cadence after Atlas reported
// "started to lag a little bit with those walkers" — the detailed
// SVG sprites cost more compositor work per frame than the dot
// placeholders, so we run fewer of them simultaneously.
const MAX_WALKERS = 50;
const WALKER_SPAWN_MS = 800;
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

// Inject explicit width/height into a walker SVG data URI so the
// browser rasterizes it at a known small size. Returns a new
// data URI with width="<vb_w * 4>" height="<vb_h * 4>" added. If
// the viewBox can't be parsed, returns the input unchanged.
function sizeWalkerSvg(dataUri) {
  const m = dataUri.match(/viewBox='([\d.\s]+)'/);
  if (!m) return dataUri;
  const parts = m[1].split(/\s+/);
  if (parts.length !== 4) return dataUri;
  const vbW = parseFloat(parts[2]);
  const vbH = parseFloat(parts[3]);
  if (!Number.isFinite(vbW) || !Number.isFinite(vbH)) return dataUri;
  const w = Math.round(vbW * 4);
  const h = Math.round(vbH * 4);
  return dataUri.replace(/<svg\s+/, `<svg width='${w}' height='${h}' `);
}

// Building → walker variant key. Picks the v1 walker SVG that best
// fits the source building. Housing spawns one of four "citizen"
// personas at random for visual variety; specific industries spawn
// their job-specific worker; services spawn their domain figure.
function pickWalkerVariant(b, bt) {
  if (bt.category === 'housing') {
    const personas = ['citizen', 'child', 'elder', 'fat', 'couple'];
    return personas[Math.floor(Math.random() * personas.length)];
  }
  const key = b.building_type_key || '';
  if (key === 'timber_camp')   return 'timber';
  if (key === 'sawmill')       return 'sawmill';
  if (key === 'stone_quarry')  return 'stone';
  if (key === 'grain_farm' || key === 'mill') return 'grain';
  if (key === 'iron_mine')     return 'iron';
  if (key === 'clay_pit' || key === 'pottery_kiln' || key === 'clay_master_hut') return 'clay';
  if (key === 'orchard')       return 'orchard';
  if (key === 'fishing_pier')  return 'fish';
  if (key === 'garden')        return 'garden';
  if (key === 'tavern')        return 'tavern';
  if (key === 'bathhouse')     return 'bathhouse';
  if (key === 'school')        return 'school';
  if (key === 'temple')        return 'temple';
  if (key === 'tax_man' || key === 'foreman_office' || key === 'mine_office') return 'civic';
  return 'citizen';
}

// Resource-key → visual kind. The resources table's `kind` column
// (raw / processed / terrain) is too coarse to drive icons, so we
// derive a finer kind from the key itself. Each kind has a drawn
// texture (`res-wood`, `res-stone`, etc.) loaded at scene boot.
function resourceKindFor(resourceKey, resource) {
  // First-pass: key-substring heuristic so adding new resources
  // doesn't require updates here unless the icon should differ.
  const k = (resourceKey || '').toLowerCase();
  if (k.includes('timber') || k.includes('forest') || k.includes('orchard') || k.includes('grove')) return 'wood';
  if (k.includes('stone') || k.includes('quarry') || k.includes('rock')) return 'stone';
  if (k.includes('iron') || k.includes('ore') || k.includes('metal')) return 'metal';
  if (k.includes('clay'))   return 'clay';
  if (k.includes('grain')  || k.includes('farmland') || k.includes('field')) return 'food';
  if (k.includes('garden') || k.includes('plot'))     return 'food';
  if (k.includes('pond')   || k.includes('water')    || k.includes('lake') || k.includes('river') || k.includes('fish')) return 'fish';
  // Industry-tagged fallback if we have the resources row
  if (resource?.industry_key === 'timber') return 'wood';
  if (resource?.industry_key === 'stone')  return 'stone';
  if (resource?.industry_key === 'iron')   return 'metal';
  if (resource?.industry_key === 'clay')   return 'clay';
  return 'default';
}

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

// World bounds = the rectangle that contains every owned tile AND
// every other player's building in state.allBuildings. Used to bound
// the camera so the player can scroll to see neighbors.
function computeWorldBounds() {
  let minX = Infinity, maxX = -Infinity;
  let minY = Infinity, maxY = -Infinity;
  for (const k in state.tileMap) {
    const t = state.tileMap[k];
    if (t.x < minX) minX = t.x; if (t.x > maxX) maxX = t.x;
    if (t.y < minY) minY = t.y; if (t.y > maxY) maxY = t.y;
  }
  for (const b of state.allBuildings) {
    if (b.x < minX) minX = b.x;
    if (b.x > maxX) maxX = b.x;
    if (b.y < minY) minY = b.y;
    if (b.y > maxY) maxY = b.y;
  }
  if (!isFinite(minX)) return { minX: 0, minY: 0, cols: 0, rows: 0 };
  return { minX, minY, cols: maxX - minX + 1, rows: maxY - minY + 1 };
}

// Heatmap value → (tint, alpha). The alpha gives a fading overlay
// at low values so neutral tiles show through. Pollution: 0=no
// tint, ≥30=heavy red. Desirability: low=red overlay, mid=neutral,
// high=green overlay.
function heatmapTintFor(mode, value) {
  if (mode === 'pollution') {
    if (value <= 0) return { tint: 0, alpha: 0 };
    const t = Math.min(1, value / 30);
    return { tint: 0xff5a3a, alpha: 0.15 + t * 0.45 };
  }
  if (mode === 'desirability') {
    if (value < 30) {
      const t = (30 - value) / 30;
      return { tint: 0xc83a3a, alpha: 0.15 + t * 0.4 };
    }
    if (value > 70) {
      const t = Math.min(1, (value - 70) / 30);
      return { tint: 0x3ac860, alpha: 0.15 + t * 0.4 };
    }
    return { tint: 0, alpha: 0 };
  }
  return { tint: 0, alpha: 0 };
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
  smelter:        { smoke: true, glow: 0xff7028 },
  glassworks:     { smoke: true, glow: 0xffc858 },
  iron_mine:      { glow: 0xffa040 },
  mine_office:    { glow: 0xffa040 },
  foreman_office: { glow: 0xffd060 },
  charcoal_kiln:  { smoke: true, glow: 0xff8030 },
  lime_kiln:      { smoke: true },
  pottery_kiln:   { smoke: true, glow: 0xff8848 },
  bakery:         { smoke: true },
  brewery:        { glow: 0xffd048 },
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
  toolmaker:      { glow: 0xff8848 },

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

// Area-of-effect range + kind for a building that has gameplay
// coverage. Used to highlight affected cells when the inspector
// opens. Returns null for buildings without an AoE (housing,
// extractors, roads). Ranges match the server-side gate checks in
// `_pp_evolve_housing` for services and the building_types columns
// for police / park / booster.
function getBuildingAoeRange(b, bt) {
  if (!bt) return null;
  if (bt.category === 'police' && bt.coverage_radius > 0) {
    return { range: bt.coverage_radius, kind: 'police' };
  }
  if (bt.category === 'park' && bt.pollution_radius > 0) {
    return { range: bt.pollution_radius, kind: 'park' };
  }
  if (bt.category === 'booster' && bt.boost_range > 0) {
    return { range: bt.boost_range, kind: 'booster' };
  }
  if (bt.category === 'service') {
    if (bt.key === 'well')      return { range: 4, kind: 'well' };
    if (bt.key === 'school')    return { range: 5, kind: 'school' };
    if (bt.key === 'temple')    return { range: 6, kind: 'temple' };
    if (bt.key === 'bathhouse') return { range: 4, kind: 'bathhouse' };
  }
  return null;
}

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
    const dt = delta / 1000;
    this._walkerSpawnTimer += dt;

    if (this._walkerSpawnTimer >= WALKER_SPAWN_MS / 1000) {
      this._walkerSpawnTimer = 0;
      this._spawnRandomWalker();
    }

    const speed = 28;  // px per second along roads
    for (let i = this._walkers.length - 1; i >= 0; i--) {
      const w = this._walkers[i];
      w.life -= dt;
      if (w.life <= 0) {
        w.sprite.destroy();
        this._walkers.splice(i, 1);
        continue;
      }
      // Lerp toward the current target tile center. When close
      // enough, pick the next road tile to walk to (graph step).
      const dx = w.targetX - w.sprite.x;
      const dy = w.targetY - w.sprite.y;
      const dist = Math.hypot(dx, dy);
      if (dist < 2) {
        this._advanceWalkerToNextRoad(w);
        if (!w.targetX && !w.targetY) {
          // No connected next step — despawn cleanly.
          w.sprite.destroy();
          this._walkers.splice(i, 1);
          continue;
        }
      } else {
        w.sprite.x += (dx / dist) * speed * dt;
        w.sprite.y += (dy / dist) * speed * dt;
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
    if (this._walkers.length >= MAX_WALKERS) return;
    const myId = state.currentUser?.id;
    const candidates = state.allBuildings.filter((b) =>
      b.player_id === myId && b.is_staffed && b.status === 'active'
    );
    if (!candidates.length) return;
    const b = candidates[Math.floor(Math.random() * candidates.length)];
    const bt = state.buildingTypes[b.building_type_key];
    if (!bt) return;
    const fw = bt.footprint_w || 1;
    const fh = bt.footprint_h || 1;

    // Find a road tile adjacent to the building's footprint. If
    // there isn't one, this worker can't go anywhere — skip.
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
    if (!adjacent.length) return;
    const [startTileX, startTileY] = adjacent[Math.floor(Math.random() * adjacent.length)];

    const startX = (startTileX - state.gridMinX) * TILE_PX + TILE_PX / 2;
    const startY = (startTileY - state.gridMinY) * TILE_PX + TILE_PX / 2;

    const variant = pickWalkerVariant(b, bt);
    const sprite = this.add.sprite(startX, startY, 'walker-' + variant);
    sprite.setDisplaySize(WALKER_PX_W, WALKER_PX_H);
    sprite.setDepth(10);

    // life ~ 14 steps × ~1.7s per step ≈ 24s of road walking.
    const w = {
      sprite,
      curTileX: startTileX, curTileY: startTileY,
      prevTileX: b.x, prevTileY: b.y,   // pretend we came from the building so first step heads OUT
      targetX: startX, targetY: startY,
      life: 24
    };
    // Kick off the first step immediately so they don't sit still
    // at the doorway.
    this._advanceWalkerToNextRoad(w);
    this._walkers.push(w);
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

    // food/grain — 5 vertical wheat strands of varying heights
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
    g.generateTexture('res-food', SZ, SZ);
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

  _ensureRoadTextures() {
    if (this.textures.exists('road-0')) return;
    const SZ = TILE_PX;
    const L = Math.floor(SZ * 0.18);      // inner margin (grass shoulder)
    const R = SZ - L;                     // inner road right/bottom edge
    const RW = R - L;                     // road body width
    const TRACK = Math.max(2, Math.floor(RW * 0.18));   // worn-track width

    for (let mask = 0; mask < 16; mask++) {
      const n = !!(mask & 8), s = !!(mask & 4), e = !!(mask & 2), w = !!(mask & 1);
      const g = this.add.graphics();

      // 1. Grass background — dark earthy green, matches owned-grass tint
      g.fillStyle(0x4a6440, 1);
      g.fillRect(0, 0, SZ, SZ);

      // 2. Road body (always centered) + arms toward connected neighbors
      g.fillStyle(0x6b5436, 1);
      g.fillRect(L, L, RW, RW);
      if (n) g.fillRect(L, 0, RW, L);
      if (s) g.fillRect(L, R, RW, SZ - R);
      if (e) g.fillRect(R, L, SZ - R, RW);
      if (w) g.fillRect(0, L, L, RW);
      // Corner fills so two-arm bends look continuous
      if (n && w) g.fillRect(0, 0, L, L);
      if (n && e) g.fillRect(R, 0, SZ - R, L);
      if (s && w) g.fillRect(0, R, L, SZ - R);
      if (s && e) g.fillRect(R, R, SZ - R, SZ - R);

      // 3. Worn center track — lighter strip down the middle of each
      //    connected arm. Skipped on dead-end "stubs" so single tiles
      //    look like a clean roundabout.
      const trackOffset = Math.floor((RW - TRACK) / 2);
      g.fillStyle(0x8a7048, 1);
      if (n || s) {
        // Vertical strip through the body
        g.fillRect(L + trackOffset, L, TRACK, RW);
        if (n) g.fillRect(L + trackOffset, 0, TRACK, L);
        if (s) g.fillRect(L + trackOffset, R, TRACK, SZ - R);
      }
      if (e || w) {
        // Horizontal strip
        g.fillRect(L, L + trackOffset, RW, TRACK);
        if (e) g.fillRect(R, L + trackOffset, SZ - R, TRACK);
        if (w) g.fillRect(0, L + trackOffset, L, TRACK);
      }

      // 4. Road edges — darker line at every grass→dirt boundary.
      //    Only along edges that AREN'T connecting to a neighbor.
      g.lineStyle(1, 0x3e2a18, 0.6);
      if (!n) { g.beginPath(); g.moveTo(L, L); g.lineTo(R, L); g.strokePath(); }
      if (!s) { g.beginPath(); g.moveTo(L, R); g.lineTo(R, R); g.strokePath(); }
      if (!w) { g.beginPath(); g.moveTo(L, L); g.lineTo(L, R); g.strokePath(); }
      if (!e) { g.beginPath(); g.moveTo(R, L); g.lineTo(R, R); g.strokePath(); }

      g.generateTexture('road-' + mask, SZ, SZ);
      g.destroy();
    }
  }

  // Highlight candidate expansion chunks. Each row is { chunk_x,
  // chunk_y }; chunks are 10×10 tiles in v1 — render a dashed
  // rectangle so the player sees exactly which patches of land
  // they're buying.
  showExpansionCandidates(candidates) {
    this.clearExpansionCandidates();
    this._expansionOverlays = this._expansionOverlays || [];
    const CHUNK = 10;
    candidates.forEach((c, i) => {
      const tlx = c.chunk_x * CHUNK;
      const tly = c.chunk_y * CHUNK;
      const wx = (tlx - state.gridMinX) * TILE_PX;
      const wy = (tly - state.gridMinY) * TILE_PX;
      const size = CHUNK * TILE_PX;
      const fill = this.add.sprite(wx + size / 2, wy + size / 2, 'square');
      fill.setDisplaySize(size, size);
      fill.setTint(0x16c79a);
      fill.setAlpha(0.18);
      fill.setDepth(4);
      const label = this.add.text(wx + size / 2, wy + size / 2, '#' + (i + 1), {
        fontFamily: 'system-ui, sans-serif',
        fontSize: '32px',
        color: '#16c79a',
        fontStyle: 'bold'
      }).setOrigin(0.5).setDepth(5);
      this._expansionOverlays.push(fill, label);
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

    for (const k in state.tileMap) {
      const t = state.tileMap[k];
      const value = this._heatmapMode === 'pollution'
        ? Number(t.pollution || 0)
        : Number(t.desirability || 0);
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
      return;
    }
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

  // Full world rerender — tiles, buildings, heatmap, camera bounds.
  // Used after expand_district adds new chunks to the parcel.
  rerenderWorld() {
    for (const s of this._tileSprites.values()) s.destroy();
    this._tileSprites.clear();
    for (const s of this._heatmapOverlays) s.destroy();
    this._heatmapOverlays = [];
    this.clearAoe();
    if (this._buildingSprites) {
      for (const s of this._buildingSprites) s.destroy();
      this._buildingSprites = [];
      this._buildingAtAnchor.clear();
    }
    this._renderTiles();
    this._renderBuildings();
    if (this._heatmapMode !== 'normal') this._renderHeatmap();

    // Update camera bounds to the new world size.
    const worldW = state.gridCols * TILE_PX;
    const worldH = state.gridRows * TILE_PX;
    this._worldW = worldW;
    this._worldH = worldH;
    this.cameras.main.setBounds(0, 0, worldW, worldH);
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

    // Render every owned tile, plus a small dot for tiles that
    // carry a resource node (timber grove, stone outcrop, iron
    // deposit, etc.). Players need to see resource tiles so they
    // know where to place extractors. v1 used a `<div class="res-dot">`
    // for this; Phaser equivalent is a tinted circle sprite on top.
    for (const k in state.tileMap) {
      const t = state.tileMap[k];
      const worldX = (t.x - state.gridMinX) * TILE_PX + TILE_PX / 2;
      const worldY = (t.y - state.gridMinY) * TILE_PX + TILE_PX / 2;

      let tint = TERRAIN_TINTS[t.terrain_type] || OWNED_GRASS_TINT;
      if (t.terrain_type === 'grass') tint = OWNED_GRASS_TINT;

      const tile = this.add.sprite(worldX, worldY, 'square');
      tile.setTint(tint);
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

  _renderBuildings() {
    // Two passes:
    //   1. Build a Set of road tile keys for autotile lookups
    //   2. Render every building. Roads pick the right NSEW autotile
    //      texture based on their neighbors. Everything else uses
    //      its authored sprite (or a category-tinted square fallback).
    const myId = state.currentUser?.id;
    this._buildingSprites = this._buildingSprites || [];

    // Pass 1: collect road positions across ALL players, since
    // roads connect across parcel borders (they're part of the
    // shared network the walker pathfinder uses). Cached on the
    // scene so the walker tick can navigate without re-scanning
    // state.allBuildings every frame.
    const roadSet = new Set();
    for (const b of state.allBuildings) {
      const bt = state.buildingTypes[b.building_type_key];
      if (bt && bt.category === 'road') roadSet.add(b.x + ',' + b.y);
    }
    this._roadSet = roadSet;

    // Pass 2: render.
    for (const b of state.allBuildings) {
      const bt = state.buildingTypes[b.building_type_key];
      if (!bt) continue;
      const fw = bt.footprint_w || 1;
      const fh = bt.footprint_h || 1;

      const worldX = (b.x - state.gridMinX) * TILE_PX + (fw * TILE_PX) / 2;
      const worldY = (b.y - state.gridMinY) * TILE_PX + (fh * TILE_PX) / 2;

      const isRoad = bt.category === 'road';
      let texKey;
      if (isRoad) {
        // NSEW connectivity bitmask
        const n = roadSet.has(b.x + ',' + (b.y - 1)) ? 8 : 0;
        const s = roadSet.has(b.x + ',' + (b.y + 1)) ? 4 : 0;
        const e = roadSet.has((b.x + 1) + ',' + b.y) ? 2 : 0;
        const w = roadSet.has((b.x - 1) + ',' + b.y) ? 1 : 0;
        texKey = 'road-' + (n | s | e | w);
      } else {
        texKey = this.textures.exists(b.building_type_key) ? b.building_type_key : 'square';
      }

      const sprite = this.add.sprite(worldX, worldY, texKey);

      if (isRoad) {
        sprite.setDisplaySize(fw * TILE_PX, fh * TILE_PX);
      } else if (texKey !== 'square') {
        sprite.setDisplaySize(fw * TILE_PX, fh * TILE_PX);
      } else {
        sprite.setScale(fw - 0.15, fh - 0.15);
        sprite.setTint(CATEGORY_TINTS[bt.category] || 0x888888);
      }
      if (b.player_id !== myId) sprite.setAlpha(0.7);

      sprite.setInteractive({ useHandCursor: true });
      sprite.buildingRef = b;

      this._buildingSprites.push(sprite);
      this._buildingAtAnchor.set(b.x + ',' + b.y, b);

      this._spawnBuildingAnimations(b, bt, worldX, worldY, fw, fh);
    }
  }

  // Spawn smoke / glow sprites for a building based on its animation
  // profile + active-staffed gate. The spawned sprites get tracked on
  // _buildingSprites so they're torn down together with the building
  // sprite on next render.
  _spawnBuildingAnimations(b, bt, worldX, worldY, fw, fh) {
    if (b.status !== 'active' || !b.is_staffed) return;
    const profile = BUILDING_ANIM_PROFILES[b.building_type_key];
    if (!profile) return;

    if (profile.glow) {
      const glow = this.add.sprite(worldX, worldY, 'square');
      glow.setDisplaySize(fw * TILE_PX, fh * TILE_PX);
      glow.setTint(profile.glow);
      glow.setAlpha(0.05);
      glow.setDepth(7);
      glow.setBlendMode(Phaser.BlendModes.ADD);
      this.tweens.add({
        targets: glow,
        alpha: 0.32,
        duration: 1400 + Math.random() * 600,
        yoyo: true,
        repeat: -1,
        ease: 'Sine.easeInOut'
      });
      this._buildingSprites.push(glow);
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
        this._buildingSprites.push(puff);
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
      this._buildingSprites.push(fig);
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
    const SLACK = 5 * TILE_PX;
    cam.setBounds(camLeft - SLACK, camTop - SLACK, camW + SLACK * 2, camH + SLACK * 2);
    // Center on the player's OWN parcel — they expect to see their
    // city on load, not the world centroid.
    cam.centerOn(this._worldW / 2, this._worldH / 2);

    // Drag-to-pan, but only when we're not drag-painting roads.
    // Otherwise the same drag motion both paints AND scrolls and the
    // road never goes down because the cursor's world position is
    // being pulled out from under it (Atlas 2026-05-11).
    this.input.on('pointermove', (pointer) => {
      if (!pointer.isDown) return;
      if (this._dragPaintActive) return;
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
          alert("That tile isn't in your parcel.");
          return;
        }
        const btKey = this._placementMode.buildingType.key;
        try {
          await placeBuilding(tile.id, btKey);
          // For non-road placements, exit placement mode so the
          // player can pan / inspect again. Roads stay sticky so
          // chained taps work like drag-paint without holding.
          if (this._placementMode.buildingType.category !== 'road') {
            this.setPlacementMode(null);
            clearBuildSelection();
          }
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
    const btKey = this._placementMode.buildingType.key;
    try {
      await placeBuilding(tile.id, btKey);
    } catch (_err) {
      // Silent during drag-paint — alerting on every failed tile
      // (already-occupied / not adjacent / no road) would spam.
      // The successful tiles still go down.
    }
  }
}
