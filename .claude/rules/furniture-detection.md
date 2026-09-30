---
paths:
  - "Snug/Core/Models/Furniture*"
  - "Snug/Core/Services/Furniture*"
  - "Snug/Features/RoomScene/Furniture*"
  - "Snug/Features/RoomScene/RoomDioramaScreen.swift"
  - "Snug/Features/RoomScene/FineTuneSheet.swift"
  - "Snug/Features/Capture/FurnitureDetectionView.swift"
  - "Snug/Core/Rendering/PlayModeFurniture.swift"
---

# Furniture detection (Phase 2)

## Philosophy
- Preserve room identity, not photorealistic furniture reconstruction
- Users need to recognize their room, not own a digital twin
- Detection produces: category, floor position, estimated dimensions, perceptual color, material class
- No texture projection, no custom shaders, no baked shadows
- All detections are honest about their confidence level

## Pipeline
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

## Implementation status (for the next engineer)
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
  (auto/skip) → `review`. Skip just CLOSES the step now (no inline picker);
  auto-skipped when no model. Manual add/transform moved to the post-capture tray.
- Furniture placement is NOT a wizard. There is no "placement step" / "Done" —
  `RoomDioramaScreen` is a persistent interactive canvas. After review, `Done`
  saves and opens the room; furniture is added/edited there anytime and AUTO-SAVES
  on each gesture end (`RoomStore.update`). (`FurniturePlacementTray`, `DeclutterView`,
  and the `.placingFurniture` flow step were removed.)
- Interaction model (all in `RoomDioramaScreen` + `SceneGestureOverlay`, UIKit gestures):
  tap a piece to select (Clay emissive highlight, additive over the red/green tint),
  single-finger drag the selected piece to move it on the floor, pinch it to resize
  width/depth (height fixed, floor-anchored). Drag on empty space orbits; pinch on
  empty space zooms (camera gestures unchanged — added to, not replaced). A drag on
  an UNselected piece selects it without moving. Selected → a micro-pill (label /
  Fine Tune / trash); Fine Tune opens a ≤40% `FineTuneSheet` (W/D/H + rotation, no
  X/Z). A persistent `+ Add` opens `FurnitureCarouselOverlay` (≤8 items).
- Gesture↔camera disambiguation: furniture tap/drag/pinch are NATIVE RealityKit
  SwiftUI gestures (`.targetedToAnyEntity()`) at `.highPriorityGesture`, so
  RealityKit unprojects to the correct entity for the orthographic camera (no
  manual ray math — the old UIKit-overlay + hand-rolled ortho ray drifted
  off-axis). Camera orbit + pinch-zoom are plain SwiftUI gestures handling empty
  space, feeding the unchanged `RoomSceneController` orbit/pinch math. Drag-move
  uses `value.convert(value.location3D, …)` to the floor; TWO-FINGER CAMERA PAN
  was dropped (SwiftUI has no clean 2-finger pan; `RoomSceneController.pan`
  remains, unbound, for a future recognizer).
- `RoomSceneController.syncFurniture` keeps furniture entities in a store SEPARATE
  from wall/floor building. Live drag/pinch
  mutate the entity (transform / in-place mesh + collision) directly for immediacy;
  the footprints are pushed up and persisted on gesture end.
- `FurniturePlacementValidator` (pure): boundary + SAT-overlap → red/amber/green;
  `FurnitureEntityBuilder.applyPlacementState(_:selected:to:)` tints per state + selection.
- Camera is a NARROW-FOV (14°) `PerspectiveCameraComponent`, NOT orthographic:
  RealityKit's native entity gesture hit-testing (`targetedToAnyEntity`/`unproject`)
  does not work against an ortho camera on iOS, so taps/drags don't register. The
  long lens reads near-isometric (minimal foreshortening; dimension labels still show true
  measurements). `updateCamera` only moves the camera (zoom = distance via `radius`)
  and never re-sets the component, so it stays perspective for the whole session.
  `frameCamera` fits the room to that FOV (×0.85 to fill), aims at the floor centroid,
  elevation 45° — global to all rooms.
- ARSession lifecycle: `attach` runs with `[.resetTracking,.removeExistingAnchors]`,
  `deinit` releases the session, a `didBecomeActive` observer resumes the feed WITHOUT
  reset (preserving placed corners) — fixes the black-camera-on-second-scan.
- The Vision→ARView bbox mapping (`displayTransform`) in `floorHit` is the part most
  likely to need a device tweak (orientation/viewport).

Still TODO:
- Bundling `YOLO26nFurniture.mlpackage` — ON HOLD pending confirmation of a stable
  YOLO26n CoreML export (asset not in the repo yet). Until then DEBUG synthetic mode
  / the manual `+ Add` catalog browse (see the buy-mode rule) carry the flow.
- Device color sampling: the mask-intersected pixel grid that feeds the (pure,
  tested) `FurnitureColorClassifier`; footprints default to `.other` color until then.
- The ortho `floorPoint` projection constants and the drag/pinch feel need device
  tuning (written to spec, not run on hardware here).
