# Building Graphics Polish Plan

**Goal:** Bring every building sprite up to the visual fidelity of `assets/sprites/mill.svg` and `assets/sprites/grain_farm.svg`. They are the polish bar; everything else should match.

**Why:** Most buildings were recently converted from PNGs to inline-SVG data URLs in `css/styles.css`. The conversion used a deliberately minimal "kiln/walker" recipe (32×32 viewBox, 2-stop gradients, 6–25 simple shapes). The owner judged that level too sparse next to the mill and grain farm and wants the rest of the buildings brought up to match.

---

## The polish recipe (canonical examples)

Read these two files in full before redrawing anything — they are the spec, not just inspiration:

- `assets/sprites/mill.svg` — windmill: tapered stone tower, conical cap, 4 sails with hubs, arched door, window, grain/flour sacks, cobblestone base
- `assets/sprites/grain_farm.svg` — fenced field with 3 wheat rows of progressively taller/brighter stalks, fence posts and rails, dirt path

Specific techniques those two share that the kiln-style inline SVGs lack:

1. **64×64 viewBox, not 32×32.** Twice the resolution per axis, so detail elements look intentional instead of crowded.
2. **3-stop linear gradients** (top → mid → bottom) for body parts, e.g.:
   ```
   <stop offset="0" stop-color="#5a7a30"/>
   <stop offset=".5" stop-color="#4a6828"/>
   <stop offset="1" stop-color="#3a5420"/>
   ```
   Smoother shading than 2-stop.
3. **Depth shadow shapes** behind a primary form to fake roundness — see the mill's back ellipse: `<ellipse cx="32" cy="38" rx="14" ry="22" fill="#686060" opacity=".2"/>` placed *behind* the tower path.
4. **Side-shadow gradients** on cylindrical forms (mill `id="ts"` is a horizontal gradient applied to a curved path on the tower's left side at opacity .5).
5. **Curved texture stroke groups** — stone courses follow the tower's curvature with `<path d="M21,28 Q32,26 43,28"/>` instead of straight `<line>`s. Very low opacity (.3).
6. **Light-catch highlights** as separate light-color shapes at low opacity (`fill="#c0b8b0" opacity=".15"`) on the side facing the imaginary light source.
7. **Density of small details.** The grain farm has ~40 wheat heads laid out in 3 rows of varied height/saturation; the mill has 4 large sails plus hub circles, an arched door with a 2-tone interior, a small window with cross mullions, two grain sacks, and ~4 cobblestones at the base. Don't be afraid of element count — the eye reads "richness," not "clutter," when shapes layer cleanly.
8. **Grounding accents.** Both files anchor the building with a low-opacity ground shadow ellipse and/or dirt patch. Do not skip this; it makes the sprite read as planted in the world.

---

## Two-place edit gotcha (READ THIS)

Every building has **two** graphic locations that must be updated together. Forgetting #2 leaves the build-panel sidebar showing the old art even after the on-map sprite updates. The owner will notice within seconds.

1. **`css/styles.css`** — `.bldg.<key> { background-image: url("data:image/svg+xml,..."); ... }` rule. This is the on-map sprite.
2. **`js/panels.js`** — `spriteIcons` map (around line 54). This is the build-panel sidebar icon. Same data URL goes in both places.

The duplication between the two files is deliberate-but-temporary; can be DRY'd later if it becomes painful. For now, paste the same data URL into both.

### Housing tier sub-gotcha

Housing has 6 tiers (t0–t5) each with its own SVG via the `--house-sprite` CSS custom property on `.bldg.house.house-t<N>`:

- t0 = shanty, t1 = hut (currently kiln-style inline)
- t2 = cottage, t3 = townhouse, t4 = villa, t5 = manor estate (originally kiln-style inline)

The build panel only shows one icon for "house" (currently t1). Map shows the actual placed tier. When upgrading any housing tier, also update `panels.js` *only if t1 specifically is touched*.

The housing `::before` pseudo-element is sized 108% × 132% of the cell, anchored 14% below the cell bottom — so the bottom 14% of the SVG renders below the cell. Anchor housing artwork to ~y=58 within the 64×64 viewBox to match the layout the existing tiers use.

### Producing-state overlay constraint

Most production buildings have a `producing::before` (worker silhouette, bobbing) and/or `producing::after` (job-specific overlay like a spinning saw) defined in `styles.css` lines ~270–360. Each overlay is positioned in % of the cell and sits on top of the building. Examples:

- sawmill `::before` worker at `left:0 bottom:5% width:28% height:40%` → keep the lower-left clear in the base art (worker stands in front of a doorway)
- sawmill `::after` saw blade at `right:8% top:18% width:30% height:30%` → keep the upper-right relatively unobstructed
- timber_camp/stone_quarry/mason_workshop `::after` workers all use the shared rule at line ~268 (width 30%, height 42%)
- pottery_kiln smoke `::after` rises from the dome top at `left:32% top:-15% width:28% height:50%`

When redrawing, look up each building's overlay positions and design the silhouette so the overlay sits in a visually coherent spot (a doorway, a working area, a chimney mouth — not in midair over the roof).

---

## Work breakdown

### Already at the polish bar — DO NOT TOUCH
- `mill` — `assets/sprites/mill.svg` (+ `mill_body.svg` swap during producing)
- `grain_farm` — `assets/sprites/grain_farm.svg`
- `walkers` — `.walker-dot.walker-*` rules in `styles.css` ~line 380. Tiny 10×14 sprites; the polish bar doesn't apply at that size.
- `road` — autotiled via JS (`getRoadTileSVG()` in `map.js`). Different system entirely. Leave alone unless the owner asks.

### Recently converted to kiln-style inline SVG (PRIORITY UPGRADE)
These are the six the owner most recently saw in the kiln style and which prompted this plan. Tackle in this order — each change is one CSS rule edit + one panels.js entry:

1. `sawmill` — currently a wooden gabled mill with plank walls, dark saw bay, log pile. Upgrade target: the mill-grade tower polish but for a saw operation. Big visible spinning saw blade, lumber stack with woodgrain rings, sawdust-pile dust motes, etc.
2. `timber_camp` — currently log hut + golden thatched roof + log stack. Upgrade target: more elaborate thatch with gold/amber gradient streaks, individual log faces with concentric ring detail, an axe in a stump prop.
3. `stone_quarry` — currently terraced gray stone blocks + scaffold + pickaxe. Upgrade target: jagged rock face with multi-stop cool-gray gradient, more cut-block face shading, rope/pulley on the scaffold, dust motes at the base.
4. `mason_workshop` — currently stone walls + terracotta peaked roof + arched doorway + brick chimney. Upgrade target: mortar lines that follow the wall curvature, a more detailed tile pattern, brighter forge interior with embers, finished sculpture in front.
5. `house_t0` — currently dark wooden shanty with slanted plank roof. Upgrade target: rougher tarp/board patches, sand grain detail, asymmetric crooked posts, a single bucket.
6. `house_t1` — currently peaked-roof wooden hut, glowing window, chimney smoke. Upgrade target: shutters on the window, individual roof shingles, a small wooden fence accent, smoke wisps.

### Originally kiln-style inline SVG (SECOND BATCH)
These were never PNGs but use the same minimal kiln recipe. The owner said "all the other ones," which includes these. After the priority six are signed off, work through this batch:

7. `pottery_kiln` — the namesake. Dome silhouette + fire glow. Upgrade: stone block courses on the dome, a smoke trail above, a finished pot or two beside the kiln.
8. `bakery` — wooden walls + thatched arch + glowing oven mouth + chimney. Upgrade: bread loaves on a shelf, more detailed brickwork, smoke from the chimney.
9. `clay_pit` — radial-gradient pit + small post. Upgrade: water at the bottom, a small bucket on a rope, footprints/tools at the rim.
10. `woodcarver` — green-toned workshop + stacked planks + carving accent. Upgrade: a half-carved figure visible inside, woodchips on the ground.
11. `sculptor` — purple-toned workshop + statue + chisel. Upgrade: a finished statue out front, chisel marks on the work in progress.
12. `house_t2` (cottage) — already pretty detailed but at 32×32. Upscale viewBox + add roof shingles + window mullions + path to door.
13. `house_t3` (townhouse)
14. `house_t4` (villa)
15. `house_t5` (manor estate)

### Skip
- The `walker-*` SVGs in `styles.css` (~line 380) — these are 10×14 px and intentionally pictographic. The polish bar doesn't apply.
- The `assets/sprites/icons/` directory — orphaned PNG icons from the old build panel; can be deleted after all conversions land but no urgency.
- The `assets/sprites/walkers/` directory — check what's in it; likely also orphaned.

---

## Workflow per building

For each building, in order:

1. **Read the current state** — `grep -n "<key>" css/styles.css js/panels.js` to find both edit sites. Note the producing-overlay positions (search `<key>.producing`).
2. **Design at 64×64.** Sketch the SVG in a `/tmp/<key>_preview.svg` file with double-quoted attributes (easier to edit) and `width="256" height="256"` so you can render it.
3. **Render preview** — `convert -background none /tmp/<key>_preview.svg /tmp/<key>_preview.png` then read the PNG to eyeball the silhouette. ImageMagick may band cool-gray gradients; that's a renderer artifact, browsers render smoothly.
4. **Show the preview to the owner** before editing the live files. They sign off the look first; revisions are cheap at this stage.
5. **Convert to data URL.** Compact the SVG (single line, single-quoted attributes, no whitespace around tags) and URL-encode the four chars: `<` → `%3C`, `>` → `%3E`, `#` → `%23`, `%` → `%25`. Spaces and single quotes can stay as-is when wrapped in CSS double-quoted url().
6. **Edit `css/styles.css`** — replace the existing `.bldg.<key>` rule with the multi-line block:
   ```css
   .bldg.<key> {
     background-image: url("data:image/svg+xml,...");
     background-color: transparent; background-size: contain; background-repeat: no-repeat; background-position: center;
     filter: drop-shadow(0 1px 2px rgba(0,0,0,0.4));
   }
   ```
   For housing tiers, edit the `--house-sprite` value on `.bldg.house.house-t<N>` instead.
7. **Edit `js/panels.js`** — replace the matching `spriteIcons` entry with the same data URL. (Skip for housing tiers other than t1; the panel only shows the t1 icon.)
8. **Commit and push to `main`.** Pattern from existing commits (single-message subject + body, Co-Authored-By trailer):
   ```
   git add city-builder-mvp/css/styles.css city-builder-mvp/js/panels.js
   git commit -m "Convert <key> graphic to mill-grade polish"
   git push origin main
   ```
   GitHub Pages redeploys in ~40s. The CSS is served with `Cache-Control: max-age=600`, so the owner needs to hard-refresh or use incognito to bust the browser cache.
9. **Tell the owner the commit SHA + that they should refresh.** Move to the next building.

### Don't do
- Don't open a PR unless explicitly asked. The owner has been pushing straight to `main`.
- Don't bypass the preview step; the owner has rejected art before and prefers the cheap iteration.
- Don't delete the unused `assets/sprites/*.png` files yet — the owner hasn't asked, and a separate session may want to compare.
- Don't introduce a build step or asset pipeline. The site is static; the inline-SVG-in-CSS approach is intentional.
- Don't try to DRY the CSS+JS duplication preemptively. It's tracked in memory as "deliberate-but-temporary"; address it only if the duplication becomes painful (>10 buildings) or the owner asks.

---

## Quick reference

| File | What's in it |
|---|---|
| `css/styles.css` line ~151 onward | `.bldg.<key>` background-image rules (on-map sprites) |
| `css/styles.css` line ~270 onward | Producing-state worker/job overlays (positions matter for design) |
| `css/styles.css` line ~198 onward | Housing tier rendering via `--house-sprite` CSS variable |
| `js/panels.js` line ~54 | `spriteIcons` map (build-panel sidebar icons) |
| `assets/sprites/mill.svg` | Polish bar reference #1 |
| `assets/sprites/grain_farm.svg` | Polish bar reference #2 |
| `assets/sprites/mill_body.svg` | Sail-less mill body for the producing animation swap |

| Live URLs | |
|---|---|
| Game | https://atlas-asittley.github.io/city-builder-mvp/ |
| Repo | https://github.com/atlas-asittley/atlas-asittley.github.io |

| Commit history of this migration | |
|---|---|
| `e64c097` | Convert sawmill graphic to inline-SVG kiln-style art |
| `c540605` | Convert timber camp graphic to inline-SVG kiln-style art |
| `69d9607` | Convert house tiers 0 and 1 to inline-SVG kiln-style art |
| `9c22bce` | Use inline-SVG icons in build panel for converted buildings |
| `d79d194` | Convert stone quarry graphic to inline-SVG kiln-style art |
| `9465c23` | Convert mason workshop graphic to inline-SVG kiln-style art |

The new session should review these to see what the kiln-style starting point looks like — then upgrade past it.
