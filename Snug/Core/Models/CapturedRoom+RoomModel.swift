import Foundation
import RoomPlan
import simd

/// Bridges Apple's RoomPlan output into the app's own `RoomModel`. Kept
/// separate from the RoomPlan capture code so the conversion is easy to find
/// and test, and so nothing about RoomPlan leaks past this file.
extension RoomModel {

    /// Builds a `RoomModel` from a finished RoomPlan `CapturedRoom`.
    ///
    /// RoomPlan gives oriented surface planes, not a floor polygon, so the
    /// floor outline is approximated from the largest floor surface's
    /// rectangle (exact for rectangular rooms, a bounding box for L-shapes —
    /// the same approximation the Phase 0 diagonal already used). Ceiling
    /// height is taken from the tallest wall.
    init(capturedRoom room: CapturedRoom, id: UUID = UUID(), capturedAt: Date = Date()) {
        let corners = Self.floorCorners(from: room)
        let height = room.walls.map { $0.dimensions.y }.max() ?? 2.4
        let openings = Self.openings(from: room)
        self.init(
            id: id,
            capturedAt: capturedAt,
            provenance: .roomPlan,
            floorCorners: corners,
            ceilingHeight: height,
            openings: openings
        )
    }

    private static func floorCorners(from room: CapturedRoom) -> [PlanePoint] {
        if let floor = room.floors.max(by: { $0.dimensions.x * $0.dimensions.y < $1.dimensions.x * $1.dimensions.y }) {
            return rectangleCorners(transform: floor.transform, width: floor.dimensions.x, depth: floor.dimensions.y)
        }
        // No floor captured: fall back to the bounding box of the wall bases.
        var pts: [PlanePoint] = []
        for wall in room.walls {
            for offset: Float in [-0.5, 0.5] {
                let p = wall.transform * SIMD4<Float>(offset * wall.dimensions.x, 0, 0, 1)
                pts.append(PlanePoint(x: p.x, z: p.z))
            }
        }
        guard !pts.isEmpty else { return [] }
        let xs = pts.map(\.x), zs = pts.map(\.z)
        let minX = xs.min()!, maxX = xs.max()!, minZ = zs.min()!, maxZ = zs.max()!
        return [
            PlanePoint(x: minX, z: minZ),
            PlanePoint(x: maxX, z: minZ),
            PlanePoint(x: maxX, z: maxZ),
            PlanePoint(x: minX, z: maxZ),
        ]
    }

    /// The four floor-plane corners of an oriented surface rectangle.
    private static func rectangleCorners(transform: simd_float4x4, width: Float, depth: Float) -> [PlanePoint] {
        // A RoomPlan surface plane spans its local x (width) and y (height);
        // the floor plane's transform lays that rectangle flat, so the local
        // (±w/2, ±h/2) corners map to the floor outline.
        let hw = width / 2
        let hd = depth / 2
        let local: [SIMD4<Float>] = [
            SIMD4(-hw, -hd, 0, 1),
            SIMD4(hw, -hd, 0, 1),
            SIMD4(hw, hd, 0, 1),
            SIMD4(-hw, hd, 0, 1),
        ]
        return local.map { corner in
            let world = transform * corner
            return PlanePoint(x: world.x, z: world.z)
        }
    }

    private static func openings(from room: CapturedRoom) -> [RoomOpening] {
        func make(_ surfaces: [CapturedRoom.Surface], kind: RoomOpening.Kind) -> [RoomOpening] {
            surfaces.map { surface in
                // Project the surface's two horizontal ends to the floor.
                let half = surface.dimensions.x / 2
                let a = surface.transform * SIMD4<Float>(-half, 0, 0, 1)
                let b = surface.transform * SIMD4<Float>(half, 0, 0, 1)
                return RoomOpening(
                    kind: kind,
                    start: PlanePoint(x: a.x, z: a.z),
                    end: PlanePoint(x: b.x, z: b.z),
                    height: surface.dimensions.y
                )
            }
        }
        return make(room.doors, kind: .door)
            + make(room.windows, kind: .window)
            + make(room.openings, kind: .opening)
    }
}
