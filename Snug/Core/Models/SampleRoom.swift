import Foundation
import simd

/// A furnished example bedroom, so a first-time user (or an App Store
/// reviewer) can try placing furniture and the fit check in seconds, before
/// scanning anything.
///
/// It is honest about what it is: its provenance is `.sample` and its name
/// says "Sample", so the app never presents it as a measurement of the user's
/// space (CLAUDE.md: never fake the scan). The geometry is the same 3.6 × 3.0 m
/// bedroom the fit tests use, and every placed product clears the walls and
/// the other pieces under the real fit check (pinned by `SampleRoomTests`).
enum SampleRoom {
    static let name = "Sample bedroom"

    /// A starting product and where it goes. Positions are floor-plane meters
    /// (x, z); yaw is degrees about +Y, the convention every footprint uses.
    struct Placement: Equatable {
        let catalogItemID: String
        let x: Float
        let z: Float
        let yawDegrees: Float
    }

    /// A bed against the right wall with a nightstand beside it, a dresser
    /// on the back wall clear of the door, and an accent chair facing the bed.
    static let placements: [Placement] = [
        Placement(catalogItemID: "amzn-b07dzt2sz3", x: 0.70, z: 0.20, yawDegrees: 90),    // platform bed
        Placement(catalogItemID: "amzn-b0cjmbz6gj", x: 1.53, z: 1.25, yawDegrees: 270),   // nightstand
        Placement(catalogItemID: "amzn-b0gmw7fq83", x: -0.15, z: -1.22, yawDegrees: 0),   // dresser
        Placement(catalogItemID: "amzn-b0gtz6jfq9", x: -1.15, z: 0.85, yawDegrees: 110),  // accent chair
    ]

    /// The sample room, furnished with whichever starting products the catalog
    /// has. Missing products are skipped rather than faked.
    static func make(catalog: [CatalogItem], now: Date = Date()) -> RoomModel {
        let itemsByID = Dictionary(catalog.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let furniture = placements.compactMap { placement -> FurnitureFootprint? in
            guard let item = itemsByID[placement.catalogItemID] else { return nil }
            return item.makeFootprint(
                at: SIMD2(placement.x, placement.z),
                yRotation: placement.yawDegrees * .pi / 180
            )
        }
        return RoomModel(
            capturedAt: now,
            provenance: .sample,
            floorCorners: [
                PlanePoint(x: -1.8, z: -1.5),
                PlanePoint(x: 1.8, z: -1.5),
                PlanePoint(x: 1.8, z: 1.5),
                PlanePoint(x: -1.8, z: 1.5),
            ],
            ceilingHeight: 2.5,
            openings: [
                RoomOpening(kind: .window, start: PlanePoint(x: -0.6, z: 1.5), end: PlanePoint(x: 0.6, z: 1.5), height: 1.2),
                RoomOpening(kind: .door, start: PlanePoint(x: -1.8, z: -1.3), end: PlanePoint(x: -1.8, z: -0.45), height: 2.05),
            ],
            detectedFurniture: furniture,
            surfaceStyle: RoomSurfaceStyle(wall: .cream, floor: .lightOak)
        )
    }
}
