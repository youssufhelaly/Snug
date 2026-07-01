import Testing
import RealityKit
import simd
import UIKit
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

    // MARK: - Per-part coloring (Sandbox clay)

    @Test func humanizesRawPartNames() {
        #expect(FurnitureEntityBuilder.humanizePartName("BedFrame_Cube_001") == "Bed Frame")
        #expect(FurnitureEntityBuilder.humanizePartName("Mattress") == "Mattress")
        #expect(FurnitureEntityBuilder.humanizePartName("Pillow") == "Pillow")
        // All-generic tokens fall back to the raw key rather than going blank.
        #expect(!FurnitureEntityBuilder.humanizePartName("Cube_001").isEmpty)
    }

    /// A model whose named groups each wrap a `ModelEntity`, spaced apart along X so a
    /// vertical ray can pick a specific one: parts are discovered by the group name,
    /// and one part can be tinted while the others stay untouched.
    private func clayModel() -> Entity {
        let root = Entity()
        for (i, name) in ["BedFrame", "Mattress", "Pillow"].enumerated() {
            let group = Entity()
            group.name = name
            group.position = SIMD3(Float(i - 1) * 0.5, 0, 0)   // x = -0.5, 0, +0.5
            let mesh = ModelEntity(
                mesh: .generateBox(size: 0.2),
                materials: [SimpleMaterial(color: .white, isMetallic: false)])
            mesh.name = "Mesh"   // generic → part key resolves to the group name
            group.addChild(mesh)
            root.addChild(group)
        }
        return root
    }

    @Test func discoversNamedColorableParts() {
        let parts = FurnitureEntityBuilder.colorableParts(of: clayModel())
        #expect(parts.map(\.key) == ["BedFrame", "Mattress", "Pillow"])
        #expect(parts.map(\.displayName) == ["Bed Frame", "Mattress", "Pillow"])
    }

    @Test func applyPartColorTintsOnlyThatPart() {
        let model = clayModel()
        FurnitureEntityBuilder.applyPartColor(.red, toPart: "Mattress", in: model)

        func baseColor(ofPart name: String) -> UIColor? {
            guard let mesh = model.findEntity(named: name)?.children.first as? ModelEntity,
                  let pbr = mesh.model?.materials.first as? PhysicallyBasedMaterial else { return nil }
            return pbr.baseColor.tint
        }
        // Mattress is now a tinted PBR material; the others keep their original.
        #expect(baseColor(ofPart: "Mattress") != nil)
        #expect(model.findEntity(named: "BedFrame")?.children.first
            .flatMap { ($0 as? ModelEntity)?.model?.materials.first as? PhysicallyBasedMaterial } == nil)
    }

    @Test func rayPicksThePartUnderItByActualGeometry() {
        let model = clayModel()   // boxes at x = -0.5 (BedFrame), 0 (Mattress), +0.5 (Pillow)
        // A vertical ray straight down through each box returns that part.
        func partUnder(x: Float) -> String? {
            FurnitureEntityBuilder.partKey(
                forRayOrigin: SIMD3(x, 5, 0), direction: SIMD3(0, -1, 0), in: model)
        }
        #expect(partUnder(x: -0.5) == "BedFrame")
        #expect(partUnder(x: 0) == "Mattress")
        #expect(partUnder(x: 0.5) == "Pillow")
        // A ray through empty space hits nothing.
        #expect(partUnder(x: 5) == nil)
    }
}
