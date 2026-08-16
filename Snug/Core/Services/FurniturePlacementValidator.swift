import Foundation
import simd

/// How a furniture footprint sits relative to the room and its neighbors —
/// the data source for the placement tray's red/amber/green feedback.
enum PlacementState: Equatable {
    /// Inside the room, clear of every wall and other piece. (green)
    case valid
    /// Inside, but within the wall/overlap margin of a wall or another piece. (amber)
    case tooClose
    /// A corner is outside the room, or it overlaps another piece. (red)
    case invalid
}

/// Validates a single furniture footprint against the room boundary and the
/// other furniture in the room.
///
/// Pure and deterministic — no ARKit, no UI, no stored state — so it is fully
/// unit-testable and can run on every slider tick. It reuses only the existing
/// `FitGeometry` primitives (`Geometry2D`, `OrientedFootprint`, `RoomFootprint`);
/// it introduces no new spatial math.
struct FurniturePlacementValidator {

    /// Classify `footprint` against the room and the OTHER footprints in it.
    ///
    /// Severity order (most severe wins): a corner outside the room or an overlap
    /// with another piece is `.invalid` (red); merely sitting within `wallMargin`
    /// of a wall or `overlapMargin` of a neighbor is `.tooClose` (amber);
    /// otherwise `.valid` (green). We check all `.invalid` conditions before any
    /// `.tooClose` one, so an overlap is never downgraded to amber.
    static func validate(
        footprint: FurnitureFootprint,
        against room: RoomModel,
        existingFootprints: [FurnitureFootprint],
        wallMargin: Float = 0.08,
        overlapMargin: Float = 0.05
    ) -> PlacementState {
        let polygon = room.floorCorners.map(\.simd2)
        guard polygon.count >= 3 else { return .invalid }

        let box = OrientedFootprint(
            center: SIMD2(footprint.worldPosition.x, footprint.worldPosition.z),
            size: SIMD2(footprint.dimensions.x, footprint.dimensions.y),
            rotation: footprint.yRotation
        )
        let corners = box.corners
        let others = existingFootprints.filter { $0.id != footprint.id && !$0.isCleared }
            .map { other in
                OrientedFootprint(
                    center: SIMD2(other.worldPosition.x, other.worldPosition.z),
                    size: SIMD2(other.dimensions.x, other.dimensions.y),
                    rotation: other.yRotation
                )
            }

        // --- Invalid (red) conditions first ---

        // Not fully inside the room — a corner outside the polygon OR a wall
        // edge slicing through the box (the spanning-a-notch case corner tests
        // alone miss). Same predicate FitService's containment uses.
        if !Geometry2D.isConvexFootprint(corners, insidePolygon: polygon) {
            return .invalid
        }
        // Overlap with any other piece: non-positive signed clearance. Same
        // math as FitService's obstacle clearance (`Geometry2D.clearance`).
        let neighborClearances = others.map { Geometry2D.clearance(box, $0) }
        if neighborClearances.contains(where: { $0 <= 0 }) {
            return .invalid
        }

        // --- Too-close (amber) conditions ---

        // Within `wallMargin` of any wall edge.
        let edges = RoomFootprint(corners: polygon).edges
        let nearestWall = corners.map { corner in
            edges.map { Geometry2D.distance(from: corner, toSegment: $0.start, $0.end) }.min() ?? .greatestFiniteMagnitude
        }.min() ?? .greatestFiniteMagnitude
        if nearestWall < wallMargin { return .tooClose }

        // Within `overlapMargin` of any other (non-overlapping) piece.
        if neighborClearances.contains(where: { $0 < overlapMargin }) {
            return .tooClose
        }

        return .valid
    }
}
