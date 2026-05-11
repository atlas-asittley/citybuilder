# City Builder

Browser-based multiplayer 2D city builder. Tap a URL, sign in, start
playing with friends. Shared persistent world.

This repo is the v2 rewrite — Phaser + WebGL renderer. The v1 game
(still live, still playable) lives in the
[`atlas-asittley.github.io`](https://github.com/atlas-asittley/atlas-asittley.github.io)
site repo under `city-builder-mvp/` and uses a DOM-based renderer
that hit a performance ceiling. The architectural reasoning behind
this rewrite is in [`docs/ARCHITECTURE_RESEARCH_2026_05_11.md`](docs/ARCHITECTURE_RESEARCH_2026_05_11.md).

Both versions share the same Supabase backend (Postgres + RLS +
realtime + pg_cron-driven ticks), so player accounts and city state
carry over without migration.

## Stack

| Layer | Choice |
| ----- | ------ |
| Renderer | [Phaser 3](https://phaser.io/) (WebGL, with Canvas fallback) |
| Bundler | [Vite](https://vitejs.dev/) |
| Backend | [Supabase](https://supabase.com/) (Postgres, Realtime, Auth) |
| Hosting | GitHub Pages (built and deployed via Actions) |

## Local development

```bash
npm install
npm run dev      # vite dev server at http://localhost:5173
npm run build    # production build to ./dist
npm run preview  # preview the production build locally
```

## Deployment

A push to `main` triggers the GitHub Actions workflow at
`.github/workflows/deploy.yml`, which runs `npm run build` and
deploys the `./dist` output to GitHub Pages. Live at
[atlas-asittley.github.io/citybuilder](https://atlas-asittley.github.io/citybuilder/).

The Vite `base` in `vite.config.js` is `/citybuilder/` in production
so asset paths resolve correctly under the GitHub Pages subpath.

## Notable docs

- [Architecture research](docs/ARCHITECTURE_RESEARCH_2026_05_11.md) — why Phaser, why now
- [Game design](GAME_DESIGN.md) — what the game *is*
- [Open todos](TODO.md) — what's planned
- [Bug reports archive](BUG_REPORTS.md) — past player-reported bugs and how they were resolved
