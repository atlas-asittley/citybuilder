# Architecture research: what's the right way to build this game?

Written 2026-05-11 in response to Atlas's question: "Is there an
approach that's better for games like these? It seems like we're
trying to fit a square peg into a round hole."

Plain-language version: yes, we are. But the square peg is narrower
than "the browser" — it's specifically "using HTML's document layout
system to draw a game world." The fix is to keep the browser and
swap the drawing system. This doc walks through why, what the
realistic options are, and what I'd actually recommend.

---

## 1. The short answer

**The browser is not the wrong tool. The DOM is.**

HTML's `<div>` system (the DOM, short for "Document Object Model")
was designed to lay out documents — articles, forms, scrollable
text. We're using it to draw ~3,000 grid cells, hundreds of animated
buildings, and dozens of walking citizens. Every animation runs
through the browser's layout engine, which was built for "this
paragraph just got longer, please reflow the page," not "30 little
people just took a step."

That's where the lag comes from. Not from JavaScript. Not from
Supabase. Not from being in a browser at all. From the specific
choice to render the *map* as a grid of HTML elements with CSS
animations.

**The fix is to swap how the map is drawn, not where the game runs.**
Specifically: render the map to a single `<canvas>` element using
WebGL (a graphics API built into every browser). Same browser,
same URL, same mobile support, same Supabase backend — but the map
now draws like a real game, not like a really-fancy spreadsheet.

The mainstream tool for doing this in 2026 is **Pixi.js** (a 2D
WebGL rendering library) or **Phaser** (a full 2D game framework
built on top of Pixi). Both are mature, both are mobile-friendly,
both are used in production by indie and commercial 2D games.

My recommendation: **Phaser**, keeping the existing Supabase
backend. Details below.

---

## 2. What I actually looked at in our codebase

Before researching options, I measured what we have:

- **~10,500 lines of JavaScript** across 26 files
- **~2,160 lines of CSS**
- **~6,200 lines of Postgres schema** (251 tables/views/functions
  + 92 incremental migration patches)

The JS splits roughly into:

| Layer                              | Files                                                                   | Lines  | Survives a rewrite? |
| ---------------------------------- | ----------------------------------------------------------------------- | ------ | -------------------- |
| **Map rendering (the bottleneck)** | `map.js`, `walkers.js`, `sprites.js`, `map_roads.js`, most of `styles.css` | ~4,800 | No — this is what changes |
| **UI panels** (inspector, build menu, trade, top bar, settings) | `panels.js`, `inspector_*.js`, `players.js`, `reports.js`, `notifications.js`, `ui.js` | ~4,300 | Mostly — keep as HTML+CSS |
| **Game core** (state, auth, RPC plumbing, realtime sub) | `state.js`, `auth.js`, `realtime.js`, `game.js`, etc. | ~1,400 | Yes — barely changes |

So roughly **half the JS would be rewritten**, the other half is
fine as-is. The entire backend (Postgres + Supabase RPC + realtime
broadcast) is untouched — and that's the part that took the most
work to build right (the tick processor, the cash ledger invariant,
the per-house pantry buffers, the auth-checked RPCs, etc.).

This matters because it means a migration isn't "start over." It's
"replace the renderer, keep everything else." The hard, distinctive
work of the game lives on the server side and stays.

---

## 3. The core insight: DOM vs Canvas vs WebGL

Three drawing systems exist in every modern browser:

### DOM (what we use now)

Every cell, every building, every citizen is an HTML element. The
browser does layout, painting, and animation as if it were a web
page. Pros: easy to inspect with browser tools, hit testing comes
for free, CSS is convenient. Cons: every animated element costs
layout work every frame, and thousands of animated elements blow
past what the layout engine was designed for.

This is what we have. This is the bottleneck.

### Canvas 2D (the immediate-mode approach)

A single `<canvas>` element. You write JavaScript that says "draw a
red rectangle at (40, 80)" sixty times a second. The browser does
no layout — just paints what you tell it. Pros: simple, no DOM
overhead. Cons: every pixel goes through the CPU, so it scales
worse than WebGL once you have a lot of moving art.

Better than DOM for our use case. Worse than WebGL.

### WebGL (the GPU approach)

Same canvas element, but rendered by the graphics card. You upload
your sprites once (a "texture atlas"), and the GPU draws thousands
of them per frame for almost no CPU cost. This is what every
real-time 3D engine uses; it works fine for 2D too. Pros: enormous
performance ceiling. Cons: low-level — you don't write WebGL
directly, you use a library.

The library you use for WebGL in 2D-game contexts is **Pixi.js**.
Pixi handles the WebGL bookkeeping; you write "place this sprite
here." Phaser uses Pixi internally and adds game-specific helpers
(scene management, input, physics, tweens).

This is what we want.

---

## 4. The realistic options

I'm sorting these by *what they preserve of what you currently
value*: URL-shareable, mobile-friendly, multiplayer, Supabase
backend, solo-dev sustainable. Anything that breaks one of those is
ranked lower.

### Option A — Stay with DOM, keep grinding incremental perf

Do nothing. Keep finding individual perf wins (the offscreen pause,
the tick-pulse, the closer optimization, the zoom coalesce). Each
buys 10–30% but the ceiling is fundamentally low.

**Verdict:** Will hit a wall well before the city sizes you want.
Already feeling it.

### Option B — Pixi.js (rendering library only)

Replace `map.js` + `walkers.js` rendering with Pixi. Keep all UI
panels in HTML. Keep Supabase. Keep JavaScript.

- **What changes:** map rendering, sprite atlas, walker animation
- **What stays:** every panel, every RPC call, the entire backend,
  TypeScript-or-not is your call
- **Mobile:** excellent. Pixi is widely used in mobile-targeted browser
  games.
- **Multiplayer:** unchanged — you keep the Supabase realtime channel.
- **Bundle size:** Pixi is ~450 KB minified. Negligible for desktop,
  fine for mobile.
- **Learning curve:** moderate. Pixi has a clean API and good docs;
  the concepts (sprite, container, ticker, texture atlas) are simple
  but new.
- **Effort:** rewrite ~4,800 lines of rendering code. Multi-week
  project for one developer. The backend doesn't change.

**Verdict:** Strong contender. Minimum viable architecture upgrade.

### Option C — Phaser (full 2D game framework, built on Pixi)

Same as B, but you get a richer toolkit: scene management, input
handling, camera system, tilemap support (purpose-built for grid
games like ours), physics if we ever need it, audio, tweens. Bigger
bundle (~1.2 MB) but more batteries-included.

- **What it gives you over Pixi:** a tilemap system that's exactly
  what we'd build manually on top of Pixi anyway. A camera with
  pan/zoom/easing built in (no more hand-rolled zoom coalesce). A
  scene system that cleanly separates "build menu open" from "trade
  panel open" from "main map." Hot-reload-friendly dev tooling.
- **What it costs:** ~3x the bundle size of Pixi, more opinionated
  (you do things "the Phaser way"). On mobile, the larger download
  is a few hundred ms on first load only — Service Workers cache
  it after.
- **Ecosystem:** mature. Many commercial 2D games ship on it. Active
  community, lots of tutorials.

**Verdict:** Almost certainly the right choice for us. The tilemap
+ camera features map directly onto features we'd otherwise hand-
roll on Pixi.

### Option D — Godot, exported to HTML5/Web

Godot is a full game engine (like Unity or Unreal but free and
open-source). It compiles your game to WebAssembly + WebGL and
serves it as a webpage.

- **What it gives you:** a visual editor for scene composition,
  tilemap editor, animation timeline, built-in physics, a proper
  game architecture. Way more "engine" than Phaser.
- **What it costs:**
  - Web exports use WebGL 2.0 only (no WebGPU yet); newer rendering
    paths aren't supported on web.
  - C# isn't supported on the web target (you'd write GDScript,
    which is Python-flavored and Godot-specific). I — your assistant
    — am much weaker at GDScript than at JavaScript, which means
    our pair-programming pace drops noticeably.
  - Web exports are heavy (~10–30 MB on first load) compared to a
    Phaser bundle (~1 MB). On a slow phone connection that's a real
    wait.
  - Recent Godot mobile focus has been on *native* iOS/Android
    builds, not the web export. The web target works but isn't where
    the engine team is pouring energy.
  - You'd need a separate way to talk to Supabase (an HTTP client
    library in GDScript), and realtime websocket support there is
    less polished than the JS SDK.

**Verdict:** Powerful, but the constraints fight against the
properties you value. The web export feels like a second-class
citizen. Reasonable if we were also planning a native mobile
release, but you said the URL property matters.

### Option E — Bevy (Rust) compiled to WebAssembly

Bevy is a Rust-based game engine using an ECS ("Entity Component
System") architecture. Same idea as Godot — game runs as WebAssembly
in the browser — but written in Rust, which is faster and stricter
than JavaScript.

- **What it gives you:** Possibly the best raw performance in
  browser-targetable engines. Modern data-oriented architecture.
  Excellent for sims with many entities.
- **What it costs:**
  - **Rust.** A different language, with a famously steep learning
    curve. You'd be learning Rust *and* Bevy *and* game architecture
    simultaneously. I can help, but my Rust-with-Bevy fluency is
    lower than my JS fluency.
  - Web exports work and improve every release, but the ecosystem
    is younger than Phaser's.
  - Same Supabase-from-non-JS challenge as Godot.
  - As of early 2026, Bevy is at v0.18 — it's still pre-1.0, meaning
    breaking API changes between minor versions are normal. That's
    fine for hobbyists, painful for a long-running project.

**Verdict:** Cutting-edge and exciting. Not the right call for a
solo dev who values delivery over learning Rust. If you ever wanted
a 10,000-citizen mega-city sim with real-time pathfinding, Bevy
would be where to look. Today, overkill.

### Option F — Native app (Unity, Godot native, etc.)

Build for iOS/Android and distribute through the app stores.

- **What you give up:** "tap a URL and play." Friends now have to
  install an app from a store. That's the property you said you
  value most. Veto.

**Verdict:** Off the table per your constraints.

---

## 5. What stays the same in all browser-based options

This is worth emphasizing because it's the bulk of what's already
working well.

### The Supabase backend doesn't change

- 251 Postgres functions/tables/views
- 6,200 lines of schema
- The tick processor (`_pp_*` orchestrator + phase helpers)
- The cash ledger invariant
- Auth, RLS policies, realtime subscriptions
- pg_cron-driven ticks
- The procedural-traders system, the per-house pantries, the
  pollution/desirability/crime/happiness pipelines

None of that touches the renderer. All of it stays exactly as-is.

### Multiplayer sync model doesn't change

We currently use:
1. PostgREST RPC calls for player actions ("place building",
   "upgrade house", "trade")
2. Supabase Realtime channels to broadcast `INSERT/UPDATE/DELETE`
   on the `buildings` table so other players see your changes
3. Server-side tick (`pg_cron` every minute) to advance the
   simulation

This is a **server-authoritative tick-based** model. It's the
right pattern for a city-builder with shared state. It does *not*
need to change with the renderer swap. (And it's actually a
strength — most engine-based games are client-authoritative, which
makes shared-world cheating prevention much harder.)

### Half the JS doesn't change

Inspector panels, top bar, settings, trade panel, players list,
reports — all DOM/HTML. They sit *next* to the canvas, not inside
it. They don't have the performance problem and don't need to move.

---

## 6. How comparable games are actually built

Reference points I looked at:

- **Kingdom Architect** (open-source medieval browser city-builder)
  — 2D canvas renderer, WebSocket multiplayer, typed asset pipeline.
- **Citybound** — ambitious open-source city sim with collaborative
  multiplayer; uses WebGL via a React/Monet hybrid for GPU resource
  management. Worth studying for inspiration.
- **BuildCity.io** — commercial WebGL browser city builder with
  no install required, exactly the URL-shareable pattern you want.
- **IsoCity** — isometric 2D-on-canvas approach if we ever want to
  shift visual style.
- **PlayCanvas** — a commercial WebGL engine built specifically for
  browser-based games (less mainstream than Phaser; included for
  completeness).
- **Townscaper** (Unity, native) — gorgeous but distributed as an
  app, not a URL. Confirms the engine power tradeoff.
- **Forge of Empires, OGame, Travian** — long-running browser MMOs.
  These are mostly DOM-based historically because their visual
  ambition is low (turn-based, mostly text and static art). They
  *would not* try to do live animated walkers in DOM.

The pattern that lines up best with what you want — URL access,
mobile, multiplayer, lots of life on the map — is the Pixi/Phaser
canvas-renderer-with-backend-API pattern.

---

## 7. My recommendation

**Phaser + the existing Supabase backend.**

Reasoning:

1. **Preserves everything you value.** URL access, mobile, multiplayer,
   tap-link-and-play, all unchanged. The Supabase backend doesn't
   move. Half the JS doesn't move.

2. **Solves the actual bottleneck.** Phaser uses Pixi's WebGL
   renderer under the hood. Thousands of animated sprites at 60 fps
   on a mid-range phone is well within its envelope. Today's lag
   would disappear.

3. **Right level of abstraction for one developer.** Phaser's
   tilemap + camera + scene + input systems give us exactly what
   we'd need to hand-roll on raw Pixi. That's weeks of "build the
   scaffolding" we don't have to do.

4. **Same language as today.** JavaScript / TypeScript. No learning
   Rust or GDScript. Our pair-programming velocity stays high.

5. **Mature, mobile-tested, well-documented.** Phaser ships
   commercial 2D games. It runs well on iOS Safari and Android
   Chrome. It has been around long enough that mobile quirks are
   well-known and fixable.

6. **Lets us drop a lot of code.** We currently maintain ~2,160
   lines of hand-written CSS animations and ~4,800 lines of map/
   walker rendering. A Phaser port reduces both, and the walker
   logic becomes a fraction of its current size when sprites are
   first-class objects instead of `<div>` elements with CSS keyframes.

The runner-up is **Pixi.js** (just the renderer, no game framework).
Pick that if you decide later that Phaser's opinions get in our way
on something specific. Roughly the same migration shape, less
out-of-the-box but more flexible.

---

## 8. What a migration would look like

Not committing to this yet — Atlas hasn't said "do it." But sketching
so the scope is concrete.

### Phase 0 — Decide and learn (1–2 sessions)

- Build a 5-minute Phaser sandbox: empty scene, tilemap with 50×50
  cells, sprite-based buildings, a camera with smooth zoom.
- Confirm on Atlas's phone that it runs at 60 fps with 500+ sprites.
- If the demo feels right, commit to the migration.

### Phase 1 — Parallel Phaser map alongside DOM map (3–5 sessions)

- Mount a Phaser canvas in the existing `index.html` alongside the
  current DOM `#map-grid`.
- Read from the same `state.allBuildings` / `state.tileMap`.
- Get the basic city visible: terrain, buildings, roads.
- Wire pan/zoom to the Phaser camera (replaces our hand-rolled zoom).
- Hide the DOM map behind a feature flag toggle so we can A/B compare.

### Phase 2 — Move features one at a time (most of the work)

- Walkers → Phaser sprite system + a tick to advance positions.
- Heatmaps → a tinted overlay sprite per tile.
- Building animations (smoke, glow, walking figures) → sprite
  animations or simple alpha-pulsing.
- Placement preview → ghost sprite that follows the cursor.
- Inspector AoE highlight → tinted overlay over the affected cells.

After each feature lands in Phaser, retire its DOM equivalent. The
inspector, panels, top bar, modal dialogs etc. stay as HTML next to
the canvas.

### Phase 3 — Cut over and clean up (1 session)

- Remove the feature flag and the DOM `#map-grid`.
- Delete the old CSS animations.
- Delete `map.js`, `walkers.js`, `map_roads.js`, `sprites.js`
  (replaced by Phaser equivalents).

### Total scope (rough)

If we ship one or two phases per week of focused sessions, the
migration is probably **4–8 weeks of meaningful work**. The vast
majority of game logic — RPC calls, panels, the entire backend —
doesn't move. The only thing that moves is the renderer.

---

## 9. What I'd want to verify before fully committing

Honest "still unknown to me" list:

1. **Phaser performance on your specific phone (Pixel 7?).** I'm
   confident from general benchmarks, but our city has features
   (heatmaps, AoE overlays, many simultaneous walker animations)
   that I'd want to confirm with a real prototype before banking
   on it.

2. **Tilemap fit for shared multiplayer maps.** Phaser's tilemap is
   designed for single-player worlds. Our map is shared across
   players, with per-player parcel ownership and dynamic tile
   updates from realtime. I think this works fine (the tilemap is
   just a sprite grid we update) but I'd want to prototype.

3. **Animation budget on mobile.** Phaser doesn't magically make
   500 simultaneously-animated sprites cheap. We still need to be
   thoughtful: cull offscreen sprites, batch updates, use sprite
   sheets. We've already learned those lessons in DOM-land; they
   port cleanly.

4. **Bundle size impact on first-load.** Phaser is ~1.2 MB minified
   + our code. Total first-load grows from today's ~150 KB JS to
   ~1.5 MB. On a fresh phone with 4G that's ~1–2 seconds of extra
   loading. Service Worker caching after first visit means repeat
   visits are still instant. Worth confirming on your phone.

---

## 10. Things I deliberately considered and ruled out

For completeness:

- **Three.js (3D)** — overkill for top-down 2D; we'd just be using
  it as a 2D library, in which case Pixi is the same thing without
  the 3D math overhead.
- **Solid.js / Svelte / React for the map** — moving frameworks
  doesn't solve the DOM problem. Same square peg.
- **Web Components** — wraps DOM in a different API. Doesn't change
  the underlying performance model.
- **Server-rendered map (HTMX-style)** — sends pre-rendered HTML
  from the server each tick. Even worse than current.
- **Splitting frontend from Supabase** — the backend is doing well,
  and the realtime integration is one of Supabase's strengths.
  Don't touch it.

---

## 11. The really honest summary

The current architecture isn't "wrong" in a moral sense. It got us
this far. The DOM-as-canvas approach is genuinely simple to start
with, and the backend you have is good enough to power a much
bigger game. But the renderer is now the binding constraint, and
no amount of micro-optimization will get us past where Phaser
starts.

If you want the city to feel alive — hundreds of walking people,
fluid zooming, smooth panning, animated activity on every staffed
building, large maps — Phaser (or Pixi if you want less framework)
is the standard, well-trodden path. It's not exotic, it's not
experimental, it's not a bet on a fad. It's how browser games like
yours have been built for the last decade. We just happened to take
the DOM path first because it was the path of least resistance for
a prototype, and the prototype outgrew it.

**Your move:** want me to set up the Phase 0 Phaser sandbox so you
can feel the difference on your phone before deciding?

---

## Sources consulted

- [PixiJS vs Phaser comparison (Generalist Programmer, 2025)](https://generalistprogrammer.com/comparisons/phaser-vs-pixijs)
- [PixiJS vs Phaser 2026 (Slant)](https://www.slant.co/versus/1965/1966/~pixi-js_vs_phaser)
- [JS game rendering benchmark (Shirajuki)](https://github.com/Shirajuki/js-game-rendering-benchmark)
- [Godot HTML5 export docs](https://docs.godotengine.org/en/latest/tutorials/export/exporting_for_web.html)
- [Godot Mobile update April 2026](https://godotengine.org/article/godot-mobile-update-apr-2026/)
- [Kingdom Architect (open-source browser city builder)](https://github.com/trymnilsen/kingdomarchitect)
- [Citybound](https://aeplay.org/citybound)
- [Bevy on WebAssembly (Cheat Book)](https://bevy-cheatbook.github.io/platforms/wasm.html)
- [Rust Game Engines in 2026 (Aarambh Dev Hub)](https://aarambhdevhub.medium.com/rust-game-engines-in-2026-bevy-vs-macroquad-vs-ggez-vs-fyrox-which-one-should-you-actually-use-9bf93669e83f)
- [PlayCanvas](https://playcanvas.com/)
