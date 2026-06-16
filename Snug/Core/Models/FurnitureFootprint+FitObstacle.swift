import Foundation
import simd

/// Bridges Phase 2 furniture footprints into the pure `FitGeometry` types the
/// trust layer consumes, keeping `FitService` ignorant of Vision / furniture.
extension FurnitureFootprint {
    /// This footprint as a fit obstacle on the floor plane.
    ///
    /// The 3D `worldPosition`/`dimensions` collapse to a 2D oriented rectangle:
    /// `worldPosition.x`/`.z` give the center (Y is altitude, dropped), and
    /// `dimensions.x`/`.y` are the footprint's width/depth (`.z` is height,
    /// dropped). Detection confidence maps onto the fit margin: a `.detected`
    /// piece is trusted at the standard band, while `.estimated` / `.manual`
    /// pieces — sized from category priors — widen it (CLAUDE.md Phase 2:
    /// `.estimated`/`.manual` = 1.5× margin).
    var fitObstacle: FitObstacle {
        FitObstacle(
            id: id,
            footprint: OrientedFootprint(
                center: SIMD2(worldPosition.x, worldPosition.z),
                size: SIMD2(dimensions.x, dimensions.y),
                rotation: yRotation
            ),
            kind: .keptObject,
            confidence: detectionConfidence == .detected ? .measured : .estimated
        )
    }
}

extension Sequence where Element == FurnitureFootprint {
    /// The kept (and not cleared) furniture as fit obstacles — the only pieces
    /// that constrain new placements. Cleared pieces are removed from the room,
    /// so they never occupy floor.
    var keptObstacles: [FitObstacle] {
        filter { $0.isKept && !$0.isCleared }.map(\.fitObstacle)
    }
}

extension RoomModel {
    /// Convenience: this room's fit input with its kept furniture already wired
    /// in as obstacles. The de-clutter step and the fit checks both call here so
    /// kept objects can never be silently dropped from a fit evaluation.
    func fitGeometryWithKeptFurniture(extraObstacles: [FitObstacle] = []) -> FitGeometry {
        fitGeometry(obstacles: detectedFurniture.keptObstacles + extraObstacles)
    }
}
