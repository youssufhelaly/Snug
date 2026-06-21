# IDEAS.md — the scope-creep parking lot

Every "while we're at it..." idea lands here instead of in the build.

## Seeded from the v2 prompt pack
- **Orbit reveal video export (V1.1)** — separately budgeted ~1-week project,
  after TestFlight. Offscreen RealityKit → AVFoundation composition. The one
  pre-approved place a vetted third-party Swift Package is allowed if the
  hand-rolled pipeline fights back for more than two days.
- **Manual-dimensions mode for non-LiDAR devices (V2)** — ~~expansion path for
  the majority of the ICP without Pro phones~~. SUPERSEDED 2026-06: pulled
  into V1 as AR-assisted corner tapping (`ManualARCaptureMethod`), so V1 now
  runs on any modern iPhone, not just LiDAR Pros. RoomPlan stays as an
  optional higher-fidelity path. What remains parked for V2: a pure
  type-in-your-measurements fallback for devices with no usable ARKit
  tracking at all.
- **Photographic inpainting de-clutter (V2+)** — V1 de-clutter only removes
  RoomPlan-detected objects from the 3D model; no photo editing implied.
- **Per-room, confidence-weighted fit margins (V2)** — V1 uses ONE global
  error-margin constant from Phase 0's measured accuracy data.

## New ideas (append below, do not build)

- **Openings follow dragged corners (V2)** — the manual-AR drag-to-correct
  editor (`RoomShapeEditorView`) repositions floor corners only. Doors/windows
  keep their captured world coordinates, so heavily re-dragging a wall can leave
  an opening detached from it. V1 priority is wall geometry for the fit check;
  re-projecting openings onto their nearest corrected wall is a V2 polish.
- **Drag-to-correct for RoomPlan captures (V2?)** — the editor is gated to
  `.manualAR` provenance. LiDAR geometry is trusted straight to review. If real
  RoomPlan scans also bulge around furniture, open the editor to them too.
- **Furniture snap-to-wall (V2)** — direct drag positions furniture freely with
  red/amber/green fit feedback, but does not snap a piece flush to the nearest wall.
  Auto-snapping (and auto-resolving overlaps) is deliberately out of V1 — the user
  nudges and the feedback guides them. (Direct drag-to-move + pinch-to-resize SHIPPED
  in the interaction-redesign PR; snap remains parked.)
- **Furniture undo/redo (V2)** — placement auto-saves on every gesture end with no
  history stack. An undo/redo of moves/resizes/adds/removes is a V2 nicety.
- **Multi-select furniture (V2)** — selection is single-piece. Selecting and
  moving/resizing several at once is out of V1 scope.
- **Corner drag-handles on furniture (V2)** — pinch-to-resize is sufficient for V1;
  explicit on-entity resize handles are a later refinement.

- **Creative proxy → resize → fit → "find similar real furniture" (V2/V3 north-star)** —
  the big one. Decouples the creative half from the commerce half so PLAY's soul
  survives while BUY stays honest. The loop:
  1. **Proxy model (PLAY):** the user browses a LARGE library of stylized 3D
     furniture and drops one in. It's a *design sketch*, not a product — its
     original modeled size is irrelevant. Supply options, in licensing-safe order:
     CC0 / royalty-free pools, or **on-demand AI generation** (Meshy / Rodin /
     Tripo-style text-or-image→3D), NOT arbitrary scraped Sketchfab/CGTrader assets
     (mostly personal-use-only — licensing is a real gate).
  2. **Resize (already shipped):** the user drags it to the size they actually want
     in their scanned room. Pinch-resize + free-form dimensions already exist.
  3. **Honest fit, twice:** `FitService` runs against the size the USER chose, in
     the real room — so it never claims the proxy's fake dimensions. Then when a
     real product is picked (step 4), the fit RE-RUNS on that product's TRUE specs
     (the architecture already does this when a real `CatalogItem` is placed). Loop:
     *play with a proxy → resize to your space → find real options that fit → the
     real option's true dims get the honest check.*
  4. **Reverse search (the hard, expensive core — V2/V3, needs a backend):** the
     chosen dimensions + look become the search payload → visual-commerce search
     over real affiliate product feeds, CONSTRAINED BY SIZE, returning buyable
     furniture that's "similar look AND actually fits" (fit-alikes, not just
     look-alikes). Cleanest signal: render the posed proxy to an image →
     image→product search, filtered by category + chosen dims + color. This is the
     central engineering + business + partnership bet; it is the company.

  Why it's parked, not built: V1 is hard-ruled offline / no backend / "no network
  calls for furniture processing." None of it lands in V1. But nothing blocks it —
  `CatalogSource` is already a swappable protocol (a remote retailer/affiliate feed
  drops in with no rewrite — see [[catalog-buymode-feature]]), and the fit math
  already keys off the user's chosen dimensions, not the asset's. Honest-trust
  invariant for whoever builds this: the four-state fit badge must ALWAYS reflect
  real numbers (user-chosen size, then real-product size) — never a proxy's size.

- **Remote retailer/affiliate-feed catalog (V2)** — flip `CatalogSource` from the
  bundled JSON to a remote feed for hundreds of honest, buyable, dimension-accurate
  items without a code rewrite. The trustworthy way to scale catalog size; the
  natural backing index for the reverse-search idea above. Network → out of V1.
