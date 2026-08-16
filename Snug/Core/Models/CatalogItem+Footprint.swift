import Foundation
import simd

/// Bridges a purchasable `CatalogItem` into the placed-furniture and fit layers,
/// reusing the exact rails detected furniture already runs on: a placed product
/// is a `FurnitureFootprint` (so the diorama renders it and `keptObstacles`
/// counts it), and a fit check is the pure `FitService` evaluating it against the
/// room walls plus every *other* kept piece. No parallel placement or fit system.
extension CatalogItem {
    /// A placed footprint for this product at a floor position.
    ///
    /// `floorXZ` is the world floor point (x = world X, y = world Z). The base
    /// sits on the `y = 0` floor plane, so the center is half the height up —
    /// the identical convention `FurniturePlacementService.place` uses (it does
    /// NOT bake in the AR session's `sessionFloorY`). Confidence is `.detected`
    /// because the dimensions are the real product spec, so `FitService` trusts
    /// it at the standard margin. `isKept` is true: a product you've placed
    /// occupies floor and must constrain the next placement.
    func makeFootprint(at floorXZ: SIMD2<Float>, yRotation: Float = 0) -> FurnitureFootprint {
        FurnitureFootprint(
            id: UUID(),
            category: category,
            worldPosition: SIMD3(floorXZ.x, dimensions.z / 2, floorXZ.y),
            dimensions: dimensions,
            yRotation: yRotation,
            appearance: FurnitureAppearance(
                colorCategory: colorCategory,
                materialClass: material,
                exactColorRGB: trueColorRGB   // known manufacturer color → rendered exactly
            ),
            detectionConfidence: .detected,
            isCleared: false,
            isKept: true,
            catalogItemID: id
        )
    }
}

extension RoomModel {
    /// The four-state fit result for a candidate footprint against this room's
    /// walls and all OTHER kept furniture.
    ///
    /// `excluding` drops the footprint with that id from the obstacle set, so
    /// re-checking an already-placed item (after a drag/resize) never treats the
    /// piece as its own obstacle. Detected `.estimated`/`.manual` kept pieces
    /// keep their widened margin (via `keptObstacles` → `FitObstacle.confidence`);
    /// the candidate itself is evaluated at the standard band.
    func fitResult(
        for candidate: FurnitureFootprint,
        excluding excludedID: UUID? = nil,
        using service: FitService = FitService()
    ) -> FitResult {
        let obstacles = detectedFurniture
            .filter { $0.id != excludedID }
            .keptObstacles
        let geometry = fitGeometry(obstacles: obstacles)
        let item = OrientedFootprint(
            center: SIMD2(candidate.worldPosition.x, candidate.worldPosition.z),
            size: SIMD2(candidate.dimensions.x, candidate.dimensions.y),
            rotation: candidate.yRotation
        )
        return service.evaluate(item: item, in: geometry)
    }
}
