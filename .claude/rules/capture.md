---
paths:
  - "Snug/Features/Capture/**"
  - "Snug/Core/Capture/**"
---

# Manual AR capture (ManualARCaptureMethod)

`ManualARCaptureMethod` is a stateless factory; all per-session AR
state lives in `ManualARCaptureController` (it owns the ARSession and
must be an NSObject delegate). When this section says "on
ManualARCaptureMethod" it means the manual-AR capture feature as a
whole, implemented in that controller. Per the architecture rules,
NONE of this state leaks into `RoomModel` except
`resolvedCeilingHeight`, written once at scan close. `RoomModel`
stores a single ceiling-height value and does not know how it was
derived. `FitService` is unchanged.

## Floor baseline — weighted average
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

## High-wall projection (replaces two-tap intersection)
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

## Openings — snap to captured walls
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

## Ceiling height — one-time look-up + edit, never typed
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

## Conditional drag-to-correct canvas
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
