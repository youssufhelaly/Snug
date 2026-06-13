import Foundation
import simd

/// How a room's geometry was captured. Recorded on every `RoomModel` so the
/// accuracy log can compare techniques and the UI can be honest about which
/// method produced the numbers.
enum RoomCaptureProvenance: String, Codable, Equatable {
    /// Apple RoomPlan / LiDAR sweep (Pro devices only).
    case roomPlan
    /// AR-assisted corner tapping with ARKit world tracking (any modern
    /// iPhone, no LiDAR required).
    case manualAR
}

/// A point on the floor plane. `x` is world X, `z` is world Z; both meters.
///
/// We store our own little struct rather than `SIMD2<Float>` so `RoomModel`
/// has a stable, explicit Codable form for persistence and test fixtures.
struct PlanePoint: Codable, Equatable, Hashable {
    var x: Float
    var z: Float

    init(x: Float, z: Float) {
        self.x = x
        self.z = z
    }

    init(_ simd: SIMD2<Float>) {
        self.x = simd.x
        self.z = simd.y
    }

    /// `x`/`z` as a 2D vector (the floor-plane convention used by the fit
    /// geometry: vector `.y` carries world Z).
    var simd2: SIMD2<Float> { SIMD2(x, z) }

    func distance(to other: PlanePoint) -> Float {
        simd_distance(simd2, other.simd2)
    }
}

/// An opening in a wall: a door, window, or open passage. For the manual-AR
/// method these are captured as the two base points along the wall, so
/// `width` is reliable while `height` may be unknown (nil) until measured.
struct RoomOpening: Codable, Equatable, Identifiable {
    enum Kind: String, Codable {
        case door
        case window
        case opening

        var label: String {
            switch self {
            case .door: "Door"
            case .window: "Window"
            case .opening: "Opening"
            }
        }
    }

    let id: UUID
    var kind: Kind
    /// The two base endpoints of the opening, on the floor plane.
    var start: PlanePoint
    var end: PlanePoint
    /// Opening height in meters, if measured. Manual AR leaves this nil unless
    /// the user captures it.
    var height: Float?

    init(id: UUID = UUID(), kind: Kind, start: PlanePoint, end: PlanePoint, height: Float? = nil) {
        self.id = id
        self.kind = kind
        self.start = start
        self.end = end
        self.height = height
    }

    var width: Float { start.distance(to: end) }
}

/// A single wall, derived from a consecutive pair of floor corners. Not stored
/// — computed from the polygon so walls and corners can never disagree.
struct WallSegment: Identifiable, Equatable {
    let id: Int
    let start: PlanePoint
    let end: PlanePoint

    var length: Float { start.distance(to: end) }
}

/// The app's single room representation, produced by every capture method and
/// consumed by the editor, catalog, fit system, and accuracy logger alike.
/// Geometry is metric and rounded to the centimeter only at display time
/// (CLAUDE.md: never bake in false precision).
struct RoomModel: Identifiable, Codable, Equatable {
    let id: UUID
    var capturedAt: Date
    var provenance: RoomCaptureProvenance
    /// Ordered floor outline. The polygon is implicitly closed (last corner
    /// connects back to the first).
    var floorCorners: [PlanePoint]
    var ceilingHeight: Float
    var openings: [RoomOpening]

    init(
        id: UUID = UUID(),
        capturedAt: Date = Date(),
        provenance: RoomCaptureProvenance,
        floorCorners: [PlanePoint],
        ceilingHeight: Float,
        openings: [RoomOpening] = []
    ) {
        self.id = id
        self.capturedAt = capturedAt
        self.provenance = provenance
        self.floorCorners = floorCorners
        self.ceilingHeight = ceilingHeight
        self.openings = openings
    }

    // MARK: - Derived geometry

    /// Walls as segments between consecutive corners, closing the polygon.
    var walls: [WallSegment] {
        guard floorCorners.count >= 2 else { return [] }
        return floorCorners.indices.map { i in
            WallSegment(
                id: i,
                start: floorCorners[i],
                end: floorCorners[(i + 1) % floorCorners.count]
            )
        }
    }

    /// The longest corner-to-corner distance — the room "diagonal" the
    /// accuracy logger compares against a tape measure. For a rectangle this
    /// is the true diagonal; for any polygon it's the widest span, which is
    /// the best single proxy for clearance accuracy.
    var longestDiagonal: Float {
        var best: Float = 0
        for i in floorCorners.indices {
            for j in (i + 1)..<floorCorners.count {
                best = max(best, floorCorners[i].distance(to: floorCorners[j]))
            }
        }
        return best
    }

    /// Floor area via the shoelace formula (absolute value, winding-agnostic).
    var floorArea: Float {
        guard floorCorners.count >= 3 else { return 0 }
        var sum: Float = 0
        for i in floorCorners.indices {
            let a = floorCorners[i]
            let b = floorCorners[(i + 1) % floorCorners.count]
            sum += a.x * b.z - b.x * a.z
        }
        return abs(sum) / 2
    }

    var perimeter: Float {
        walls.reduce(0) { $0 + $1.length }
    }
}
