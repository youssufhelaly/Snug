import Foundation
@testable import Snug

/// Room fixtures for FitService tests.
///
/// These are code-built `RoomModel`s shaped like real captured rooms (metric,
/// AR-provenance). Drop serialized exports from the app's fixture exporter into
/// `decodedFromJSON` to test against true scan output — `roundTripJSON` proves
/// the same `RoomModel` Codable form the app writes re-imports here unchanged.
enum FitFixtures {

    /// A plain rectangular bedroom, ~3.6 m × 3.0 m, centered at the origin.
    static let rectangularBedroom = RoomModel(
        provenance: .manualAR,
        floorCorners: [
            PlanePoint(x: -1.8, z: -1.5),
            PlanePoint(x:  1.8, z: -1.5),
            PlanePoint(x:  1.8, z:  1.5),
            PlanePoint(x: -1.8, z:  1.5),
        ],
        ceilingHeight: 2.5
    )

    /// The same bedroom with a window on the +Z (far) wall. Windows are NOT
    /// fit obstacles, so an item against that wall must still fit.
    static let bedroomWithWindow = RoomModel(
        provenance: .manualAR,
        floorCorners: rectangularBedroom.floorCorners,
        ceilingHeight: 2.5,
        openings: [
            RoomOpening(
                kind: .window,
                start: PlanePoint(x: -0.6, z: 1.5),
                end: PlanePoint(x: 0.6, z: 1.5),
                height: 1.2
            )
        ]
    )

    /// An L-shaped studio (non-convex) to exercise the conservative-on-reflex
    /// containment path. ~4 m × 4 m bounding box with a bite out of one corner.
    static let lShapedStudio = RoomModel(
        provenance: .manualAR,
        floorCorners: [
            PlanePoint(x: 0, z: 0),
            PlanePoint(x: 4, z: 0),
            PlanePoint(x: 4, z: 2),
            PlanePoint(x: 2, z: 2),
            PlanePoint(x: 2, z: 4),
            PlanePoint(x: 0, z: 4),
        ],
        ceilingHeight: 2.4
    )

    /// A U-shaped room: 6 m × 4 m bounding box with the notch x∈[2,4], z∈[2,4]
    /// cut OUT of the floor (open at z=4). Exercises the containment case corner
    /// tests alone miss: an item can bridge the two arms with all four corners
    /// on real floor while the notch walls pass clean through it.
    static let uShapedLounge = RoomModel(
        provenance: .manualAR,
        floorCorners: [
            PlanePoint(x: 0, z: 0),
            PlanePoint(x: 6, z: 0),
            PlanePoint(x: 6, z: 4),
            PlanePoint(x: 4, z: 4),
            PlanePoint(x: 4, z: 2),
            PlanePoint(x: 2, z: 2),
            PlanePoint(x: 2, z: 4),
            PlanePoint(x: 0, z: 4),
        ],
        ceilingHeight: 2.4
    )

    // MARK: - Codable proof

    /// A serialized `RoomModel` in the exact JSON form the app's fixture
    /// exporter produces. Decoding it proves real exports re-import cleanly.
    static let rectangularBedroomJSON = """
    {
      "id": "11111111-1111-1111-1111-111111111111",
      "capturedAt": 738000000,
      "provenance": "manualAR",
      "floorCorners": [
        {"x": -1.8, "z": -1.5},
        {"x": 1.8, "z": -1.5},
        {"x": 1.8, "z": 1.5},
        {"x": -1.8, "z": 1.5}
      ],
      "ceilingHeight": 2.5,
      "openings": []
    }
    """
}
