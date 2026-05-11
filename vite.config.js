import { defineConfig } from 'vite';

// GitHub Pages serves project sites at /<repo>/, so we need this base
// path baked into the build output for assets to resolve correctly.
// Dev mode (npm run dev) uses '/' automatically.
export default defineConfig({
  base: process.env.NODE_ENV === 'production' ? '/citybuilder/' : '/',
  build: {
    outDir: 'dist',
    target: 'es2020',
    sourcemap: true
  },
  server: {
    port: 5173,
    host: true
  }
});
