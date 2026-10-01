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
    /// Every piece still in the room, as fit obstacles. "Kept" means the user
    /// didn't clear it: placed products, Sandbox shapes, and detected furniture
    /// left in place all occupy floor. Cleared pieces are out of the room, so
    /// they never do.
    ///
    /// This deliberately ignores `FurnitureFootprint.isKept`. No UI ever sets
    /// that flag on detected furniture (the detection step's "Done, keep N"
    /// just leaves pieces in place), so filtering on it silently dropped real
    /// furniture from the fit check while the diorama still drew it.
    var keptObstacles: [FitObstacle] {
        filter { !$0.isCleared }.map(\.fitObstacle)
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
