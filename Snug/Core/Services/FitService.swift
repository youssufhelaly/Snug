import Foundation
import simd

/// The trust layer. Computes how a candidate piece of furniture fits against
/// real scanned floor geometry and reports one of four uncertainty-honest
/// states (CLAUDE.md: highest-stakes code in the app).
///
/// `FitService` is pure, deterministic, and free of UI / RealityKit / RoomPlan
/// imports — it consumes only the 2D `FitGeometry` primitives and produces a
/// `FitResult`. All clearances are signed meters on the floor plane: positive
/// means a gap, negative means overlap or sticking out past a wall.
struct FitService {

    init() {}

    /// Evaluate a candidate item against the room and its obstacles.
    ///
    /// - Parameters:
    ///   - item: the item's floor footprint (center, size, rotation).
    ///   - geometry: the room outline plus occupied floor (kept objects, etc.).
    ///   - errorMargin: the uncertainty band in meters. Defaults to the global
    ///     Phase-0-seeded value; pass an explicit value in tests.
    /// - Returns: the fit state plus the clearances that produced it.
    func evaluate(
        item: OrientedFootprint,
        in geometry: FitGeometry,
        errorMargin: Float = FitConfiguration.errorMargin
    ) -> FitResult {
        // A room needs at least a triangle to contain anything.
        guard geometry.room.corners.count >= 3 else {
            return FitResult(
                state: .wontFit,
                clearance: -.greatestFiniteMagnitude,
                wallClearance: -.greatestFiniteMagnitude,
                obstacleClearance: nil,
                limit: .none
            )
        }

        // Containment: smallest signed clearance to any wall. Walls are measured
        // geometry, so they always use the base error margin (multiplier 1).
        let wall = roomClearance(item: item, room: geometry.room)

        // Obstacles: track the smallest *raw* clearance (for honest reporting)
        // and, separately, the binding constraint chosen by margin-NORMALIZED
        // clearance. An obstacle with `.estimated` confidence widens its
        // uncertainty band 1.5×; dividing its clearance by that multiplier and
        // classifying against the base margin is exactly equivalent to widening
        // the band, because every four-state threshold scales linearly with the
        // margin. So a less-trusted obstacle binds the result sooner — pushing
        // toward "too close to call" where a measured one would still "fit" —
        // without ever blocking placement (CLAUDE.md: honesty, not a hard no).
        var obstacleClearance: Float?
        var bindingNormalized = wall.clearance      // wall multiplier == 1
        var clearance = wall.clearance              // raw clearance of the binding constraint
        var limit: FitResult.Limit = .wall(index: wall.wallIndex)
        for obstacle in geometry.obstacles {
            let raw = rectangleClearance(item, obstacle.footprint)
            if obstacleClearance == nil || raw < obstacleClearance! {
                obstacleClearance = raw
            }
            let normalized = raw / obstacle.confidence.marginMultiplier
            if normalized < bindingNormalized {
                bindingNormalized = normalized
                clearance = raw
                limit = .obstacle(id: obstacle.id, kind: obstacle.kind)
            }
        }

        return FitResult(
            state: Self.classify(clearance: bindingNormalized, errorMargin: errorMargin),
            clearance: clearance,
            wallClearance: wall.clearance,
            obstacleClearance: obstacleClearance,
            limit: limit
        )
    }

    // MARK: - State classification

    /// The single place the four-state boundary lives. Continuous in
    /// `clearance`, conservative on every boundary (e.g. exactly `errorMargin`
    /// of clearance is still "too close to call", never "fits").
    static func classify(clearance: Float, errorMargin: Float) -> FitResult.State {
        if clearance > errorMargin * 2 {
            return .fitsWithRoom
        } else if clearance > errorMargin {
            return .fits
        } else if clearance >= -errorMargin {
            return .tooCloseToCall
        } else {
            return .wontFit
        }
    }

    // MARK: - Containment

    /// Signed clearance from the item to the room walls, and the index of the
    /// limiting wall.
    ///
    /// Clearance is the true Euclidean distance from the item footprint to the
    /// nearest wall *segment* — positive when the item is fully inside the room,
    /// negative when it pokes out. Measuring to segments (not infinite wall
    /// lines) is what makes this correct for NON-CONVEX and rotated rooms: a
    /// reflex corner's wall line would otherwise cut across the interior and
    /// floor the clearance at a phantom value when the item is nowhere near that
    /// wall. The item box is convex, so the closest boundary feature is either
    /// an item corner against a wall segment or a wall corner against an item
    /// edge — we take the minimum of both.
    private func roomClearance(
        item: OrientedFootprint,
        room: RoomFootprint
    ) -> (clearance: Float, wallIndex: Int) {
        let box = item.corners
        let poly = room.corners
        guard poly.count >= 3, box.count == 4 else {
            return (-.greatestFiniteMagnitude, 0)
        }

        // Inside ⇔ every item corner is within the floor polygon AND no wall
        // corner has poked inside the item (which would mean a wall slices
        // through it). Works for any simple polygon, convex or not.
        let allCornersInside = box.allSatisfy { Geometry2D.isPoint($0, insidePolygon: poly) }
        let wallCornerInsideBox = poly.contains { Geometry2D.isPoint($0, insidePolygon: box) }
        let inside = allCornersInside && !wallCornerInsideBox

        var minDistance = Float.greatestFiniteMagnitude
        var wallIndex = 0

        // Item corners → wall segments.
        for (index, edge) in room.edges.enumerated() {
            for corner in box {
                let d = Geometry2D.distance(from: corner, toSegment: edge.start, edge.end)
                if d < minDistance { minDistance = d; wallIndex = index }
            }
        }
        // Wall corners → item edges (captures a wall corner jutting toward a
        // flat item face). Attribute it to the wall starting at that corner.
        for j in poly.indices {
            for k in box.indices {
                let d = Geometry2D.distance(from: poly[j], toSegment: box[k], box[(k + 1) % box.count])
                if d < minDistance { minDistance = d; wallIndex = j }
            }
        }

        return (inside ? minDistance : -minDistance, wallIndex)
    }

    // MARK: - Obstacle clearance

    /// Signed clearance between two oriented rectangles: positive is the true
    /// gap, negative is the penetration depth when they overlap.
    private func rectangleClearance(_ a: OrientedFootprint, _ b: OrientedFootprint) -> Float {
        let cornersA = a.corners
        let cornersB = b.corners
        // Face normals of both boxes are the complete separating-axis set for
        // two convex rectangles (SAT).
        let axes = a.separatingAxes + b.separatingAxes

        var separated = false
        var minOverlap = Float.greatestFiniteMagnitude
        for axis in axes {
            let pa = Geometry2D.projectionInterval(of: cornersA, onto: axis)
            let pb = Geometry2D.projectionInterval(of: cornersB, onto: axis)
            // Positive on an axis means a gap on that axis -> separated.
            let gap = max(pa.min - pb.max, pb.min - pa.max)
            if gap > 0 { separated = true }
            let overlap = min(pa.max, pb.max) - max(pa.min, pb.min)
            minOverlap = min(minOverlap, overlap)
        }

        if separated {
            // True minimum distance between two convex polygons. Face-normal
            // axes alone overestimate the gap in corner-to-corner cases, so we
            // measure vertex-to-edge distances directly.
            return polygonDistance(cornersA, cornersB)
        } else {
            // Overlapping: the smallest overlap across axes is the penetration
            // depth. Report it as negative clearance.
            return -minOverlap
        }
    }

    /// Minimum distance between two convex polygons known to be disjoint.
    private func polygonDistance(_ a: [SIMD2<Float>], _ b: [SIMD2<Float>]) -> Float {
        var distance = Float.greatestFiniteMagnitude
        for p in a {
            for i in b.indices {
                distance = min(distance, Geometry2D.distance(from: p, toSegment: b[i], b[(i + 1) % b.count]))
            }
        }
        for p in b {
            for i in a.indices {
                distance = min(distance, Geometry2D.distance(from: p, toSegment: a[i], a[(i + 1) % a.count]))
            }
        }
        return distance
    }
}

/// The outcome of a fit check: the four-state badge plus the clearances behind
/// it. UI copy lives in the view layer; this stays pure.
struct FitResult: Equatable {
    /// The four uncertainty-honest states (CLAUDE.md fit system).
    enum State: Equatable {
        /// Clearance greater than 2× the error margin.
        case fitsWithRoom
        /// Clearance greater than the error margin.
        case fits
        /// Clearance within ± the error margin. Tell the user to measure.
        case tooCloseToCall
        /// Negative clearance beyond the error margin.
        case wontFit
    }

    /// What bound the result — the wall or obstacle with the least clearance.
    /// Drives the "measure THIS wall" guidance.
    enum Limit: Equatable {
        case wall(index: Int)
        case obstacle(id: UUID, kind: FitObstacle.Kind)
        case none
    }

    /// The binding (smallest) signed clearance in meters.
    let state: State
    let clearance: Float
    /// Smallest signed clearance to any wall.
    let wallClearance: Float
    /// Smallest signed clearance to any obstacle, or nil if there are none.
    let obstacleClearance: Float?
    /// Which wall or obstacle produced `clearance`.
    let limit: Limit
}
