import Foundation
import Testing
import simd
@testable import Snug

/// The Ideation-Sandbox data track: decoding shapes, the read library, and the
/// `SandboxAsset → FurnitureFootprint` bridge that tags a piece as ideation.
struct SandboxLibraryTests {

    private static let json = """
    [
      {
        "id": "sbx-sofa", "name": "Mid-Century Sofa", "category": "sofa",
        "style": "mid_century", "baseDimensions": [2.15, 0.90, 0.85],
        "colorCategory": "warmBrown", "material": "fabric"
      },
      {
        "id": "sbx-table", "name": "Round Table", "category": "dining_table",
        "style": "scandinavian", "baseDimensions": [1.05, 1.05, 0.75],
        "colorCategory": "white", "material": "wood"
      }
    ]
    """

    private struct StubSource: SandboxSource {
        let assets: [SandboxAsset]
        func load() async throws -> [SandboxAsset] { assets }
    }

    @Test func decodesAssetsFromJSON() throws {
        let assets = try JSONDecoder().decode([SandboxAsset].self, from: Data(Self.json.utf8))
        #expect(assets.count == 2)
        let sofa = try #require(assets.first)
        #expect(sofa.id == "sbx-sofa")
        #expect(sofa.category == .sofa)
        #expect(sofa.style == .midCentury)
        #expect(sofa.baseDimensions == SIMD3<Float>(2.15, 0.90, 0.85))
    }

    @MainActor
    @Test func bundledSandboxAssetsDecodeAndAreUsable() async {
        // The shipped resource must decode and be non-empty (it feeds the Ideas tab).
        let library = SandboxLibrary()
        await library.load()
        #expect(library.loadError == nil)
        #expect(!library.assets.isEmpty)
        // Every shipped shape has a positive base size on all axes and a bundled
        // clay model to render (the Ideas tab is fed by the `tools/catalog/` library).
        for asset in library.assets {
            #expect(asset.baseDimensions.x > 0 && asset.baseDimensions.y > 0 && asset.baseDimensions.z > 0)
            #expect(asset.modelAssetName != nil)
        }
    }

    @MainActor
    @Test func libraryFiltersByCategoryAndListsAvailable() async throws {
        let assets = try JSONDecoder().decode([SandboxAsset].self, from: Data(Self.json.utf8))
        let library = SandboxLibrary(source: StubSource(assets: assets))
        await library.load()
        #expect(library.assets(in: .sofa).map(\.id) == ["sbx-sofa"])
        #expect(library.assets(in: nil).count == 2)
        // Declaration order: sofa precedes dining_table in FurnitureCategory.
        #expect(library.availableCategories == [.sofa, .diningTable])
    }

    @Test func makeFootprintTagsAsSandboxNotCatalog() {
        let asset = SandboxAsset(
            id: "sbx-sofa", name: "Mid-Century Sofa", category: .sofa,
            style: .midCentury, baseDimensions: SIMD3(2.15, 0.90, 0.85),
            colorCategory: .warmBrown, material: .fabric, modelAssetName: "quaternius_Sofa")
        let footprint = asset.makeFootprint(at: SIMD2(1, 2), yRotation: 0.5)

        #expect(footprint.sandboxAssetID == "sbx-sofa")
        #expect(footprint.catalogItemID == nil)            // never a buyable product
        #expect(footprint.detectionConfidence == .manual)  // user-chosen size → widened margin
        #expect(footprint.isKept)                           // occupies floor as an obstacle
        #expect(footprint.dimensions == asset.baseDimensions)
        // Base sits on the floor: center is half the height up.
        #expect(footprint.worldPosition == SIMD3<Float>(1, 0.85 / 2, 2))
        // No true-color claim for an ideation shape.
        #expect(footprint.appearance.exactColorRGB == nil)
    }

    /// Decode-safety: a pre-sandbox room blob (no `sandboxAssetID` key) must still
    /// decode, with the field nil — the whole point of it being optional.
    @Test func footprintWithoutSandboxKeyDecodesToNil() throws {
        let legacy = """
        {
          "id": "00000000-0000-0000-0000-000000000001",
          "category": "chair",
          "worldPosition": [0, 0.5, 0],
          "dimensions": [0.7, 0.7, 0.9],
          "yRotation": 0,
          "appearance": { "colorCategory": "tan", "materialClass": "fabric" },
          "detectionConfidence": "detected",
          "isCleared": false,
          "isKept": true
        }
        """
        let footprint = try JSONDecoder().decode(FurnitureFootprint.self, from: Data(legacy.utf8))
        #expect(footprint.sandboxAssetID == nil)
        #expect(footprint.catalogItemID == nil)
    }
}
