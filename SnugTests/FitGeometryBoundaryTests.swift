import Testing
import simd
@testable import Snug

/// Boundary-containment regression tests for `Geometry2D`. A point (or a
/// footprint corner) lying exactly on a wall must count as INSIDE, so a piece
/// pushed flush against a wall isn't misclassified as out-of-bounds by
/// `FitService` / `FurniturePlacementValidator`. Guards the flush-corner fix
/// from PR #13 review, where the raw even-odd ray cast left boundary points
/// undefined.
struct FitGeometryBoundaryTests {

    /// A 4×4 m square room (CCW), matching how floor polygons reach `Geometry2D`.
    private let room: [SIMD2<Float>] = [
        SIMD2(0, 0), SIMD2(4, 0), SIMD2(4, 4), SIMD2(0, 4),
    ]

    @Test func pointOnEdgeCountsAsInside() {
        #expect(Geometry2D.isPoint(SIMD2(2, 0), insidePolygon: room))   // mid bottom wall
        #expect(Geometry2D.isPoint(SIMD2(0, 2), insidePolygon: room))   // mid left wall
        #expect(Geometry2D.isPoint(SIMD2(0, 0), insidePolygon: room))   // a vertex
    }

    @Test func flushFootprintReadsAsContained() {
        // A 2×1 box shoved against the bottom wall: its two bottom corners sit
        // exactly on y = 0. Before the fix this failed the corner-containment
        // guard and the piece read as "not fitting."
        let box: [SIMD2<Float>] = [
            SIMD2(1, 0), SIMD2(3, 0), SIMD2(3, 1), SIMD2(1, 1),
        ]
        #expect(Geometry2D.isConvexFootprint(box, insidePolygon: room))
    }

    @Test func cornerInCornerReadsAsContained() {
        // Flush into a room corner: two corners on two walls at once.
        let box: [SIMD2<Float>] = [
            SIMD2(0, 0), SIMD2(1, 0), SIMD2(1, 1), SIMD2(0, 1),
        ]
        #expect(Geometry2D.isConvexFootprint(box, insidePolygon: room))
    }

    @Test func genuinelyOutsidePointsStayOutside() {
        #expect(!Geometry2D.isPoint(SIMD2(5, 2), insidePolygon: room))     // past right wall
        #expect(!Geometry2D.isPoint(SIMD2(-0.1, 2), insidePolygon: room))  // left of room
        #expect(!Geometry2D.isPoint(SIMD2(2, 4.5), insidePolygon: room))   // above room
    }

    @Test func footprintPokingThroughWallIsRejected() {
        // Bottom edge below y = 0 — genuinely outside, must stay rejected.
        let box: [SIMD2<Float>] = [
            SIMD2(1, -0.5), SIMD2(3, -0.5), SIMD2(3, 0.5), SIMD2(1, 0.5),
        ]
        #expect(!Geometry2D.isConvexFootprint(box, insidePolygon: room))
    }

    @Test func strictInteriorExcludesTheBoundary() {
        // The two variants must disagree exactly on the boundary: `isPoint`
        // counts an on-edge point as inside, the strict variant does not. This
        // is what keeps a flush corner contained while still catching a wall
        // vertex that genuinely pokes through a piece.
        #expect(Geometry2D.isPoint(SIMD2(2, 0), insidePolygon: room))
        #expect(!Geometry2D.isPointStrictlyInside(SIMD2(2, 0), insidePolygon: room))
        // A true interior point is inside under both.
        #expect(Geometry2D.isPoint(SIMD2(2, 2), insidePolygon: room))
        #expect(Geometry2D.isPointStrictlyInside(SIMD2(2, 2), insidePolygon: room))
    }
}
