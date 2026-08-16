import Foundation
import simd

/// Which camera the diorama is driving. Orthogonal to any material/rendering
/// choice — `.diorama` is the free-orbit isometric "is it arranged right?" view;
/// `.walkthrough` is the first-person "what will it feel like to walk in?" preview
/// at human eye height. Switching only changes the camera pose + gestures; no
/// geometry or material moves.
enum CameraPerspective: Equatable {
    case diorama
    case walkthrough
}

/// A preset standing spot for the first-person "step inside" walkthrough — a
/// fixed floor position, eye height, and initial look direction the user taps
/// between. Walkthrough is a *preview*, not an editor and not free-roam: a few
/// meaningful vantages (each doorway/opening, plus the room center) with
/// look-around gets ~90% of the "what will it feel like to walk in?" value while
/// dodging the collision/clipping/free-roam scope trap.
///
/// Pure value type, derived from `RoomModel` by `WalkthroughVantage.vantages(for:)`
/// so it's unit-testable without RealityKit. The scene consumes only `position`,
/// `eyeHeight`, and `initialYaw`; the UI shows `label`.
struct WalkthroughVantage: Identifiable, Equatable {
    let id: String
    /// User-facing chip label ("Doorway", "Window", "Center").
    let label: String
    /// SF Symbol for the chip.
    let symbol: String
    /// Standing position on the floor plane (world x, z).
    let position: SIMD2<Float>
    /// Camera height above the floor, in meters. Human standing eye height,
    /// clamped so it never pokes through a low ceiling.
    let eyeHeight: Float
    /// Initial horizontal look direction as a yaw angle: forward on the XZ plane
    /// is `(sin(yaw), cos(yaw))`, so `yaw == 0` faces +Z. Look-around adjusts from
    /// here; each vantage starts aimed at the room so you never open facing a wall.
    let initialYaw: Float

    /// Standing human eye height (meters) — the whole point of the mode.
    static let standingEyeHeight: Float = 1.6

    /// Derive the walkthrough vantages for a room: one per opening (stood just
    /// inside, facing the room center) plus a center vantage facing the main
    /// opening. Returns at least the center vantage for any room with a valid
    /// floor polygon; empty only for a degenerate room.
    static func vantages(for room: RoomModel) -> [WalkthroughVantage] {
        let corners = room.floorCorners.map(\.simd2)
        guard corners.count >= 3 else { return [] }
        // A point known to be INSIDE the room (see `interiorPoint`): every vantage
        // stands at or aims toward it, and for a concave (L-shaped) room the plain
        // vertex-mean centroid can land in the missing corner — outside the walls.
        let interior = interiorPoint(of: corners)
        let eye = eyeHeight(ceiling: room.ceilingHeight)

        var result: [WalkthroughVantage] = []

        // Number labels only within a kind that repeats, so a single door stays
        // "Doorway" while three windows become "Window 1/2/3".
        var kindCounts: [RoomOpening.Kind: Int] = [:]
        for opening in room.openings { kindCounts[opening.kind, default: 0] += 1 }
        var kindSeen: [RoomOpening.Kind: Int] = [:]

        for opening in room.openings {
            let mid = (opening.start.simd2 + opening.end.simd2) / 2
            var inward = interior - mid
            let dist = simd_length(inward)
            guard dist > 0.001 else { continue }
            inward /= dist
            // Stand ~0.6 m inside the opening, but never past the interior point in
            // a tiny room (half the distance to it is the cap).
            let step = min(0.6, dist * 0.5)
            let position = mid + inward * step
            let yaw = yawToward(from: position, target: interior)

            kindSeen[opening.kind, default: 0] += 1
            let label = kindCounts[opening.kind, default: 0] > 1
                ? "\(labelText(opening.kind)) \(kindSeen[opening.kind]!)"
                : labelText(opening.kind)

            result.append(WalkthroughVantage(
                id: "opening-\(opening.id.uuidString)",
                label: label,
                symbol: symbol(opening.kind),
                position: position,
                eyeHeight: eye,
                initialYaw: yaw
            ))
        }

        // Center vantage: stand at the interior point, facing the first opening
        // (the way you'd walk in) if there is one, else facing +Z.
        let centerYaw = room.openings.first.map {
            yawToward(from: interior, target: ($0.start.simd2 + $0.end.simd2) / 2)
        } ?? 0
        result.append(WalkthroughVantage(
            id: "center",
            label: "Center",
            symbol: "dot.scope",
            position: interior,
            eyeHeight: eye,
            initialYaw: centerYaw
        ))

        return result
    }

    /// Standing eye height clamped under the ceiling: 1.6 m in a normal room, but
    /// lowered (to ≥1.2 m) so it never sits at or above a low ceiling.
    private static func eyeHeight(ceiling: Float) -> Float {
        min(standingEyeHeight, max(1.2, ceiling - 0.2))
    }

    /// A point guaranteed to lie inside the room polygon, near its middle. The
    /// vertex-mean centroid when that's inside — true for every convex room, so a
    /// rectangle keeps its exact center — else the centroid of the largest triangle
    /// of the polygon's triangulation, which is always interior for a simple
    /// polygon. Without this, a concave (L-shaped) room's vertex-mean centroid can
    /// fall in the missing corner, standing the walkthrough camera in a wall.
    private static func interiorPoint(of corners: [SIMD2<Float>]) -> SIMD2<Float> {
        let centroid = corners.reduce(SIMD2<Float>.zero, +) / Float(corners.count)
        if Geometry2D.isPoint(centroid, insidePolygon: corners) { return centroid }

        // Concave room: pick the centroid of the largest triangle the polygon
        // triangulates into — a robust, always-interior "middle" point.
        let indices = PolygonTriangulator.triangulate(corners)
        var best: (area: Float, point: SIMD2<Float>)?
        var i = 0
        while i + 3 <= indices.count {
            let a = corners[Int(indices[i])]
            let b = corners[Int(indices[i + 1])]
            let c = corners[Int(indices[i + 2])]
            let area = abs((b.x - a.x) * (c.y - a.y) - (c.x - a.x) * (b.y - a.y)) * 0.5
            if best == nil || area > best!.area { best = (area, (a + b + c) / 3) }
            i += 3
        }
        return best?.point ?? centroid
    }

    /// Yaw such that forward `(sin, cos)` points from `from` toward `target` on
    /// the XZ plane. Returns 0 when the two coincide.
    private static func yawToward(from: SIMD2<Float>, target: SIMD2<Float>) -> Float {
        let d = target - from
        guard simd_length(d) > 0.001 else { return 0 }
        return atan2(d.x, d.y)
    }

    private static func labelText(_ kind: RoomOpening.Kind) -> String {
        switch kind {
        case .door: "Doorway"
        case .window: "Window"
        case .opening: "Opening"
        }
    }

    private static func symbol(_ kind: RoomOpening.Kind) -> String {
        switch kind {
        case .door: "door.left.hand.open"
        case .window: "window.vertical.closed"
        case .opening: "rectangle.portrait"
        }
    }
}
