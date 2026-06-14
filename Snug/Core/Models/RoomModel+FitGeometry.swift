import Foundation
import simd

/// Bridges the persisted `RoomModel` into the pure `FitGeometry` the fit system
/// consumes. Keeps `FitService` ignorant of how a room was captured.
extension RoomModel {
    /// Build the fit input from this room's floor outline.
    ///
    /// - Parameter obstacles: occupied floor the item must avoid — kept-object
    ///   footprints and doorway keep-clear zones. Empty in Phase 0.5; the
    ///   de-clutter step (Phase 2) wires kept objects through here.
    ///
    /// Wall openings (doors/windows) are intentionally NOT obstacles: a sofa
    /// can sit under a window, and the closed floor polygon already represents
    /// the wall. Doorway swing/keep-clear zones, when we add them, arrive as
    /// explicit `FitObstacle`s of kind `.doorway`.
    func fitGeometry(obstacles: [FitObstacle] = []) -> FitGeometry {
        FitGeometry(
            room: RoomFootprint(corners: floorCorners.map(\.simd2)),
            obstacles: obstacles
        )
    }

    /// A plain ~3.6 m × 3.0 m room for exercising the fit harness without a
    /// live scan (debug entry point on the home screen).
    static let fitHarnessSample = RoomModel(
        provenance: .manualAR,
        floorCorners: [
            PlanePoint(x: -1.8, z: -1.5),
            PlanePoint(x: 1.8, z: -1.5),
            PlanePoint(x: 1.8, z: 1.5),
            PlanePoint(x: -1.8, z: 1.5),
        ],
        ceilingHeight: 2.5
    )
}
