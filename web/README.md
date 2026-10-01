# Snug web demo

A browser version of Snug's core loop: put real Amazon furniture into a room at its real size, drag it around, and get an honest fit verdict. It exists so anyone can try Snug from a link, without an iPhone.

The iOS app is still the real product. It measures your actual room with AR. The web demo uses sample rooms, or a rectangle you type in, and says so on screen.

## What carries over from the iOS app

- **The fit check is a direct port.** [`src/fit/`](src/fit) is a line-for-line TypeScript port of `FitService.swift` and `FitGeometry.swift`. It returns the same four states with the same 5 cm margin. The Swift test cases are ported in [`test/`](test), so the two can't quietly drift apart.
- **Mesh fitting is ported too.** [`src/scene/modelFit.ts`](src/scene/modelFit.ts) mirrors `CatalogModelLoader.approximateFitTransform`. Every footprint is exactly the product's real width and depth. The mesh is only for looks. Each piece shows a true-size box until its model loads, and keeps that box if loading fails.
- **The catalog is the same 15 products.** [`scripts/sync-catalog.mjs`](scripts/sync-catalog.mjs) copies them from the app's `catalog.json`. It drops hard-coded prices, hot-linked Amazon images and the placeholder affiliate tag.

## Features

- Two sample rooms: a bedroom with a door and window, and an L-shaped studio. You can also type in your own room size.
- Search and category filters.
- New pieces auto-place in the spot with the most clearance, away from doorways.
- Drag to move, rotate in 15° steps, and nudge with the arrow keys for centimeter tests.
- A live fit verdict per piece, naming the wall or piece that limits it.
- "Copy link" encodes the whole layout in the URL.
- "Before / after image" exports a shareable PNG of the empty and furnished room.

## Run it

```sh
npm install
npm run dev        # http://localhost:5173
npm test           # fit and mesh-fit unit tests
npm run build      # static site in dist/
```

## Deploy

The site is fully static, so any static host works.

- **GitHub Pages.** The workflow in `.github/workflows/web.yml` tests, builds and publishes on every push to main. Turn it on once in Settings > Pages by setting the source to "GitHub Actions". The site then lives at `https://<user>.github.io/Snug/`.
- **Cloudflare Pages or Vercel.** Import the repo, set the root directory to `web`, the build command to `npm run build`, and the output directory to `dist`.

Optional build-time variables. Anything unset stays hidden.

| Variable | Effect |
|---|---|
| `VITE_AMAZON_TAG` | Your Amazon Associates tag. Adds it to product links and shows the commission disclosure. |
| `VITE_TESTFLIGHT_URL` | Shows a "Get the iPhone app" button. |

On GitHub Pages, set them as repository variables named `AMAZON_TAG` and `TESTFLIGHT_URL`.

## Asset pipeline

| Command | What it does |
|---|---|
| `npm run optimize-models` | Simplifies the raw Tripo meshes to about 60,000 triangles, with 1024 px WebP textures and meshopt compression. That shrinks 664 MB of source models to about 10 MB. |
| `npm run thumbs` | Renders a catalog thumbnail per product from our own models, using the locally installed Chrome. |
| `npm run sync-catalog` | Re-copies the catalog from the iOS app. |
| `npm run e2e` | Drives the built site in Chrome. It drags a piece into a wall, adds a piece, restores a shared link on a phone-sized screen, and exports the before/after image. Run `npx vite preview --port 4173` first. |

## Known limits

- The rooms are samples, not scans. The fit math is the app's, but the room geometry isn't measured.
- Tripo meshes don't share a consistent "front", so some products may need a turn to face the right way. The footprint is always correct.
- Doorway clearance only guides auto-placement. Fit verdicts ignore doors, like the iOS app does today.
