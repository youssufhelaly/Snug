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

## Subsystem rules — auto-loaded by path
Deep, subsystem-specific knowledge lives in `.claude/rules/*.md` and
loads automatically when you open a matching file (each rule's `paths:`
frontmatter is the trigger). Don't duplicate that content here. The map:

- **capture.md** — Manual AR capture: floor baseline, high-wall projection,
  openings, ceiling look-up, drag-to-correct canvas. Triggers on `Features/Capture/**`.
- **data-model.md** — `RoomModel` / `StoredRoom` / `RoomStore`, SwiftData schema
  & migration rules. Triggers on `Core/Models/RoomModel.swift`, `Core/Persistence/**`.
- **fit-system.md** — FitService, the four honest states, confidence margins.
  Triggers on `Core/Services/FitService.swift`, `Features/Fit/**`.
- **furniture-detection.md** — Phase 2 detection philosophy, pipeline, out-of-scope,
  full impl status. Triggers on `*Furniture*` files + `RoomDioramaScreen`.
- **catalog-buymode.md** — the commerce loop, catalog spine, realistic models.
  Triggers on `Features/Catalog/**`, `CatalogItem*`, `CatalogService`, `Resources/**`.
- **rendering-modes.md** — PLAY↔BUY diorama, the identical-geometry invariant.
  Triggers on `Features/RoomScene/**`, `Core/Rendering/**`.
- **design-system.md** — colors, typography, motion, haptics, accessibility.
  Triggers on `Features/**`, `Core/DesignSystem/**`, `Core/UI/**`.
- **swift.md** — always use the `swiftui-expert-skill` for Swift/SwiftUI work.
  Triggers on any `**/*.swift`.

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
  The Phase 1 diorama (`Features/RoomScene`) is a SwiftUI `RealityView`.
  The post-capture floor-plan review is plain SwiftUI Canvas (2D).
- SwiftData for local persistence (rooms, designs, saved items),
  using SwiftData's native VersionedSchema + SchemaMigrationPlan
  for model evolution. Do NOT add custom version fields to models.
  Concrete shape is in the **data-model** rule (current schema: `SnugSchemaV1`).
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
  RoomScene (the 3D diorama, incl. the BUY-mode realistic-model path),
  Rooms (the "My rooms" home), Catalog (the buy-mode shop), Onboarding
  (first-run value slides + camera-permission primer, gated by
  `@AppStorage("hasOnboarded")` in `SnugApp`). Planned: Editor, Saved, Share.
- /Core holds shared services, models, and the design system
  (`Core/DesignSystem/Theme.swift` is the single source of truth
  for colors, the spring, and the per-mode `RoomPalette`).
- All RoomPlan / RealityKit work happens off the main thread
  except final scene mutations.
- Write code as if a second engineer joins next month: clear
  naming, no clever tricks, doc comments on every service's
  public API.

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
- Don't treat existing code as ground truth. When building a new feature
  and the established architecture doesn't fit it well, DO NOT bend the
  feature to match the current code by default. Evaluate both — the
  existing approach and the one the feature wants — and pick whichever is
  genuinely better. The current code may be right or may be wrong; decide
  on merit, and tell me when you think the existing pattern should change.
- Push back. When my feedback or an architecture decision looks wrong to
  you, say so with your reasoning rather than complying silently — and when
  you think I'm right, say that too. I want your honest engineering opinion,
  not agreement. Disagree, state the better option, then defer to my call.
- If you're uncertain about an iOS API's behavior, say so and study
  https://developer.apple.com/ for the authoritative reference — do not
  guess silently. This matters most for RoomPlan, RealityKit offscreen
  rendering, and AVFoundation, where confident hallucination is a known
  failure mode.
