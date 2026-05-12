// Pure-logic helpers used by MainScene. Extracted into a separate
// module so they can be unit-tested without booting Phaser.
//
// Everything here is stateless or takes its state via arguments —
// no `this`, no scene refs, no DOM lookups.

// ── Building signature ──────────────────────────────────────────
//
// Pack every visual-affecting field of a building into a string so
// the diff renderer can decide whether the sprite needs updating.
// If two consecutive renders produce the same signature, the existing
// sprite + animations are kept as-is. Any change → re-render. The
// road bitmask is included so a road tile retextures when a neighbor
// is laid or removed.
export function buildingSignature(b, bt, roadSet, myId) {
  let sig = b.building_type_key + '|' + b.x + ',' + b.y;
  sig += '|t' + (b.housing_tier || 0);
  sig += '|s' + (b.status || '-');
  sig += '|w' + (b.is_staffed ? 1 : 0);
  sig += '|p' + (b.paused ? 1 : 0);
  sig += '|e' + (b.expansion_level || 0);
  sig += '|o' + (b.player_id === myId ? 'me' : 'them');
  if (bt.category === 'road') {
    const n = roadSet.has(b.x + ',' + (b.y - 1)) ? 1 : 0;
    const s = roadSet.has(b.x + ',' + (b.y + 1)) ? 1 : 0;
    const e = roadSet.has((b.x + 1) + ',' + b.y) ? 1 : 0;
    const w = roadSet.has((b.x - 1) + ',' + b.y) ? 1 : 0;
    sig += '|r' + n + s + e + w;
  }
  return sig;
}

// ── Resource-tile kind ─────────────────────────────────────────
//
// Resource-key → visual kind. The resources table's `kind` column
// (raw / processed / terrain) is too coarse to drive icons, so we
// derive a finer kind from the key itself. Each kind has a drawn
// texture (`res-wood`, `res-stone`, etc.).
export function resourceKindFor(resourceKey, resource) {
  const k = (resourceKey || '').toLowerCase();
  if (k.includes('timber') || k.includes('forest') || k.includes('orchard') || k.includes('grove')) return 'wood';
  if (k.includes('stone') || k.includes('quarry') || k.includes('rock')) return 'stone';
  if (k.includes('iron') || k.includes('ore') || k.includes('metal')) return 'metal';
  if (k.includes('clay'))   return 'clay';
  if (k.includes('grain')  || k.includes('farmland') || k.includes('field')) return 'food';
  if (k.includes('garden') || k.includes('plot'))     return 'food';
  if (k.includes('pond')   || k.includes('water')    || k.includes('lake') || k.includes('river') || k.includes('fish')) return 'fish';
  if (resource?.industry_key === 'timber') return 'wood';
  if (resource?.industry_key === 'stone')  return 'stone';
  if (resource?.industry_key === 'iron')   return 'metal';
  if (resource?.industry_key === 'clay')   return 'clay';
  return 'default';
}

// ── Walker variant picker ──────────────────────────────────────
//
// Building → walker variant key. Picks the v1 walker SVG that best
// fits the source building. Housing spawns one of four "citizen"
// personas at random for visual variety; specific industries spawn
// their job-specific worker; services spawn their domain figure.
export function pickWalkerVariant(b, bt) {
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

// ── Building AoE range ─────────────────────────────────────────
//
// Returns { range, kind } for a building that has gameplay coverage,
// or null otherwise. Ranges match the server-side gate checks in
// `_pp_evolve_housing` for services and the building_types columns
// for police / park / booster.
export function getBuildingAoeRange(b, bt) {
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

// ── Heatmap tint ────────────────────────────────────────────────
//
// Returns { tint, alpha } for a tile's value under a given mode.
// alpha=0 means "no overlay drawn".
export function heatmapTintFor(mode, value) {
  if (mode === 'pollution') {
    if (value <= 0) return { tint: 0, alpha: 0 };
    const t = Math.min(1, value / 30);
    return { tint: 0xe85a3a, alpha: 0.15 + t * 0.45 };
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
  if (mode === 'crime') {
    if (value < 50) return { tint: 0, alpha: 0 };
    return { tint: 0xc84878, alpha: 0.42 };
  }
  if (mode === 'issues') {
    if (value < 50) return { tint: 0, alpha: 0 };
    return { tint: 0xf0a838, alpha: 0.5 };
  }
  return { tint: 0, alpha: 0 };
}

// ── World bounds from a state snapshot ──────────────────────────
//
// Returns { minX, minY, cols, rows } covering every owned tile AND
// every visible building. Pass tileMap + buildings explicitly so
// this stays pure / testable.
export function computeWorldBounds(tileMap, allBuildings) {
  let minX = Infinity, maxX = -Infinity, minY = Infinity, maxY = -Infinity;
  for (const k in tileMap) {
    const t = tileMap[k];
    if (t.x < minX) minX = t.x; if (t.x > maxX) maxX = t.x;
    if (t.y < minY) minY = t.y; if (t.y > maxY) maxY = t.y;
  }
  for (const b of allBuildings) {
    if (b.x < minX) minX = b.x;
    if (b.x > maxX) maxX = b.x;
    if (b.y < minY) minY = b.y;
    if (b.y > maxY) maxY = b.y;
  }
  if (!isFinite(minX)) return { minX: 0, minY: 0, cols: 0, rows: 0 };
  return { minX, minY, cols: maxX - minX + 1, rows: maxY - minY + 1 };
}

// ── Tutorial gating ─────────────────────────────────────────────
//
// Each tutorial step (0..3) limits which building categories the
// player can see in the Build tab. step 4 = done, all unlocked.
// Mirrors v1's tutorialAllowsBuilding in ui.js.
export function tutorialAllowsBuilding(bt, tutorialStep) {
  const step = tutorialStep ?? 4;
  if (step >= 4) return true;
  if (!bt) return false;
  if (bt.category === 'road') return true;
  if (step === 0) return bt.category === 'housing';
  if (step === 1) return bt.category === 'housing' || bt.key === 'well';
  if (step === 2) {
    return bt.category === 'housing' || bt.key === 'well' || bt.category === 'food_extractor';
  }
  if (step === 3) {
    return bt.category === 'housing' || bt.key === 'well'
      || bt.category === 'food_extractor' || bt.category === 'extractor';
  }
  return false;
}

// ── Walker SVG sizing ──────────────────────────────────────────
//
// Inject explicit width/height into a walker SVG data URI so the
// browser rasterizes it at a known small size. Returns a new
// data URI with width="<vb_w * 4>" height="<vb_h * 4>" added. If
// the viewBox can't be parsed, returns the input unchanged.
export function sizeWalkerSvg(dataUri) {
  // Accept either single or double quotes around viewBox so the
  // helper isn't brittle to upstream string-formatting changes.
  const m = dataUri.match(/viewBox=['"]([\d.\s]+)['"]/);
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
