import Foundation
import simd

/// Turns a confirmed `FurnitureObservation` into a floor-placed
/// `FurnitureFootprint` in `RoomModel` coordinates.
///
/// ## Why this layer is pure
/// Like `FitService`, this is deterministic and free of ARKit / Vision imports
/// so it can be unit-tested against plain numbers. The AR controller does the
/// one impure thing — raycasting the bounding box's bottom-center screen point
/// against `ARFrame` planes — and hands the *resolved* world hit (plus the
/// floor baseline and room polygon) to `place(...)`. Everything spatial here is
/// arithmetic on those inputs.
///
/// ## Coordinate convention
/// All positions are `RoomModel` world coordinates, Y-up. `dimensions` packs
/// `(width, depth, height)` as `(x, y, z)` — see `FurnitureModels`. The floor
/// plane is the XZ plane; `sessionFloorY` (from `ManualARCaptureController`) is
/// the altitude every footprint is snapped to.
struct FurniturePlacementService {

    /// Multiplier widening the raw pixel-width back-projection into a real-world
    /// width, tuned for the typical furniture-occupies-most-of-its-box case.
    static let widthScale: Float = 1.2
    /// How far a back-projected width may stray from the category prior before
    /// we distrust it and fall back to the prior (±40%).
    static let widthClampFraction: Float = 0.40

    /// Resolved inputs for placing one detection. The AR layer fills `raycast*`
    /// and the camera fallback fields from the live `ARFrame`; tests pass them
    /// directly.
    struct Input {
        let observation: FurnitureObservation
        let appearance: FurnitureAppearance
        /// World XZ where the bounding box's bottom-center raycast landed, or
        /// nil if no plane was hit.
        let raycastHitXZ: SIMD2<Float>?
        /// Camera→hit distance in meters, used to back-project pixel width. Nil
        /// when there was no raycast hit.
        let raycastDistance: Float?
        /// Floor baseline (weighted `sessionFloorY`) every footprint snaps to.
        let sessionFloorY: Float
        /// The room's floor polygon (`RoomModel.floorCorners` as XZ vectors).
        let roomCorners: [SIMD2<Float>]
        /// Camera position/forward on the floor plane — used to project a
        /// position when the raycast missed. The fallback is marked `.estimated`.
        let cameraPositionXZ: SIMD2<Float>?
        let cameraForwardXZ: SIMD2<Float>?
    }

    func place(_ input: Input) -> FurnitureFootprint {
        // 1–4. Resolve floor XZ. Prefer the raycast; otherwise project forward
        //       from the camera (or fall back to the room centroid) and mark estimated.
        var usedFallbackPosition = false
        let rawXZ: SIMD2<Float>
        if let hit = input.raycastHitXZ {
            rawXZ = hit
        } else {
            usedFallbackPosition = true
            rawXZ = Self.forwardProjectedXZ(
                cameraPositionXZ: input.cameraPositionXZ,
                cameraForwardXZ: input.cameraForwardXZ,
                category: input.observation.category
            ) ?? Self.centroid(of: input.roomCorners)
        }

        // Dimensions: width is back-projected and clamped; depth/height are priors.
        let (dimensions, widthFellBack) = Self.estimatedDimensions(
            category: input.observation.category,
            boundingBoxWidth: Float(input.observation.boundingBox.width),
            raycastDistance: input.raycastDistance
        )

        // 6. Keep the WHOLE footprint inside the room polygon (all four corners,
        //    8 cm clear of every wall) — not just its center. Computed after the
        //    dimensions so the box's real footprint drives the clamp.
        let clampedXZ = FurniturePlacementService.clampToBoundary(
            position: rawXZ,
            dimensions: SIMD2(dimensions.x, dimensions.y),
            rotation: 0,
            room: RoomFootprint(corners: input.roomCorners)
        )

        // Confidence: a real raycast hit AND a trusted back-projected width earns
        // `.detected`; anything we had to fall back on stays `.estimated` so
        // FitService widens its band (CLAUDE.md: honest about confidence).
        let confidence: FurnitureFootprint.DetectionConfidence =
            (usedFallbackPosition || widthFellBack) ? .estimated : .detected

        return FurnitureFootprint(
            id: input.observation.id,
            category: input.observation.category,
            // Y is FLOOR-RELATIVE: `RoomModel`'s floor is the y=0 plane (the
            // diorama and FitService both treat it as the reference; RoomModel
            // stores no absolute altitude). The box's base sits on that floor, so
            // its center is half its height up. We deliberately do NOT bake in the
            // AR session's `sessionFloorY` (an arbitrary world altitude, usually
            // ~-1.2 m) — doing so sank furniture below the diorama floor. The raw
            // raycast Y is likewise ignored (drifts on non-LiDAR devices); only
            // its XZ is trusted.
            worldPosition: SIMD3(clampedXZ.x, dimensions.z / 2, clampedXZ.y),
            dimensions: dimensions,
            yRotation: 0,
            appearance: input.appearance,
            detectionConfidence: confidence
        )
    }

    // MARK: - Pure helpers (unit-tested directly)

    /// Estimated `(width, depth, height)` for a category. Width is the
    /// back-projected pixel width clamped to ±`widthClampFraction` of the prior;
    /// outside that band (or with no distance to back-project from) we distrust
    /// it and fall back to the prior, reporting `fellBackToPrior == true`. Depth
    /// and height always use priors — a single bounding box can't measure them.
    static func estimatedDimensions(
        category: FurnitureCategory,
        boundingBoxWidth: Float,
        raycastDistance: Float?
    ) -> (dimensions: SIMD3<Float>, fellBackToPrior: Bool) {
        let prior = category.defaultDimensions
        guard let distance = raycastDistance, distance > 0, boundingBoxWidth > 0 else {
            return (prior, true)
        }
        let projected = boundingBoxWidth * distance * widthScale
        let lower = prior.x * (1 - widthClampFraction)
        let upper = prior.x * (1 + widthClampFraction)
        guard projected >= lower && projected <= upper else {
            return (prior, true)
        }
        return (SIMD3(projected, prior.y, prior.z), false)
    }

    /// Clamp a floor point to the room polygon: returned unchanged if already
    /// inside, otherwise projected to the nearest point on the polygon boundary
    /// and nudged a hair toward the centroid so it lands strictly interior.
    static func clamped(_ point: SIMD2<Float>, toRoom corners: [SIMD2<Float>]) -> SIMD2<Float> {
        guard corners.count >= 3 else { return point }
        if Geometry2D.isPoint(point, insidePolygon: corners) { return point }

        var nearest = point
        var best = Float.greatestFiniteMagnitude
        for i in corners.indices {
            let a = corners[i]
            let b = corners[(i + 1) % corners.count]
            let p = nearestPointOnSegment(point, a, b)
            let d = simd_distance(point, p)
            if d < best { best = d; nearest = p }
        }
        // Nudge toward the centroid so the point is inside, not exactly on the
        // wall (a footprint sitting on the wall would read as zero clearance).
        let centroid = corners.reduce(SIMD2<Float>.zero, +) / Float(corners.count)
        let toCentroid = centroid - nearest
        let length = simd_length(toCentroid)
        guard length > 1e-5 else { return nearest }
        return nearest + (toCentroid / length) * 0.01
    }

    /// Project a position forward from the camera when the raycast missed. Falls
    /// back to the room centroid if no camera pose is available, so a missed
    /// raycast still yields a plausible in-room position rather than the origin.
    private static func forwardProjectedXZ(
        cameraPositionXZ: SIMD2<Float>?,
        cameraForwardXZ: SIMD2<Float>?,
        category: FurnitureCategory
    ) -> SIMD2<Float>? {
        guard let origin = cameraPositionXZ, let forward = cameraForwardXZ else {
            return nil   // no camera pose — caller falls back to the room centroid
        }
        let length = simd_length(forward)
        let direction = length > 1e-5 ? forward / length : SIMD2(0, 1)
        // Push out by a category-scaled distance: bigger pieces tend to sit
        // farther from where you stand to photograph them.
        let reach = max(1.0 as Float, category.defaultDimensions.x)
        return origin + direction * reach
    }

    static func centroid(of corners: [SIMD2<Float>]) -> SIMD2<Float> {
        guard !corners.isEmpty else { return .zero }
        return corners.reduce(SIMD2<Float>.zero, +) / Float(corners.count)
    }

    // MARK: - Boundary clamp

    /// Clamp `position` so all four footprint corners are at least `margin` meters
    /// inside the room polygon. Iterative: each pass finds the corner most in
    /// violation (outside, or closer than `margin` to its nearest wall) and pushes
    /// the whole center inward along that wall's inward normal by the shortfall.
    /// Converges for normal rooms; capped at 10 iterations so a degenerate room (or
    /// a box bigger than the room) can't loop forever — it returns the best effort.
    ///
    /// Uses only `OrientedFootprint.corners` and `Geometry2D` from `FitGeometry`
    /// (no new spatial math). `margin` (8 cm) is intentionally tighter than
    /// `FitService`'s error margin: enough to keep furniture off the walls without
    /// fighting the user's deliberate placements.
    static func clampToBoundary(
        position: SIMD2<Float>,
        dimensions: SIMD2<Float>,   // x = width, y = depth
        rotation: Float,
        room: RoomFootprint,
        margin: Float = 0.08
    ) -> SIMD2<Float> {
        guard room.corners.count >= 3 else { return position }
        let roomCentroid = Self.centroid(of: room.corners)
        var center = position

        for _ in 0..<10 {
            let corners = OrientedFootprint(center: center, size: dimensions, rotation: rotation).corners
            var worstShortfall: Float = 0
            var pushDirection = SIMD2<Float>(0, 0)

            for corner in corners {
                // Nearest wall edge and the distance to it.
                var nearestEdge: (start: SIMD2<Float>, end: SIMD2<Float>)?
                var bestDistance = Float.greatestFiniteMagnitude
                for edge in room.edges {
                    let d = Geometry2D.distance(from: corner, toSegment: edge.start, edge.end)
                    if d < bestDistance { bestDistance = d; nearestEdge = edge }
                }
                guard let edge = nearestEdge else { continue }

                // Signed depth: positive when the corner is inside the room.
                let inside = Geometry2D.isPoint(corner, insidePolygon: room.corners)
                let signedDepth = inside ? bestDistance : -bestDistance
                let shortfall = margin - signedDepth   // > 0 ⇒ must move inward
                guard shortfall > worstShortfall else { continue }

                // Inward normal of the offending edge (toward the room centroid).
                let edgeDir = edge.end - edge.start
                var normal = SIMD2<Float>(-edgeDir.y, edgeDir.x)
                let edgeMid = (edge.start + edge.end) / 2
                if simd_dot(normal, roomCentroid - edgeMid) < 0 { normal = -normal }
                let length = simd_length(normal)
                guard length > 1e-5 else { continue }

                worstShortfall = shortfall
                pushDirection = normal / length
            }

            if worstShortfall <= 0 { break }   // all corners satisfied
            center += pushDirection * worstShortfall
        }
        return center
    }

    private static func nearestPointOnSegment(
        _ p: SIMD2<Float>, _ a: SIMD2<Float>, _ b: SIMD2<Float>
    ) -> SIMD2<Float> {
        let ab = b - a
        let lengthSquared = simd_length_squared(ab)
        guard lengthSquared > 0 else { return a }
        let t = max(0, min(1, simd_dot(p - a, ab) / lengthSquared))
        return a + t * ab
    }
}
