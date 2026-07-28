# IDEAS.md — the scope-creep parking lot

Every "while we're at it..." idea lands here instead of in the build.

> **Note (2026-07-06):** Several items once parked here have GRADUATED into the
> core product vision and now live in `VISION.md` as the real roadmap, not the
> "don't build" list: the creative-proxy → resize → fit → **reverse-search for
> real furniture that fits** loop, the **two-catalog** (Verified vs. Ideation
> Sandbox) model, **paste-a-link → 3D**, **snap-a-photo → reverse-search → 3D**,
> **describe-a-room → AI preset layout**, and **first-person walkthrough**. Read
> `VISION.md` for how they sequence. What stays below is genuinely deferred
> polish and the truly-out-of-V1 stuff.

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
- **Furniture snap-to-wall** — ~~direct drag positions furniture freely with
  red/amber/green fit feedback, but does not snap a piece flush to the nearest wall.
  Auto-snapping is deliberately out of V1.~~ SUPERSEDED 2026-06: pulled forward as a
  DELIBERATE one-tap action (micro-pill "snap to wall" button → `WallSnapService`
  glides the piece flush to the nearest wall, back-to-wall yaw). Drag-time *magnetism*
  stays out (it fights precise placement); the user still nudges, the button snaps.
  What remains parked: **auto-resolving overlaps** between pieces.
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

  - **Refinement 2026-06-23 — two named catalogs + a splittable bridge.** Model the
    above as TWO isolated data tracks sharing one renderer:
    - **Verified Catalog** (commerce/trust): real manufacturer USDZ placed **1:1,
      zero scaling** — `fitTransform` degenerates to the identity (native dims ≈
      target dims), so nothing warps. Retailers publish AR Quick Look USDZ
      (`Snug/Resources/Models/README.md`), so this is populatable with permission.
      A Verified SKU with NO real USDZ yet must render the **honest stylized box**,
      NOT a dressed-up generic asset — stretching a generic shape to impersonate a
      real product is the exact anti-pattern this whole idea rejects.
    - **Ideation Sandbox** (engagement/design): generic CC0 shapes, **deliberately
      elastic**. The per-axis stretch we feared is a FEATURE here — the user sculpts
      digital clay, making no purchase claim. The `tools/catalog/` pipeline
      (Quaternius/Kenney/ITHappy → ARKit USDZ + the aspect-ratio guardrail) feeds
      THIS track, not Verified.
    - **The bridge splits by network dependency:**
      - ✅ V1-feasible, LOCAL, offline: *dimensional* reverse-search — the
        resized Sandbox piece's bounding box filters the bundled Verified catalog
        within ± a tolerance that SHOULD be the same constant as `FitService`'s
        error margin ("3 real sofas match this footprint"). No backend, on-thesis.
      - 🚫 V2/V3, remote: *style/visual* ranking — embeddings, image→product search,
        affiliate feeds. This is the backend bet already described above.
    - **Trust-boundary UX hazard:** a stretched Sandbox piece must never read as
      buyable-and-fitting. The named split makes "ideation" vs "real & fits"
      unmistakable; the moment elastic geometry touches a price/fit claim, the brand
      promise breaks.

- **Remote retailer/affiliate-feed catalog (V2)** — flip `CatalogSource` from the
  bundled JSON to a remote feed for hundreds of honest, buyable, dimension-accurate
  items without a code rewrite. The trustworthy way to scale catalog size; the
  natural backing index for the reverse-search idea above. Network → out of V1.

- Feature where you are able to describe and ai generate furniture which deos not exist in catlog, you can even ai generate a whole room after describing style and vibe of room and what you want 

- **First-person walkthrough mode (V2)** — a "step inside your room" *preview*, not an
  editor. The iso "Isometric Cozy Minimalism" diorama answers *"is it arranged right?"*;
  first-person at human eye height (~1.6m) answers the question a renter actually has:
  *"what will it feel like to walk in?"* Cheap to build on what exists — geometry is
  already shared (PLAY↔BUY identical-geometry invariant) and it's a RealityKit scene, so
  this is fundamentally a **camera pose change**: drop the camera to standing height, swap
  orbit gestures for look-around. Design guardrails:
  - **Preview, not edit.** Dragging furniture from eye level is bad (depth is ambiguous,
    near objects occlude far). Keep arranging in iso; "step inside" to experience it; step
    back out to adjust. Do NOT try to make it the primary editor.
  - **Constrained navigation, not free-roam.** A few preset vantage points (doorway, bed,
    desk) you tap between + look-around gets ~90% of the value and dodges the collision/
    clipping/WASD rabbit hole. Full free-roam is the scope trap.
  - **It's a trust moment (on-thesis).** Standing in the doorway seeing a true-to-scale
    piece at eye level in real color (BUY mode) is a more honest "will this work" gut-check
    than a top-down toy — a natural home for the fit badge.
  - **Distinct from AR passthrough.** This is *virtual* first-person (inside the rendered
    room). Holding the phone up in your real room to composite furniture in is the AR
    fit-check path — a different feature. Do the virtual one first; it reuses everything.
# Take a pictiure of a furniture you like  in a store or somewhere and have a 3d version of it in you app
# you enter an link of. aproduct you wanna see in you rworl. we make an api call get images convert to 3d goive it to you 
# The core idea is an "Infinite Catalog Sandbox"—transforming Snug from a curated boutique app into an unrestricted e-commerce engine where users can search for and place any real-world Amazon furniture item directly into their space. 
To keep it from destroying your margins or tanking your UX, the idea relies on a strict split:

The Browse Layer: Free, lightning-fast, and dirt-cheap keyword searching powered by third-party product data APIs.

The Generation Layer: High-cost, high-latency 3D conversion that is heavily guarded by global cloud caching (so you only pay to generate an item once) and locked behind a premium paywall (Snug Pro).

# Cache the full raw Canopy response per ASIN to disk (raw_cache/<asin>.json in tools/catalog/), at the moment lookup() is called — regardless of which fields we currently parse. That way any field we didn't think to use today (galleries, bullets, specs, and rating/reviews once added) is sitting on disk forever, and a future "oh we need X" never costs another API call for ASINs we've already looked up.
Persist imageUrls (full gallery) into asins_draft.json/asins.json entries, not just mainImageUrl.
Add rating + review count to the query — but I don't want to guess Canopy's actual field names (their docs drift from the live schema, per the warning already in canopy.py). This needs one live --introspect call against the schema first to confirm the real field names before I wire them in.
Update seed_catalog.py's resume logic so re-runs check the raw cache before calling lookup() again (skip the network call entirely if already cached).