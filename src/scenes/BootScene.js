// Smoke-test scene. Confirms Phaser is mounting, the renderer
// reports WebGL (not Canvas fallback), and the toolchain produces
// a deployable build. Replaced by the real Phase 0 sandbox in the
// next step.
import Phaser from 'phaser';

export class BootScene extends Phaser.Scene {
  constructor() {
    super('BootScene');
  }

  create() {
    const { width, height } = this.scale;
    const renderer = this.game.renderer.type === Phaser.WEBGL ? 'WebGL' : 'Canvas';

    this.add.text(width / 2, height / 2 - 40, 'City Builder', {
      fontFamily: 'system-ui, sans-serif',
      fontSize: '40px',
      color: '#16c79a'
    }).setOrigin(0.5);

    this.add.text(width / 2, height / 2 + 8, 'Phaser ' + Phaser.VERSION + ' · ' + renderer, {
      fontFamily: 'system-ui, sans-serif',
      fontSize: '14px',
      color: '#888'
    }).setOrigin(0.5);

    this.add.text(width / 2, height / 2 + 40, 'New build — v2 work in progress', {
      fontFamily: 'system-ui, sans-serif',
      fontSize: '12px',
      color: '#555'
    }).setOrigin(0.5);
  }
}
