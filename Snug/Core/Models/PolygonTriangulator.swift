import Foundation
import simd

/// Triangulates a simple (non-self-intersecting) floor polygon into a triangle
/// index list, so the diorama can build a floor mesh for any room shape — not
/// just rectangles. Rectangles, L-shapes, and other non-convex outlines all
/// work; holes are not supported (rooms don't have them).
///
/// Pure `simd`/`Foundation` (no RealityKit) so it's unit-testable and can be
/// verified off-device. Convention matches the rest of the fit geometry: a
/// `SIMD2<Float>`'s `x` is world X and `y` is world Z.
enum PolygonTriangulator {

    /// Ear-clipping triangulation.
    ///
    /// - Parameter polygon: ordered floor corners (CW or CCW; winding-agnostic).
    /// - Returns: flat triangle indices into `polygon` (`[a,b,c, a,b,c, …]`),
    ///   each triangle wound counter-clockwise in the XZ plane. Empty if the
    ///   polygon has fewer than 3 corners or is degenerate.
    static func triangulate(_ polygon: [SIMD2<Float>]) -> [UInt32] {
        guard polygon.count >= 3 else { return [] }
        guard polygon.count > 3 else { return [0, 1, 2] }

        // Work on a CCW copy so "convex vertex" and "ear" tests share one sign
        // convention; remember the mapping back to the caller's indices.
        let ccw = signedArea(polygon) >= 0
        let order: [Int] = ccw
            ? Array(polygon.indices)
            : Array(polygon.indices.reversed())

        var remaining = order
        var triangles: [UInt32] = []
        // Guard against an infinite loop on malformed input: at most one ear
        // per vertex per full pass, n-2 ears total.
        var safety = remaining.count * remaining.count

        while remaining.count > 3 && safety > 0 {
            safety -= 1
            var clipped = false

            for i in remaining.indices {
                let prev = remaining[(i + remaining.count - 1) % remaining.count]
                let curr = remaining[i]
                let next = remaining[(i + 1) % remaining.count]

                let a = polygon[prev], b = polygon[curr], c = polygon[next]

                // Reflex vertices can't be ears.
                guard cross(b - a, c - b) > 0 else { continue }

                // No other remaining vertex may fall inside triangle a-b-c.
                let containsOther = remaining.contains { idx in
                    idx != prev && idx != curr && idx != next
                        && pointInTriangle(polygon[idx], a, b, c)
                }
                if containsOther { continue }

                triangles.append(contentsOf: [UInt32(prev), UInt32(curr), UInt32(next)])
                remaining.remove(at: i)
                clipped = true
                break
            }

            // No ear found in a full pass → polygon is degenerate; bail with
            // what we have rather than spinning.
            if !clipped { break }
        }

        if remaining.count == 3 {
            triangles.append(contentsOf: remaining.map { UInt32($0) })
        }
        return triangles
    }

    // MARK: - Primitives

    /// Signed area (>0 when the polygon winds counter-clockwise in XZ).
    static func signedArea(_ polygon: [SIMD2<Float>]) -> Float {
        var sum: Float = 0
        for i in polygon.indices {
            let a = polygon[i]
            let b = polygon[(i + 1) % polygon.count]
            sum += a.x * b.y - b.x * a.y
        }
        return sum / 2
    }

    /// 2D cross product (z-component of the 3D cross of the lifted vectors).
    private static func cross(_ u: SIMD2<Float>, _ v: SIMD2<Float>) -> Float {
        u.x * v.y - u.y * v.x
    }

    /// Inclusive point-in-triangle via consistent edge signs.
    private static func pointInTriangle(
        _ p: SIMD2<Float>, _ a: SIMD2<Float>, _ b: SIMD2<Float>, _ c: SIMD2<Float>
    ) -> Bool {
        let d1 = cross(b - a, p - a)
        let d2 = cross(c - b, p - b)
        let d3 = cross(a - c, p - c)
        let hasNeg = d1 < 0 || d2 < 0 || d3 < 0
        let hasPos = d1 > 0 || d2 > 0 || d3 > 0
        // Inside (or on an edge) only if all edge signs agree.
        return !(hasNeg && hasPos)
    }
}
