// Entry point and router. Bootstraps Phaser as the background
// canvas, then routes the UI overlay through:
//   1. Auth screen      (if no session)
//   2. Industry select  (logged in but no profile)
//   3. Game             (logged in + profile)
//
// The Phaser scene lives in the background the whole time. UI
// screens render to #ui-root as a DOM overlay. This keeps panel
// development (HTML/CSS, easy to inspect) decoupled from the
// canvas renderer (Phaser, fast).
//
// Sandbox mode (?sandbox=1) bypasses auth and boots the perf
// demo directly — useful for testing the renderer on a phone
// without logging in.
import Phaser from 'phaser';
import { SandboxScene } from './scenes/SandboxScene.js';
import { MainScene } from './scenes/MainScene.js';
import { sb } from './api/supabase.js';
import { state, setUser, setProfile, setCityName } from './state/store.js';
import { loadInitialWorld } from './state/loader.js';
import { mountAuthScreen, unmountAuthScreen } from './ui/AuthScreen.js';
import { mountIndustrySelectScreen, unmountIndustrySelectScreen } from './ui/IndustrySelectScreen.js';
import { mountLoadingScreen, unmountLoadingScreen } from './ui/LoadingScreen.js';
import { mountTopBar } from './ui/TopBar.js';
import { mountBuildMenu } from './ui/BuildMenu.js';
import { startTickLoop } from './api/tick.js';
import { subscribeRealtime } from './state/realtime.js';

// ── Boot Phaser ──
const params = new URLSearchParams(window.location.search);
const sandboxMode = params.has('sandbox');

const game = new Phaser.Game({
  type: Phaser.AUTO,
  parent: 'game-root',
  backgroundColor: '#0a0e14',
  scale: {
    mode: Phaser.Scale.RESIZE,
    autoCenter: Phaser.Scale.CENTER_BOTH,
    width: window.innerWidth,
    height: window.innerHeight
  },
  render: { pixelArt: false, antialias: true },
  scene: sandboxMode ? [SandboxScene] : [MainScene]
});

if (sandboxMode) {
  // Sandbox path: skip auth, let SandboxScene own the whole screen.
  console.log('Sandbox mode — auth bypassed');
} else {
  bootApp();
}

async function bootApp() {
  // Check for an existing session in localStorage. If logged in,
  // skip the auth screen.
  const { data } = await sb.auth.getSession();
  if (data?.session?.user) {
    onAuthSuccess(data.session.user);
  } else {
    mountAuthScreen(onAuthSuccess);
  }
}

async function onAuthSuccess(user) {
  setUser(user);
  unmountAuthScreen();
  mountLoadingScreen('Checking your profile…');

  // Profile probe — same logic as v1's checkProfileAndRoute.
  const { data: profile } = await sb
    .from('player_profiles')
    .select('*')
    .eq('id', user.id)
    .maybeSingle();

  if (profile && profile.industry_key) {
    setProfile(profile);
    await enterGame();
  } else {
    unmountLoadingScreen();
    mountIndustrySelectScreen(async () => {
      // After industry choice, refetch the profile and enter.
      const { data: fresh } = await sb
        .from('player_profiles')
        .select('*')
        .eq('id', user.id)
        .maybeSingle();
      setProfile(fresh);
      unmountIndustrySelectScreen();
      await enterGame();
    });
  }
}

async function enterGame() {
  mountLoadingScreen('Loading your city…');

  try {
    // Pull the city name (display only) in parallel with the bulk
    // world fetch — both touch different tables and don't block
    // each other.
    const [cityRow] = await Promise.all([
      state.profile?.city_id
        ? sb.from('cities').select('name').eq('id', state.profile.city_id).maybeSingle().then((r) => r.data)
        : Promise.resolve(null),
      loadInitialWorld()
    ]);
    if (cityRow?.name) setCityName(cityRow.name);

    unmountLoadingScreen();

    // Hand control to the Phaser scene. It reads from `state` and
    // builds the visible map. Subsequent panel mounts overlay on
    // top via #ui-root.
    const scene = game.scene.getScene('MainScene');
    if (scene) scene.scene.restart();

    // Mount the DOM overlays (top bar + build menu), kick off the
    // production tick loop, and subscribe to realtime building
    // changes so other players' builds appear without a refresh.
    mountTopBar();
    mountBuildMenu((buildingType) => {
      const s = game.scene.getScene('MainScene');
      if (s?.setPlacementMode) s.setPlacementMode(buildingType);
    });

    const rerender = () => {
      const s = game.scene.getScene('MainScene');
      if (s?.rerenderBuildings) s.rerenderBuildings();
    };
    startTickLoop(rerender);
    subscribeRealtime(rerender);
  } catch (err) {
    console.error('Failed to enter game:', err);
    document.getElementById('ui-root').innerHTML = `
      <div class="ui-screen ui-screen-center">
        <div class="ui-card">
          <h1 class="ui-title">Couldn't load</h1>
          <p class="ui-subtitle">${err.message || 'Unknown error'}</p>
          <button class="ui-btn-primary" onclick="location.reload()">Reload</button>
        </div>
      </div>
    `;
  }
}
