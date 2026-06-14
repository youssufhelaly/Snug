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
        let polygon = corners.map(\.simd2)
        if Geometry2D.hasSelfIntersection(polygon) {
            return .invalid("Invalid room shape — wall paths can't cross.")
        }
        if hasShortWall(corners) {
            return .invalid("Walls must be at least 30cm long.")
        }
        if Geometry2D.polygonArea(polygon) <= Self.minimumArea {
            return .invalid("Invalid room area — check corner positions.")
        }
        return .valid
    }

    // MARK: - Rules

    private func hasShortWall(_ corners: [PlanePoint]) -> Bool {
        let n = corners.count
        for i in 0..<n where corners[i].distance(to: corners[(i + 1) % n]) <= Self.minimumWallLength {
            return true
        }
        return false
    }
}
