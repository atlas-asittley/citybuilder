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
import { bindSceneToInspector } from './ui/InspectorPanel.js';
import { bindSceneToExpansion } from './ui/ExpansionPanel.js';
import { mountIndustrySelectScreen, unmountIndustrySelectScreen } from './ui/IndustrySelectScreen.js';
import { mountLoadingScreen, unmountLoadingScreen } from './ui/LoadingScreen.js';
import { mountTopBar, refreshTopBar } from './ui/TopBar.js';
import { mountInfoBar, refreshInfoBar } from './ui/InfoBar.js';
import { mountBuildMenu } from './ui/BuildMenu.js';
import { mountZoomControls } from './ui/ZoomControls.js';
import { mountHeatmapToggle } from './ui/HeatmapToggle.js';
import { checkAndShowChangelogIfUnseen } from './ui/ChangelogModal.js';
import { mountTutorialBanner } from './ui/TutorialBanner.js';
import { startTickLoop, onTileMetricsChanged, onPopIncrease, onPopDecrease } from './api/tick.js';
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
  // Sandbox is auto-started; MainScene is registered but NOT auto-
  // started — it only starts once data has loaded from Supabase.
  // Otherwise create() would run before state.profile exists and we
  // saw "Waiting for data…" stuck on screen even after auth.
  scene: sandboxMode ? [SandboxScene] : []
});

if (sandboxMode) {
  console.log('Sandbox mode — auth bypassed');
} else {
  game.scene.add('MainScene', MainScene, false);
  bootApp().catch(showFatalError);
}

// Catch-all so anything throwing during boot becomes visible instead
// of leaving a blank screen with errors only in the dev console.
window.addEventListener('unhandledrejection', (e) => {
  showFatalError(e.reason || e);
});

function showFatalError(err) {
  console.error('Fatal:', err);
  const root = document.getElementById('ui-root');
  if (!root) return;
  const msg = (err && (err.message || err.toString())) || 'Unknown error';
  root.innerHTML = `
    <div class="ui-screen ui-screen-center">
      <div class="ui-card">
        <h1 class="ui-title" style="color:#e94560;">Couldn't start</h1>
        <p class="ui-subtitle" style="word-break:break-word;">${msg.replace(/[&<>]/g, (c) => ({'&':'&amp;','<':'&lt;','>':'&gt;'}[c]))}</p>
        <button class="ui-btn-primary" id="clear-and-reload">Clear session & reload</button>
      </div>
    </div>
  `;
  document.getElementById('clear-and-reload').addEventListener('click', async () => {
    try {
      await sb.auth.signOut();
    } catch (_e) { /* best effort */ }
    try {
      // Belt-and-braces: nuke any Supabase-related localStorage keys
      // in case signOut() can't reach a malformed token.
      for (let i = localStorage.length - 1; i >= 0; i--) {
        const k = localStorage.key(i);
        if (k && (k.startsWith('sb-') || k.includes('supabase'))) {
          localStorage.removeItem(k);
        }
      }
    } catch (_e) { /* storage disabled — silent */ }
    location.reload();
  });
}

async function bootApp() {
  // Check for an existing session in localStorage. If logged in,
  // skip the auth screen.
  const { data, error } = await sb.auth.getSession();
  if (error) {
    // Corrupt session token — surface so Atlas can recover with
    // the Clear button, rather than spinning silently.
    throw new Error('Session check failed: ' + error.message);
  }
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

    // Start (or restart) the Phaser scene now that state is
    // populated. Use the scene manager's keys-based API instead of
    // `scene.scene.restart()` so this works whether the scene was
    // previously started or not.
    if (game.scene.isActive('MainScene')) {
      game.scene.getScene('MainScene').scene.restart();
    } else {
      game.scene.start('MainScene');
    }

    // Mount the DOM overlays (top bar + build menu + zoom controls),
    // kick off the production tick loop, and subscribe to realtime
    // building changes so other players' builds appear without a
    // refresh.
    mountInfoBar();
    mountTopBar(() => {
      // After a successful expand, the grid bounds may have grown.
      // Re-derive them from the new tileMap and restart the scene.
      const tileMap = state.tileMap;
      let minX = Infinity, maxX = -Infinity, minY = Infinity, maxY = -Infinity;
      for (const k in tileMap) {
        const t = tileMap[k];
        if (t.x < minX) minX = t.x; if (t.x > maxX) maxX = t.x;
        if (t.y < minY) minY = t.y; if (t.y > maxY) maxY = t.y;
      }
      if (isFinite(minX)) {
        state.gridMinX = minX; state.gridMinY = minY;
        state.gridCols = maxX - minX + 1; state.gridRows = maxY - minY + 1;
      }
      // Incremental rerender keeps the scene instance alive — all
      // the modules holding sceneRef stay valid. A full restart()
      // would invalidate them and require rewiring zoom/heatmap/
      // inspector against the fresh scene instance.
      const s = game.scene.getScene('MainScene');
      if (s?.rerenderWorld) s.rerenderWorld();
    });
    mountBuildMenu((buildingType) => {
      const s = game.scene.getScene('MainScene');
      if (s?.setPlacementMode) s.setPlacementMode(buildingType);
    });
    const mainScene = game.scene.getScene('MainScene');
    mountZoomControls(mainScene);
    mountHeatmapToggle(mainScene);
    bindSceneToInspector(mainScene);
    bindSceneToExpansion(mainScene);

    onTileMetricsChanged(() => mainScene.refreshHeatmap?.());
    onPopIncrease((count) => {
      for (let i = 0; i < count; i++) mainScene.spawnImmigrantWalker?.();
    });
    onPopDecrease((count) => {
      for (let i = 0; i < count; i++) mainScene.spawnEmigrantWalker?.();
    });

    mountTutorialBanner();

    const rerender = () => {
      const s = game.scene.getScene('MainScene');
      if (s?.rerenderBuildings) s.rerenderBuildings();
    };
    startTickLoop(rerender);
    subscribeRealtime(rerender);

    // Show any unseen "what's new" entries. Fire-and-forget — never
    // gates the game UI.
    checkAndShowChangelogIfUnseen();
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
