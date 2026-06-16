# Snug — Project Context

## What this app is
Snug is a native iOS app for renters furnishing a new apartment.
The core loop: scan your room (10-second LiDAR sweep) → clear out
detected furniture → redesign in a playful stylized 3D view →
toggle to a true-to-scale, true-color "buy mode" → purchase real
furniture with an honest, uncertainty-aware fit check.

The product thesis in one line: **trust is the foundation, fun is
the brand.** Accurate geometry underneath, playful rendering on top.

## Who it's for (V1)
Urban renters, age 22–35, with a LiDAR-capable iPhone, furnishing
a first or new apartment on a budget of roughly $500–$2,000.
Everything in the catalog must be no-drill, no-paint, removable,
deposit-safe.

## Tech stack — do not deviate without asking
- Swift 5.10+, SwiftUI for all UI
- iOS 26.0 minimum deployment target
- Room capture is abstracted behind a `RoomCaptureMethod` protocol that
  always produces our own `RoomModel`. Two conformers exist:
  - `ManualARCaptureMethod` (DEFAULT) — AR-assisted corner tapping on
    ARKit `ARWorldTrackingConfiguration`. No LiDAR; runs on any modern
    iPhone. This is the device class we actually target.
  - `RoomPlanCaptureMethod` — Apple RoomPlan / LiDAR sweep. Kept, but
    offered only on LiDAR-capable Pro devices and never the default.
  Detect capability at launch; show the graceful unsupported screen
  only when neither method is available.
- RealityKit for the live AR capture overlay and the 3D room view.
  The Phase 1 diorama (`Features/RoomScene`) is a SwiftUI `RealityView`
  driving a true `OrthographicCameraComponent` — migrated off the legacy
  `.nonAR ARView` (`UIViewRepresentable`). The post-capture floor-plan
  review is plain SwiftUI Canvas (2D).
- SwiftData for local persistence (rooms, designs, saved items),
  using SwiftData's native VersionedSchema + SchemaMigrationPlan
  for model evolution. Do NOT add custom version fields to models.
  Concrete shape is in "Data model & persistence" below (current
  schema: `SnugSchemaV1`).
- No third-party dependencies in the core app. One exception is
  pre-approved: the V1.1 video-export module may use a vetted
  Swift Package if offscreen RealityKit→AVFoundation composition
  proves too fragile by hand. Ask before adding it.
- No backend in V1. Everything local. Catalog ships as a bundled
  JSON + USDZ asset pack. Design models so a remote catalog can
  replace the bundled one later.

## Architecture rules
- MVVM. Views are dumb. ViewModels are @Observable classes.
  Business logic lives in plain services (RoomCaptureService,
  FitService, CatalogService, RoomStore, DesignStore), injected
  via environment. `RoomStore` (Phase 1) owns saved-room
  persistence; `DesignStore` (Phase 4) will own saved layouts.
- One feature = one folder under /Features. Present: Capture, Fit,
  RoomScene (the 3D diorama), Rooms (the "My rooms" home). Planned:
  Editor, Catalog, Saved, Share, Onboarding.
- /Core holds shared services, models, and the design system
  (`Core/DesignSystem/Theme.swift` is the single source of truth
  for colors, the spring, and the per-mode `RoomPalette`).
- All RoomPlan / RealityKit work happens off the main thread
  except final scene mutations.
- Write code as if a second engineer joins next month: clear
  naming, no clever tricks, doc comments on every service's
  public API.

## Data model & persistence
- `RoomModel` is the app's ONE canonical room representation: a
  plain `Codable`/`Equatable` value type (floor-corner polygon,
  ceiling height, openings; walls/area/diagonal are derived). Every
  capture method produces it; `FitService`, the diorama, the
  accuracy logger, and the test fixtures all read it. It is NOT a
  SwiftData `@Model` — keep it a value type.
- Persistence wraps it, never replaces it. `StoredRoom` (a SwiftData
  `@Model` inside `SnugSchemaV1`) stores the whole `RoomModel` as a
  JSON `Data` blob plus a few DENORMALIZED columns for listing
  without decoding (`id`, `name`, `capturedAt`, `thumbnailData`).
  This deliberately avoids a second source of geometry truth. The
  blob's evolution rides on `RoomModel`'s own `Codable`; SwiftData
  migrations (`SnugMigrationPlan`) handle the surrounding columns.
- `RoomStore` is the only writer of saved rooms (save / update /
  rename / setThumbnail / delete + encode-decode). Views list rooms
  reactively with `@Query`; mutations go through `RoomStore`. It is
  a plain `@Observable` (not `@MainActor`) holding the container's
  **main** `ModelContext`, so it must be used on the main thread.
- Adding a new persisted field to a room (e.g. Phase 2's detected
  objects) = add it to `RoomModel` (with a Codable default so old
  blobs still decode) and, if `StoredRoom`'s columns change, bump to
  `SnugSchemaV2` with a migration stage. Never add a manual version
  field.

## Manual AR capture (ManualARCaptureMethod)
`ManualARCaptureMethod` is a stateless factory; all per-session AR
state lives in `ManualARCaptureController` (it owns the ARSession and
must be an NSObject delegate). When this section says "on
ManualARCaptureMethod" it means the manual-AR capture feature as a
whole, implemented in that controller. Per the architecture rules,
NONE of this state leaks into `RoomModel` except
`resolvedCeilingHeight`, written once at scan close. `RoomModel`
stores a single ceiling-height value and does not know how it was
derived. `FitService` is unchanged.

### Floor baseline — weighted average
- `floorTaps: [(y, weight, anchorID, position)]` accumulates one
  sample per accepted direct floor-corner tap. `sessionFloorY` is the
  weight-weighted average of their `y`. High-wall taps NEVER append to
  `floorTaps`.
- Weights map to exactly three ARKit outcomes (no invented confidence
  APIs): `ARPlaneAnchor` classified `.floor` → `1.0`; any other
  detected plane anchor → `0.5`; estimated geometry only (no plane
  anchor) → `0.2`.
- Spatial deduplication runs BEFORE accumulating: a tap is kept only
  if its XZ position is ≥ `0.5 m` from every existing tap, OR it
  belongs to a plane anchor whose identifier isn't represented yet.
  This exists so repeated taps in one spot can't dominate the weighted
  average and bias (warp) every projected high-wall corner.
- After a floor baseline exists, direct floor-corner raycasts more
  than `0.15 m` above/below that baseline are rejected. This prevents
  accidental taps on furniture/tabletops from placing wildly shifted
  corners.
- Floor is "locked" once the cumulative deduplicated weight exceeds
  `2.0`. The UI shows "Floor locked" / "Tap a floor corner first".

### High-wall projection (replaces two-tap intersection)
- The "Corner blocked?" toggle is always tappable (never disabled);
  when the floor isn't locked yet it shows a soft warning instead.
- On a high-wall tap: retain the raycast's X/Z, snap Y to
  `sessionFloorY`. Store as a corner — it's already floor-snapped.
  `usedHighWallProjection` is set to `true` on this path. A
  successful high-wall placement is one-shot: the controller
  immediately exits high-wall mode so the next tap returns to normal
  floor-corner tapping. Failed wall taps leave the mode active so the
  user can retry.
- Fallback (live, not dead code): if `sessionFloorY` is nil, use
  `cameraTransform.columns.3.y - 1.4` and log a warning. The correct
  camera-height accessor is `cameraTransform.columns.3.y`.
- A dotted vertical alignment guide is drawn (2D SwiftUI overlay) from
  the centre crosshair to the bottom of the viewport while aiming;
  without it, horizontal aiming error warps the floor plan.
- Two-tap intersection is deprecated (`@available(*, deprecated)`) and
  removed from all active UI paths, but not deleted yet. It was
  replaced because it needed two precise wall-parallel sightings —
  fiddly to aim, prone to near-parallel lines and corners resolving
  behind the user. High-wall projection needs a single tap.

### Openings — snap to captured walls
- Door/window/opening taps happen after the room polygon is closed.
  The user can tap either the wall face or the floor/base of the
  opening.
- Opening capture raycasts vertical and horizontal planes separately,
  then chooses the candidate whose X/Z snaps closest to the captured
  wall outline. This avoids saving raw AR wall/floor hits that are
  shifted relative to the user's tapped room polygon.
- The first tap of an opening stores both the snapped point and the
  wall segment index. The second tap is forced onto the same wall
  segment, so a doorway/window cannot drift diagonally onto a nearby
  plane.

### Ceiling height — one-time look-up + edit, never typed
We never ask the user to type a number. The goal is a reasonable
estimate plus an edit option, not perfect measurement — chasing exact
ceiling measurement on non-LiDAR hardware is the one genuinely
unreliable measurement, so a sensible default + a visible adjust
control is more honest than fake precision.
- Manual AR does NOT passively estimate ceiling height during corner
  capture. Sparse feature points seen while scanning corners vary too
  much between runs and create false precision.
- On `Done`, after all optional doors/windows are marked, the app runs
  one full-screen "point at the ceiling" look-up step. It collects raw
  feature points only while `isLookingUp == true`.
- The look-up accepts only plausible floor-relative heights in
  `2.1...3.2 m`, requires at least `60` plausible active ceiling
  points, uses the median of those heights, and rounds to `0.05 m`.
  If there are too few plausible points after 1 second, the prompt
  extends once with "Keep pointing up…".
- Final resolution, strict priority: (1) future RoomPlan hand-off
  height if populated, (2) accepted one-time look-up height,
  (3) `2.5 m` default. Result is stored in `resolvedCeilingHeight`
  and written to `RoomModel` once. Confidence is high for an accepted
  look-up, low for the default.
- Manual AR avoids AR scene reconstruction/mesh during capture because
  it adds startup load on LiDAR devices and the flow only needs plane
  raycasts plus feature points for the one-time ceiling look-up.

### Conditional drag-to-correct canvas
- The canvas opens automatically after scan close when
  `usedHighWallProjection`, the floor never locked (cumulative weight
  < `2.0`), or the ceiling confidence is low. Together these three
  flags drive the trigger. Otherwise the result screen shows an
  unobtrusive "Review layout" button.
- The canvas edits `position.x`/`position.z` on corners only (never
  `position.y`); handles are keyed by stable `UUID`, never array
  index. It includes the ceiling-height edit control (2.0–4.5 m, 0.1
  steps); committing overwrites `resolvedCeilingHeight` and
  re-extrudes the room.
- `GeometryValidator` is a standalone, unit-testable struct (no UI).
  It runs reactively on corner changes (never on button press) and
  drives the commit button's disabled state and the error ribbon:
  no self-intersection, every wall > 0.3 m, shoelace area > 1.0 m².

## Design system — "playful but trustworthy"
- Aesthetic: warm, rounded, optimistic. Think Headspace meets
  Nintendo, NOT corporate furniture catalog.
- Colors (define in Core/DesignSystem/Theme.swift as a single
  source of truth):
  - background: warm off-white #FAF7F2 (dark mode: #1C1A17)
  - primary accent "Clay": #E8714A
  - secondary "Sage": #7FA886
  - ink (text): #2B2722 (dark mode: #F0EDE8)
  - subtle: #8A847C
- Typography: SF Rounded for headings and buttons, SF Pro for
  body. Generous sizes — minimum body 16pt.
- Corners: 16pt radius on cards, 24pt on sheets, fully rounded
  pill buttons.
- Motion: spring animations (response 0.4, damping 0.8) on every
  state change. Bouncy and alive, never abrupt.
- Haptics on every meaningful action (scan complete, item placed,
  fit result shown).
- Empty states and errors are friendly, never blank or technical.
- Accessibility is not optional: Dynamic Type, VoiceOver labels on
  all interactive elements, reduced-motion variants.

## The two rendering modes (core product mechanic)
- PLAY MODE (default): stylized rendering — soft pastel material
  overrides, slightly exaggerated ambient lighting, simplified
  shadows. Fun to look at, fast to render.
- BUY MODE (toggle): TRUE-TO-SCALE, TRUE-COLOR. Catalog items
  render with their real material colors from the catalog data,
  neutral lighting, and visible dimension labels. We do not claim
  or attempt photorealism in V1 — accuracy of size and color is
  the promise, and stylization must never alter either in this
  mode. One-tap toggle, always visible, cross-fade < 400ms.
- Implementation (Phase 1, `Features/RoomScene`): the diorama is one
  RealityKit scene built once from `RoomModel`; PLAY↔BUY swaps ONLY
  materials + lighting (and toggles BUY dimension labels) — never a
  vertex. Render-mode colors come from `RoomPalette` in Theme.swift.
  It's an open-top "dollhouse": no ceiling, and walls between the
  camera and the interior are culled each frame so you can see in.
  The < 400ms cross-fade freezes the current frame, swaps materials
  beneath it, and fades the freeze out (a SwiftUI image overlay); the
  same frame is the room's list thumbnail. Since `RealityView` has no
  `ARView.snapshot`, both are produced offscreen by
  `OffscreenSnapshotRenderer` (RealityKit `RealityRenderer`), which clones
  the live scene and FAILS LOUDLY rather than faking a frame — on failure
  the mode swaps with no fade. PLAY image-based lighting is an
  `ImageBasedLightComponent` (+ receiver on the root, PLAY only), and the
  warm "void" backdrop is a SwiftUI `Color` behind the `RealityView`
  (it renders transparent), not a skybox. If you touch this, the
  identical-geometry invariant is the acceptance gate — verify with a
  wireframe overlay.

## The fit system (the trust layer — highest-stakes code in the app)
- FitService computes placement results against REAL scanned
  geometry, using ONE global error-margin constant in V1, set from
  Phase 0's measured accuracy data. (Per-room, confidence-weighted
  margins are a V2 idea — keep it in IDEAS.md.) It reports four
  states:
  1. "Fits with room to spare" — clearance > error margin × 2
  2. "Fits" — clearance > error margin
  3. "Too close to call — measure this wall" — clearance within
     the error margin. We TELL the user to grab a tape measure.
     This honesty IS the brand; never round it to a green check.
  4. "Won't fit" — negative clearance beyond the error margin
- FitService is pure, deterministic, and unit-tested against
  serialized real-scan fixtures. No UI code inside it. Treat any
  change to it as high-risk and test-first.

## Furniture detection philosophy
- Preserve room identity, not photorealistic furniture reconstruction
- Users need to recognize their room, not own a digital twin
- Detection produces: category, floor position, estimated dimensions, perceptual color, material class
- No texture projection, no custom shaders, no baked shadows
- All detections are honest about their confidence level

## Furniture detection (Phase 2)
- Model: YOLO26n CoreML (YOLO26nFurniture.mlpackage), bundled, offline
- Timing: post-scan dedicated pan step, NOT during corner capture
- Consensus gate: Rolling IoU tracking tracker, >= 3 consecutive frames or >= 1.5s lifetime
- Floor snapping: always snap Y to sessionFloorY from ManualARCaptureController
- Dimensions: category priors scaled by pixel-width estimate, clamped ±40%
- Color: Lab-space perceptual mapping to 15 named categories constrained inside instance alpha mask
- Material: category heuristic in V2, classifier in V3
- Fallback: manual category picker — treat as first-class, not error state
- FitService confidence: .detected = standard margin, .estimated/.manual = 1.5× margin

## Out of scope for furniture detection (do not build)
- Texture projection or projective shaders
- Photogrammetry or mesh reconstruction
- NeRFs, Gaussian splats
- Baked lighting or shadows on furniture assets
- Per-item custom 3D model generation
- Any network calls for furniture processing

## Furniture detection — implementation status (for the next engineer)
Phase 2 is landing in layers. What exists and is unit-tested today:
- The value types (`Core/Models/FurnitureModels.swift`): `FurnitureObservation`,
  `FurnitureCategory` (priors + display + SF Symbols), `FurnitureFootprint`,
  `FurnitureAppearance`, `FurnitureColorCategory`, `FurnitureMaterialClass`.
- `RoomModel.detectedFurniture` — persisted in the existing JSON blob. RoomModel
  now has a CUSTOM `Codable` (`decodeIfPresent ?? []`) because Swift's synthesized
  decoder does NOT honor property defaults for missing keys; the custom decoder is
  what lets pre-Phase-2 blobs still decode. No `SnugSchema` version bump needed
  (the `StoredRoom` columns are unchanged).
- `FurniturePlacementService` — PURE (no ARKit). The AR layer resolves the
  bottom-center raycast and hands it `Input`; this service snaps Y to the floor,
  clamps XZ into the room polygon, and back-projects/clamps width (±40%).
- `FurnitureColorClassifier` — PURE sRGB→Lab nearest-category mapping; the pixel
  sampling (mask-intersected 5×5 grid, ~1000-lux frame) is the detection layer's job.
- `FurnitureFootprint.fitObstacle` / `[…].keptObstacles` — the kept→obstacle bridge.
- `FitService` — per-obstacle margin widening via `FitObstacle.Confidence`
  (`.estimated` ⇒ 1.5×). Implemented by NORMALIZING each constraint's clearance by
  its multiplier and classifying against the base margin (the four-state thresholds
  scale linearly with the margin, so this is exact and leaves the all-`.measured`
  path byte-identical). It never blocks placement — only shifts toward "too close".
Landed but DEVICE-VERIFY (compiles/passes only on a Mac; written to spec, not run
on Linux — validate the AR/Vision/RealityKit specifics on an AR iPhone):
- `FurnitureDetectionService` (Vision/CoreML). Pure `consensus`/`iou` are unit-tested;
  the Vision parsing assumes a `VNRecognizedObjectObservation` export (validate the
  label set), `processFrame` mutates `@Observable` state only via `MainActor.run`,
  and the `CVPixelBuffer` is held for the request's lifetime. `#if DEBUG` injects
  synthetic detections when the model isn't bundled.
- Pan step wired into `ManualARCaptureController` (Option A): new `.furnitureDetection`
  `Step` between `markingOpenings` and `review`. `Done` → `furnitureDetection` →
  (auto/skip) → `review`. Skippable to the manual picker; auto-skipped when no model.
- SwiftUI surfaces: `FurnitureDetectionView` (pan progress + Skip), `ManualFurniturePickerView`
  (first-class fallback, ≤ 8 items), `DeclutterView` (keep/clear over the diorama).
- `FurnitureEntityBuilder` — collision + input-target + footprint-id-tagged boxes
  (unit-tested for bounds/components on device).
- The Vision→ARView bbox mapping (`displayTransform`) in `floorHit` is the part most
  likely to need a device tweak (orientation/viewport).

Still TODO:
- Bundling `YOLO26nFurniture.mlpackage` — ON HOLD pending confirmation of a stable
  YOLO26n CoreML export (asset not in the repo yet). Until then DEBUG synthetic mode
  / the manual picker carry the flow.
- Rendering `FurnitureEntityBuilder` boxes INSIDE the live diorama with 3D
  tap-to-clear (RealityView targeted gestures, extending `RoomSceneController`'s
  hit-testing). `DeclutterView` currently drives keep/clear over the diorama backdrop;
  the model contract (`isKept`/`isCleared`) is identical either way.
- Device color sampling: the mask-intersected pixel grid that feeds the (pure,
  tested) `FurnitureColorClassifier`; footprints default to `.other` color until then.

## Hard rules
- NEVER fake the scan. If RoomPlan fails or confidence is low,
  say so and offer a rescan. No silently invented geometry.
- Never display false precision. Dimensions shown to users are
  rounded to the centimeter and accompanied by the fit state, not
  presented as exact truth.
- No dark patterns: no fake urgency, no hidden costs. Affiliate
  relationships disclosed in UI copy.
- Build offline-first. Fully usable with no network in V1.

## Out of scope for V1 — do NOT build these even if tempted
Creator marketplace, accounts/auth, co-living multiplayer, room
health score, Android, iPad layouts, in-app checkout (V1 links out
to retailer with disclosure), multi-room projects, photorealistic
rendering, photographic inpainting, orbit reveal VIDEO export
(image pair only in V1 — video is a separately scoped V1.1
project). NOTE: the old "manual-dimensions mode for non-LiDAR
devices (V2)" item has been PULLED FORWARD and reframed — V1 now
ships AR-assisted corner tapping (ManualARCaptureMethod) as the
default capture path so non-Pro iPhones are first-class. Pure
typed-dimensions entry with no AR remains out of scope.

## Testing & quality bar
- Unit tests for all services using Swift Testing. FitService gets
  the deepest coverage, driven by serialized RoomModel fixtures
  (exported from either capture method) plus the real CapturedRoom
  fixtures from Phase 0 where available.
- Each phase ends with a manual on-device test script.
- Zero compiler warnings policy.
- Run and fix the build before declaring any task done.

## How to work with me
- Before writing code for any task, give me a 5-line plan and wait
  for my OK if the task touches more than 3 files.
- After completing a task: summarize what changed, list files
  touched, and give me the on-device test steps.
- If you're uncertain about an iOS API's behavior, say so ans study this website https://developer.apple.com/ for more info about everything apple developer  — do not guess silently. This
  matters most for RoomPlan, RealityKit offscreen rendering, and
  AVFoundation, where confident hallucination is a known failure
  mode.
