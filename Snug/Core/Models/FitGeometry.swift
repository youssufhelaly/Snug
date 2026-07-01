import Foundation
import simd

/// Pure 2D floor-plane geometry for the fit system.
///
/// Everything here is deliberately free of RoomPlan, RealityKit, and UIKit so
/// `FitService` stays a pure, deterministic, unit-testable core (CLAUDE.md:
/// "FitService is pure … No UI code inside it"). The Phase 1 RoomModel and the
/// catalog placement layer convert *into* these types; nothing here knows
/// where the numbers came from.
///
/// Convention: all points live on the floor plane. A `SIMD2<Float>`'s `x` is
/// world X and its `y` is world **Z** (the floor's second horizontal axis).
/// Units are meters, matching RoomPlan.

/// An axis-aligned-in-local-space rectangle placed and rotated on the floor —
/// the footprint of a furniture item or a kept object, viewed from above.
struct OrientedFootprint: Equatable {
    /// Center on the floor plane (x = world X, y = world Z).
    var center: SIMD2<Float>
    /// Local extents: `x` is width along the item's own X, `y` is depth along
    /// its own Z. Always the full size, not half-extents.
    var size: SIMD2<Float>
    /// Yaw about the vertical axis, in radians. 0 means the item's local axes
    /// align with world X/Z.
    var rotation: Float

    init(center: SIMD2<Float>, size: SIMD2<Float>, rotation: Float = 0) {
        self.center = center
        self.size = size
        self.rotation = rotation
    }

    /// The four corners in world space, from the local (-x,-z) corner.
    ///
    /// `rotation` is a yaw about +Y, matching RealityKit's
    /// `simd_quatf(angle: yRotation, axis: [0,1,0])` — the convention the diorama
    /// renders with (`FurnitureEntityBuilder`) and `WallSnapService` snaps to. A
    /// +Y yaw maps the local depth axis (+Z, our `size.y`) to `(sin θ, cos θ)` in
    /// world (x, z) and the width axis (+X, `size.x`) to `(cos θ, -sin θ)`. Getting
    /// this sign wrong mirrors the fit footprint relative to the on-screen box, so
    /// a piece that *looks* flush/inside reads as askew and poking through a wall —
    /// a divergence that only appears at non-90° yaws, i.e. against tilted walls.
    var corners: [SIMD2<Float>] {
        let half = size / 2
        let c = cos(rotation)
        let s = sin(rotation)
        let local: [SIMD2<Float>] = [
            SIMD2(-half.x, -half.y),
            SIMD2(half.x, -half.y),
            SIMD2(half.x, half.y),
            SIMD2(-half.x, half.y),
        ]
        return local.map { p in
            SIMD2(center.x + p.x * c + p.y * s,
                  center.y - p.x * s + p.y * c)
        }
    }

    /// The two edge normals (separating-axis candidates for SAT) — the rotated
    /// width and depth axes under the same +Y convention as `corners`. The
    /// rectangle's other two edges are parallel, so two axes suffice.
    var separatingAxes: [SIMD2<Float>] {
        let c = cos(rotation)
        let s = sin(rotation)
        return [SIMD2(c, -s), SIMD2(s, c)]
    }
}

/// The room's floor outline as an ordered polygon. A rectangle is four
/// corners; L-shaped and other non-convex rooms are supported as longer
/// polygons (see `FitService` for the accuracy caveats on non-convex shapes).
struct RoomFootprint: Equatable {
    /// Ordered polygon corners (winding may be CW or CCW; the math doesn't
    /// rely on a particular winding).
    var corners: [SIMD2<Float>]

    init(corners: [SIMD2<Float>]) {
        self.corners = corners
    }

    /// Convenience for the common rectangular room, centered at `center`.
    static func rectangle(
        width: Float,
        depth: Float,
        center: SIMD2<Float> = .zero
    ) -> RoomFootprint {
        let hx = width / 2
        let hz = depth / 2
        return RoomFootprint(corners: [
            SIMD2(center.x - hx, center.y - hz),
            SIMD2(center.x + hx, center.y - hz),
            SIMD2(center.x + hx, center.y + hz),
            SIMD2(center.x - hx, center.y + hz),
        ])
    }

    /// The polygon edges as (start, end) segment pairs, wrapping the last
    /// corner back to the first.
    var edges: [(start: SIMD2<Float>, end: SIMD2<Float>)] {
        guard corners.count >= 2 else { return [] }
        return corners.indices.map { i in
            (corners[i], corners[(i + 1) % corners.count])
        }
    }
}

/// Occupied floor space the item must avoid: a kept object's footprint, or a
/// keep-clear zone in front of a doorway. The `kind` lets the result explain
/// *why* something doesn't fit; `id` lets callers map a result back to the
/// thing that blocked it.
struct FitObstacle: Identifiable, Equatable {
    enum Kind: Equatable {
        /// A piece of furniture the user chose to keep.
        case keptObject
        /// Floor that must stay walkable (a doorway / passage swing zone).
        case doorway
    }

    /// How well we trust this obstacle's geometry. Kept-furniture footprints
    /// sized from category priors (Phase 2's `.estimated` / `.manual` detections)
    /// are far less certain than measured walls, so the fit math widens its
    /// uncertainty band for them (`marginMultiplier`). This lives in the fit
    /// layer — not as a furniture type — so `FitService` stays free of Vision /
    /// furniture imports; the de-clutter bridge maps detection confidence onto it.
    enum Confidence: Equatable {
        /// Real measured geometry (or a high-confidence detection). Standard band.
        case measured
        /// Estimated from priors or manually placed — widen the band 1.5×.
        case estimated

        /// Factor applied to the global error margin for this obstacle.
        var marginMultiplier: Float {
            switch self {
            case .measured:  return 1.0
            case .estimated: return 1.5
            }
        }
    }

    let id: UUID
    var footprint: OrientedFootprint
    var kind: Kind
    var confidence: Confidence

    init(id: UUID = UUID(), footprint: OrientedFootprint, kind: Kind, confidence: Confidence = .measured) {
        self.id = id
        self.footprint = footprint
        self.kind = kind
        self.confidence = confidence
    }
}

/// The full geometric input to a fit check: the room outline plus everything
/// already occupying the floor.
struct FitGeometry: Equatable {
    var room: RoomFootprint
    var obstacles: [FitObstacle]

    init(room: RoomFootprint, obstacles: [FitObstacle] = []) {
        self.room = room
        self.obstacles = obstacles
    }
}

/// Small, dependency-free 2D primitives used by `FitService`. Kept internal
/// and side-effect-free so the fit math reads as straight-line geometry.
enum Geometry2D {
    /// Shortest distance from a point to a finite segment.
    static func distance(from point: SIMD2<Float>, toSegment a: SIMD2<Float>, _ b: SIMD2<Float>) -> Float {
        let ab = b - a
        let lengthSquared = simd_length_squared(ab)
        guard lengthSquared > 0 else { return simd_distance(point, a) }
        // Project point onto the line, clamped to the segment.
        let t = max(0, min(1, simd_dot(point - a, ab) / lengthSquared))
        let projection = a + t * ab
        return simd_distance(point, projection)
    }

    /// Even-odd ray cast: is `point` inside the (possibly non-convex) polygon?
    /// Points exactly on an edge are treated as inside by the boundary-distance
    /// logic in FitService, so the strictness here doesn't affect the result.
    static func isPoint(_ point: SIMD2<Float>, insidePolygon polygon: [SIMD2<Float>]) -> Bool {
        guard polygon.count >= 3 else { return false }
        var inside = false
        var j = polygon.count - 1
        for i in polygon.indices {
            let a = polygon[i]
            let b = polygon[j]
            let intersects = (a.y > point.y) != (b.y > point.y)
                && point.x < (b.x - a.x) * (point.y - a.y) / (b.y - a.y) + a.x
            if intersects { inside.toggle() }
            j = i
        }
        return inside
    }

    /// Projection interval [min, max] of `points` onto a (not necessarily
    /// unit) `axis`.
    static func projectionInterval(of points: [SIMD2<Float>], onto axis: SIMD2<Float>) -> (min: Float, max: Float) {
        var lo = Float.greatestFiniteMagnitude
        var hi = -Float.greatestFiniteMagnitude
        for p in points {
            let d = simd_dot(p, axis)
            lo = min(lo, d)
            hi = max(hi, d)
        }
        return (lo, hi)
    }

    /// Shoelace area (absolute value, winding-agnostic) of a floor polygon.
    /// The single source of truth for floor area — `RoomModel.floorArea`, the
    /// capture controller's close check, and `GeometryValidator` all call here.
    static func polygonArea(_ polygon: [SIMD2<Float>]) -> Float {
        guard polygon.count >= 3 else { return 0 }
        var sum: Float = 0
        for i in polygon.indices {
            let a = polygon[i]
            let b = polygon[(i + 1) % polygon.count]
            sum += a.x * b.y - b.x * a.y
        }
        return abs(sum) / 2
    }

    /// Whether any pair of non-adjacent edges of the closed polygon cross — the
    /// self-intersection ("bow-tie") test the drag-to-correct canvas gates on.
    static func hasSelfIntersection(_ polygon: [SIMD2<Float>]) -> Bool {
        let n = polygon.count
        guard n >= 4 else { return false }
        for i in 0..<n {
            let a = polygon[i]
            let b = polygon[(i + 1) % n]
            for j in (i + 1)..<n {
                // Skip adjacent segments (they legitimately share a vertex),
                // including the wrap-around pair (last segment ↔ first segment).
                if (j + 1) % n == i || (i + 1) % n == j { continue }
                let c = polygon[j]
                let d = polygon[(j + 1) % n]
                if segmentsIntersect(a, b, c, d) { return true }
            }
        }
        return false
    }

    // MARK: - Segment intersection (orientation method)

    private static func segmentsIntersect(_ p1: SIMD2<Float>, _ p2: SIMD2<Float>,
                                          _ p3: SIMD2<Float>, _ p4: SIMD2<Float>) -> Bool {
        let d1 = orientation(p3, p4, p1)
        let d2 = orientation(p3, p4, p2)
        let d3 = orientation(p1, p2, p3)
        let d4 = orientation(p1, p2, p4)

        if ((d1 > 0 && d2 < 0) || (d1 < 0 && d2 > 0)) &&
           ((d3 > 0 && d4 < 0) || (d3 < 0 && d4 > 0)) {
            return true
        }

        // Collinear overlap cases.
        if d1 == 0 && onSegment(p3, p4, p1) { return true }
        if d2 == 0 && onSegment(p3, p4, p2) { return true }
        if d3 == 0 && onSegment(p1, p2, p3) { return true }
        if d4 == 0 && onSegment(p1, p2, p4) { return true }
        return false
    }

    /// Signed area sign of triangle (a, b, c): >0 CCW, <0 CW, 0 collinear.
    private static func orientation(_ a: SIMD2<Float>, _ b: SIMD2<Float>, _ c: SIMD2<Float>) -> Float {
        (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
    }

    /// Whether point `p` lies within the bounding box of segment a–b (used only
    /// when the three points are already known collinear).
    private static func onSegment(_ a: SIMD2<Float>, _ b: SIMD2<Float>, _ p: SIMD2<Float>) -> Bool {
        min(a.x, b.x) <= p.x && p.x <= max(a.x, b.x) &&
        min(a.y, b.y) <= p.y && p.y <= max(a.y, b.y)
    }
}
