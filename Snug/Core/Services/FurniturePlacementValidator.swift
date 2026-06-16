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

        // Any corner outside the room polygon.
        if corners.contains(where: { !Geometry2D.isPoint($0, insidePolygon: polygon) }) {
            return .invalid
        }
        // Overlap with any other piece (SAT via the rectangles' separating axes).
        if others.contains(where: { overlaps(box, $0) }) {
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
        if others.contains(where: { minimumDistance(box, $0) < overlapMargin }) {
            return .tooClose
        }

        return .valid
    }

    // MARK: - Geometry (composed from existing FitGeometry primitives)

    /// Separating-Axis-Theorem overlap test for two oriented rectangles, using the
    /// rectangles' own face normals (`OrientedFootprint.separatingAxes`) — the
    /// complete axis set for two convex boxes — and `Geometry2D.projectionInterval`.
    private static func overlaps(_ a: OrientedFootprint, _ b: OrientedFootprint) -> Bool {
        let cornersA = a.corners
        let cornersB = b.corners
        for axis in a.separatingAxes + b.separatingAxes {
            let pa = Geometry2D.projectionInterval(of: cornersA, onto: axis)
            let pb = Geometry2D.projectionInterval(of: cornersB, onto: axis)
            if pa.min > pb.max || pb.min > pa.max { return false }   // a gap ⇒ separated
        }
        return true
    }

    /// Minimum distance between two disjoint rectangles: the smallest corner→edge
    /// distance in both directions (`Geometry2D.distance(from:toSegment:_:)`).
    private static func minimumDistance(_ a: OrientedFootprint, _ b: OrientedFootprint) -> Float {
        let cornersA = a.corners
        let cornersB = b.corners
        var best = Float.greatestFiniteMagnitude
        for corner in cornersA {
            for i in cornersB.indices {
                best = min(best, Geometry2D.distance(from: corner, toSegment: cornersB[i], cornersB[(i + 1) % cornersB.count]))
            }
        }
        for corner in cornersB {
            for i in cornersA.indices {
                best = min(best, Geometry2D.distance(from: corner, toSegment: cornersA[i], cornersA[(i + 1) % cornersA.count]))
            }
        }
        return best
    }
}
