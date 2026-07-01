import Testing
import Foundation
import simd
@testable import Snug

/// Regression coverage for the rotation-convention bug: the fit footprint
/// (`OrientedFootprint`, consumed by `FitService` / `FurniturePlacementValidator` /
/// `WallSnapService`) MUST rotate the same way the diorama renders a piece — a +Y
/// yaw via `simd_quatf(angle: yRotation, axis: [0,1,0])`. When the two disagreed by
/// a sign, a piece that looked flush/inside on screen read as askew and poking
/// through the wall — but only at non-90° yaws, so axis-aligned rooms hid it and
/// tilted (manually-captured) walls exposed it.
struct OrientedFootprintConventionTests {

    /// A +Y yaw maps the local depth axis (+Z, `size.y`) to `(sin θ, cos θ)` in
    /// world (x, z) — identical to what RealityKit applies to the rendered box.
    @Test func depthAxisMatchesRealityKitYRotation() {
        let theta: Float = 0.4
        let depth: Float = 0.8
        let fp = OrientedFootprint(center: .zero, size: SIMD2(0.5, depth), rotation: theta)

        // Midpoint of the +depth edge (between corners 2 and 3) is the front-face
        // center; it must sit at center + depth/2 · (sinθ, cosθ).
        let frontMid = (fp.corners[2] + fp.corners[3]) / 2
        let expected = SIMD2(sin(theta), cos(theta)) * (depth / 2)
        #expect(simd_distance(frontMid, expected) < 1e-5)
    }

    /// The same yaw RealityKit uses to orient the entity. Mirrors
    /// `FurnitureEntityBuilder.entity`'s `simd_quatf(angle:axis:)` so the test
    /// fails if the footprint convention ever drifts from the renderer again.
    @Test func cornersMatchAnExplicitRealityKitRotation() {
        let theta: Float = -0.7
        let size = SIMD2<Float>(1.2, 0.6)
        let fp = OrientedFootprint(center: SIMD2(0.3, -0.2), size: size, rotation: theta)
        let q = simd_quatf(angle: theta, axis: [0, 1, 0])

        let half = size / 2
        let local: [SIMD3<Float>] = [
            SIMD3(-half.x, 0, -half.y),
            SIMD3(half.x, 0, -half.y),
            SIMD3(half.x, 0, half.y),
            SIMD3(-half.x, 0, half.y),
        ]
        for (i, corner) in fp.corners.enumerated() {
            let rotated = q.act(local[i])               // RealityKit-space corner
            let world = SIMD2(0.3 + rotated.x, -0.2 + rotated.z)
            #expect(simd_distance(corner, world) < 1e-5)
        }
    }
}

/// `WallSnapService` snaps for the render convention; with the footprint now on the
/// SAME convention, a snapped piece is genuinely flush and inside even against a
/// TILTED wall — the case axis-aligned `WallSnapServiceTests` can't reach.
struct WallSnapTiltedWallTests {

    private let service = FitService()

    /// A 4×4 m square rotated 0.3 rad about the origin — every wall is off-axis, so
    /// the rotation-sign bug is live here (it cancels only at multiples of 90°).
    private var tiltedRoom: [SIMD2<Float>] {
        let r: Float = 0.3
        let c = cos(r), s = sin(r)
        return [SIMD2<Float>(-2, -2), SIMD2(2, -2), SIMD2(2, 2), SIMD2(-2, 2)].map {
            SIMD2($0.x * c - $0.y * s, $0.x * s + $0.y * c)
        }
    }

    @Test func snappedPieceIsFlushAndInsideOnATiltedWall() throws {
        let corners = tiltedRoom
        let depth: Float = 0.8
        let width: Float = 1.0
        let wall = 1   // an off-axis wall

        let snap = try #require(WallSnapService.snap(
            pieceCenter: .zero, width: width, depth: depth, toWall: wall, corners: corners))

        let fp = OrientedFootprint(center: snap.position, size: SIMD2(width, depth), rotation: snap.yRotation)

        // Flush: the piece's nearest corner sits ~`wallGap` from the chosen wall
        // segment (back against it), not floating in front of it.
        let a = corners[wall], b = corners[(wall + 1) % corners.count]
        let backGap = fp.corners.map { Geometry2D.distance(from: $0, toSegment: a, b) }.min() ?? .infinity
        #expect(abs(backGap - WallSnapService.wallGap) < 0.02)

        // Inside: the fit math agrees with the render — not poking through a wall.
        let result = service.evaluate(
            item: fp, in: FitGeometry(room: RoomFootprint(corners: corners)), errorMargin: 0.05)
        #expect(result.state != .wontFit)
        #expect(result.wallClearance > -0.05)
    }
}
