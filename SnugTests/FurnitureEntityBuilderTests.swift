import Testing
import RealityKit
import simd
@testable import Snug

/// Structure of the de-clutter furniture entities: correct box bounds, a
/// collision shape + input target for tapping, and the footprint-id tag for
/// routing taps back to the model. (RealityKit — runs on device/simulator, not
/// Linux CI.)
@MainActor
struct FurnitureEntityBuilderTests {

    private func footprint() -> FurnitureFootprint {
        FurnitureFootprint(
            category: .sofa,
            worldPosition: SIMD3(0.5, 0.4, -0.3),
            dimensions: FurnitureCategory.sofa.defaultDimensions,   // (2.20, 0.90, 0.80)
            yRotation: 0,
            appearance: FurnitureAppearance(colorCategory: .cream, materialClass: .fabric),
            detectionConfidence: .detected
        )
    }

    @Test func boxMeshMatchesDimensions() {
        let f = footprint()
        let entity = FurnitureEntityBuilder.entity(for: f)
        let model = try? #require(entity as? ModelEntity)
        let extents = model?.model?.mesh.bounds.extents ?? .zero
        // Mesh is generateBox(width: x, height: z, depth: y).
        #expect(abs(extents.x - f.dimensions.x) < 0.02)
        #expect(abs(extents.y - f.dimensions.z) < 0.02)
        #expect(abs(extents.z - f.dimensions.y) < 0.02)
    }

    @Test func hasCollisionAndInputTarget() {
        let entity = FurnitureEntityBuilder.entity(for: footprint())
        #expect(entity.components[CollisionComponent.self] != nil)
        #expect(entity.components[InputTargetComponent.self] != nil)
    }

    @Test func taggedWithFootprintID() {
        let f = footprint()
        let entity = FurnitureEntityBuilder.entity(for: f)
        let tag = entity.components[FurnitureTagComponent.self]
        #expect(tag?.footprintID == f.id)
        #expect(tag?.category == .sofa)
    }

    @Test func keptAppearanceAddsAmberOutlineOnce() {
        let f = footprint()
        let entity = FurnitureEntityBuilder.entity(for: f)
        FurnitureEntityBuilder.applyKeptAppearance(to: entity, footprint: f)
        FurnitureEntityBuilder.applyKeptAppearance(to: entity, footprint: f)   // idempotent
        let outlines = entity.children.filter { $0.name == "kept_outline" }
        #expect(outlines.count == 1)
    }

    @Test func positionedAtWorldPosition() {
        let f = footprint()
        let entity = FurnitureEntityBuilder.entity(for: f)
        #expect(entity.position == f.worldPosition)
    }
}
