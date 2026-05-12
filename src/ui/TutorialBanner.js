// Tutorial banner — bottom-of-screen strip showing the current
// onboarding step. Auto-advances as the server marks
// player_profiles.tutorial_step up via the AFTER INSERT trigger on
// buildings; we just refresh from state and update the banner copy.
//
// 4 steps (0-3) active; step 4 means done — banner hides.
import { state } from '../state/store.js';

const STEPS = [
  {
    title: 'Step 1 of 4 — Build 4 Houses',
    body: 'Tap "Build", select a House, and place 4 anywhere on your land. Each house holds 6 citizens who arrive immediately — by the end of this step you\'ll have ~24 workers ready to staff the rest of the city.'
  },
  {
    title: 'Step 2 of 4 — Build a Well',
    body: 'Place a Well on a tile next to a road, near your houses. Wells provide water service to nearby housing (within 4 tiles) so it can keep growing. The Well takes 3 workers when staffed.'
  },
  {
    title: 'Step 3 of 4 — Build a Food Producer',
    body: 'Pick a food extractor — Garden, Orchard, Fishing Pier, or Grain Farm. Each needs its own type of resource tile (look for the colored dots). Food keeps citizens alive and adds happiness.'
  },
  {
    title: 'Step 4 of 4 — Build a Resource Extractor',
    body: 'Place your industry\'s extractor on a matching resource tile. It produces the goods you\'ll trade for money. Save up before building police buildings — their upkeep can sink an early-game economy.'
  }
];

let mounted = false;
let dismissedForSession = false;

export function mountTutorialBanner() {
  if (mounted) return;
  const root = document.getElementById('ui-root');
  const banner = document.createElement('div');
  banner.id = 'tutorial-banner';
  banner.innerHTML = `
    <div class="tb-content">
      <h3 class="tb-title"></h3>
      <p class="tb-body"></p>
    </div>
    <button class="tb-dismiss" aria-label="Hide for now">×</button>
  `;
  root.appendChild(banner);
  mounted = true;

  banner.querySelector('.tb-dismiss').addEventListener('click', () => {
    // Dismissed for the rest of this session. refreshTutorialBanner
    // bails before re-showing. Next page load brings it back if the
    // tutorial step is still active.
    dismissedForSession = true;
    banner.classList.add('hidden');
  });

  refreshTutorialBanner();
}

export function refreshTutorialBanner() {
  if (!mounted) return;
  const banner = document.getElementById('tutorial-banner');
  if (!banner) return;
  if (dismissedForSession) {
    banner.classList.add('hidden');
    return;
  }
  const step = state.profile?.tutorial_step ?? 0;
  if (step >= 4) {
    banner.classList.add('hidden');
    return;
  }
  banner.classList.remove('hidden');
  const copy = STEPS[step];
  if (!copy) {
    banner.classList.add('hidden');
    return;
  }
  banner.querySelector('.tb-title').textContent = copy.title;
  banner.querySelector('.tb-body').textContent = copy.body;
}
