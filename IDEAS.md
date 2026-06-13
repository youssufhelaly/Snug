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
