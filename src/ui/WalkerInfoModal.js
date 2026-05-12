// Walker info card — small modal popped when the player taps a
// walker on the map. Shows persona + kind + origin building (when
// applicable). Pure flavor — no actions; the close button or any
// outside click dismisses.
import { state } from '../state/store.js';

let mounted = false;

const KIND_LABELS = {
  immigrant:        'Immigrant — moving in',
  emigrant:         'Emigrant — moving out',
  road:             'Worker on the move',
  collector:        'Collector — harvesting',
  'collector-path': 'Collector — harvesting'
};

const VARIANT_LABELS = {
  citizen:   'Citizen',
  child:     'Child',
  elder:     'Elder',
  fat:       'Well-fed citizen',
  couple:    'Couple',
  civic:     'Civic worker',
  tavern:    'Tavern keeper',
  temple:    'Temple acolyte',
  school:    'Schoolchild',
  bathhouse: 'Bathhouse attendant',
  timber:    'Timber worker',
  sawmill:   'Sawyer',
  stone:     'Quarryman',
  grain:     'Farmer',
  iron:      'Ironworker',
  clay:      'Potter',
  orchard:   'Orchardist',
  fish:      'Fisher',
  garden:    'Gardener'
};

// Find the walker entry whose sprite matches the tapped sprite so we
// can read kind/accessory info that lives on the entry, not the
// sprite. Cheap O(N) — bounded by walker cap.
function findWalkerEntry(sprite, walkers) {
  for (const w of walkers) {
    if (w.sprite === sprite) return w;
  }
  return null;
}

export function openWalkerInfo(sprite, walkers) {
  if (mounted) return;
  mounted = true;

  const info = sprite.walkerInfo || {};
  const entry = findWalkerEntry(sprite, walkers);
  const kind = info.kind || entry?.kind || 'citizen';
  const persona = VARIANT_LABELS[info.variant] || info.variant || 'Citizen';
  const origin = info.originBuilding;
  const originType = info.originType;
  const originName = origin && originType ? originType.name : null;
  const originCoords = origin ? `(${origin.x}, ${origin.y})` : null;

  const root = document.getElementById('ui-root');
  const overlay = document.createElement('div');
  overlay.id = 'walker-info-overlay';
  overlay.innerHTML = `
    <div class="wi-card">
      <div class="wi-header">
        <h2>${escapeHtml(persona)}</h2>
        <button class="wi-close" aria-label="Close">×</button>
      </div>
      <div class="wi-body">
        <div class="wi-row"><span class="wi-label">Status</span><span class="wi-value">${escapeHtml(KIND_LABELS[kind] || kind)}</span></div>
        ${originName ? `<div class="wi-row"><span class="wi-label">From</span><span class="wi-value">${escapeHtml(originName)} ${escapeHtml(originCoords)}</span></div>` : ''}
        <p class="wi-flavor">${flavorText(kind, persona)}</p>
      </div>
    </div>
  `;
  root.appendChild(overlay);
  const close = () => { overlay.remove(); mounted = false; };
  overlay.querySelector('.wi-close').addEventListener('click', close);
  overlay.addEventListener('click', (e) => { if (e.target === overlay) close(); });
  document.addEventListener('keydown', function onEsc(e) {
    if (e.key === 'Escape') { close(); document.removeEventListener('keydown', onEsc); }
  });
}

function flavorText(kind, persona) {
  if (kind === 'immigrant') return `New ${persona.toLowerCase()} arriving — happiness > 50 attracts migration.`;
  if (kind === 'emigrant')  return `${persona} leaving the city — happiness < 50 drives emigration.`;
  if (kind === 'collector' || kind === 'collector-path') return `${persona} hauling resources back to the extractor.`;
  if (kind === 'road') return `${persona} going about their day on the street network.`;
  return `${persona} in the city.`;
}

function escapeHtml(s) {
  return String(s == null ? '' : s).replace(/[&<>"]/g, (c) => ({
    '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;'
  }[c]));
}

// Stash entry.kind back onto sprite.walkerInfo for the ambient walkers
// (road/collector) so the modal can read it without re-iterating
// state.allBuildings. Called from MainScene as walkers are spawned.
export function tagWalkerSpriteKind(sprite, kind) {
  if (sprite && sprite.walkerInfo) sprite.walkerInfo.kind = kind;
}
