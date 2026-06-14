import Foundation
import simd

/// Validates a floor-corner polygon for the drag-to-correct canvas. Pure and
/// standalone (no UI, no AR) so it can be unit-tested in isolation against
/// fixtures. It runs reactively as corners are dragged and drives the commit
/// button's disabled state and the error-ribbon copy — it never runs on press.
///
/// Three rules, checked in order; the first failure wins:
/// 1. No self-intersection — non-adjacent wall segments may not cross.
/// 2. Minimum wall length — every segment must be longer than 0.3 m.
/// 3. Positive area — the shoelace area must exceed 1.0 m².
struct GeometryValidator {

    /// Walls shorter than this (m) are almost certainly a dragging mistake.
    static let minimumWallLength: Float = 0.3
    /// Below this absolute shoelace area (m²) the polygon isn't a real room.
    static let minimumArea: Float = 1.0

    enum Result: Equatable {
        case valid
        case invalid(String)

        var isValid: Bool {
            if case .valid = self { return true }
            return false
        }

        var errorMessage: String? {
            if case .invalid(let message) = self { return message }
            return nil
        }
    }

    func validate(_ corners: [PlanePoint]) -> Result {
        guard corners.count >= 3 else {
            return .invalid("Invalid room area — check corner positions.")
        }
        if hasSelfIntersection(corners) {
            return .invalid("Invalid room shape — wall paths can't cross.")
        }
        if hasShortWall(corners) {
            return .invalid("Walls must be at least 30cm long.")
        }
        if shoelaceArea(corners) <= Self.minimumArea {
            return .invalid("Invalid room area — check corner positions.")
        }
        return .valid
    }

    // MARK: - Rules

    /// Every closed-polygon segment against every non-adjacent segment.
    private func hasSelfIntersection(_ corners: [PlanePoint]) -> Bool {
        let n = corners.count
        for i in 0..<n {
            let a = corners[i].simd2
            let b = corners[(i + 1) % n].simd2
            for j in (i + 1)..<n {
                // Skip adjacent segments (they legitimately share a vertex),
                // including the wrap-around pair (last segment ↔ first segment).
                if j == i { continue }
                if (j + 1) % n == i || (i + 1) % n == j { continue }
                let c = corners[j].simd2
                let d = corners[(j + 1) % n].simd2
                if segmentsIntersect(a, b, c, d) { return true }
            }
        }
        return false
    }

    private func hasShortWall(_ corners: [PlanePoint]) -> Bool {
        let n = corners.count
        for i in 0..<n where corners[i].distance(to: corners[(i + 1) % n]) <= Self.minimumWallLength {
            return true
        }
        return false
    }

    private func shoelaceArea(_ corners: [PlanePoint]) -> Float {
        var sum: Float = 0
        for i in corners.indices {
            let a = corners[i]
            let b = corners[(i + 1) % corners.count]
            sum += a.x * b.z - b.x * a.z
        }
        return abs(sum) / 2
    }

    // MARK: - Segment intersection (orientation method)

    private func segmentsIntersect(_ p1: SIMD2<Float>, _ p2: SIMD2<Float>,
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
    private func orientation(_ a: SIMD2<Float>, _ b: SIMD2<Float>, _ c: SIMD2<Float>) -> Float {
        (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
    }

    /// Whether point `p` lies within the bounding box of segment a–b (used only
    /// when the three points are already known collinear).
    private func onSegment(_ a: SIMD2<Float>, _ b: SIMD2<Float>, _ p: SIMD2<Float>) -> Bool {
        min(a.x, b.x) <= p.x && p.x <= max(a.x, b.x) &&
        min(a.y, b.y) <= p.y && p.y <= max(a.y, b.y)
    }
}
