// Entry point. For now just boots a minimal Phaser scene to prove
// the toolchain works end-to-end (Vite dev server, Phaser, build,
// deploy). The real game scaffolding lands once we have Phase 0
// validated on Atlas's phone.
import Phaser from 'phaser';
import { SandboxScene } from './scenes/SandboxScene.js';

const config = {
  type: Phaser.AUTO,            // WebGL with Canvas fallback
  parent: 'game-root',
  backgroundColor: '#0a0e14',
  scale: {
    mode: Phaser.Scale.RESIZE,
    autoCenter: Phaser.Scale.CENTER_BOTH,
    width: window.innerWidth,
    height: window.innerHeight
  },
  render: {
    pixelArt: false,
    antialias: true
  },
  scene: [SandboxScene]
};

new Phaser.Game(config);
