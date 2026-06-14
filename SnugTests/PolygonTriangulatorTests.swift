import Testing
import simd
@testable import Snug

/// The floor triangulator feeds the diorama's floor mesh, so a wrong split
/// would show as a hole or a phantom triangle in the rendered room. These tests
/// assert the structural invariants that keep the mesh sound for any room shape.
struct PolygonTriangulatorTests {

    private func triangleArea(_ a: SIMD2<Float>, _ b: SIMD2<Float>, _ c: SIMD2<Float>) -> Float {
        abs((b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)) / 2
    }

    /// Sum of triangle areas must equal the polygon area (no gaps/overlaps), the
    /// triangle count must be n-2, and every index must be in range.
    private func assertTiles(_ polygon: [SIMD2<Float>], _ comment: Comment) {
        let indices = PolygonTriangulator.triangulate(polygon)
        #expect(indices.count == (polygon.count - 2) * 3, comment)
        #expect(indices.allSatisfy { $0 < UInt32(polygon.count) }, comment)

        var area: Float = 0
        for t in stride(from: 0, to: indices.count, by: 3) {
            area += triangleArea(
                polygon[Int(indices[t])],
                polygon[Int(indices[t + 1])],
                polygon[Int(indices[t + 2])]
            )
        }
        let expected = abs(PolygonTriangulator.signedArea(polygon))
        #expect(abs(area - expected) < 0.001, comment)
    }

    @Test func rectangleEitherWinding() {
        assertTiles([
            SIMD2(-1.8, -1.5), SIMD2(1.8, -1.5), SIMD2(1.8, 1.5), SIMD2(-1.8, 1.5),
        ], "rectangle CCW")
        assertTiles([
            SIMD2(-1.8, 1.5), SIMD2(1.8, 1.5), SIMD2(1.8, -1.5), SIMD2(-1.8, -1.5),
        ], "rectangle CW")
    }

    @Test func lShapedRoom() {
        assertTiles([
            SIMD2(0, 0), SIMD2(4, 0), SIMD2(4, 2), SIMD2(2, 2), SIMD2(2, 4), SIMD2(0, 4),
        ], "L-shape (non-convex)")
    }

    @Test func concavePolygon() {
        assertTiles([
            SIMD2(0, 0), SIMD2(4, 2), SIMD2(0, 4), SIMD2(1, 2),
        ], "concave arrowhead")
    }

    @Test func triangleIsOneTriangle() {
        let indices = PolygonTriangulator.triangulate([SIMD2(0, 0), SIMD2(3, 0), SIMD2(0, 2)])
        #expect(indices.count == 3)
    }

    @Test func degenerateInputReturnsEmpty() {
        #expect(PolygonTriangulator.triangulate([]).isEmpty)
        #expect(PolygonTriangulator.triangulate([SIMD2(0, 0), SIMD2(1, 1)]).isEmpty)
    }
}
