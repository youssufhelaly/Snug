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
