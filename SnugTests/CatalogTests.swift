import Foundation
import Testing
import simd
@testable import Snug

/// Catalog/BUY-mode spine: model decoding, the read service, the
/// `CatalogItem → FurnitureFootprint` bridge, and the fit helper that runs a
/// candidate product against real room geometry.
struct CatalogTests {

    // MARK: - Fixtures

    /// A small product that comfortably fits the 3.6×3.0 m bedroom.
    private let lamp = CatalogItem(
        id: "test-coffee",
        name: "Test Coffee Table",
        brand: "Snug",
        category: .coffeeTable,
        dimensions: SIMD3(1.0, 0.5, 0.45),
        trueColorRGB: SIMD3(0.17, 0.15, 0.13),
        colorCategory: .black,
        material: .wood,
        priceCents: 4999,
        retailerName: "Test",
        productURL: URL(string: "https://example.com/p/coffee")!
    )

    /// A product wider than the room is — can never fit.
    private let hugeSofa = CatalogItem(
        id: "test-huge",
        name: "Enormous Sofa",
        brand: "Snug",
        category: .sofa,
        dimensions: SIMD3(5.0, 1.0, 0.8),
        trueColorRGB: SIMD3(0.42, 0.40, 0.38),
        colorCategory: .darkGrey,
        material: .fabric,
        priceCents: 199900,
        retailerName: "Test",
        productURL: URL(string: "https://example.com/p/huge")!
    )

    private struct StubSource: CatalogSource {
        let items: [CatalogItem]
        func load() async throws -> [CatalogItem] { items }
    }

    // MARK: - Model decoding

    @Test func decodesSIMDDimensionsFromJSONArrays() throws {
        let json = """
        [{
          "id": "x", "name": "X", "brand": "B", "category": "sofa",
          "dimensions": [2.18, 0.91, 0.84],
          "trueColorRGB": [0.42, 0.40, 0.38],
          "colorCategory": "darkGrey", "material": "fabric",
          "priceCents": 119900, "currencyCode": "USD",
          "retailerName": "R", "productURL": "https://example.com/p",
          "affiliateTag": null, "thumbnailAssetName": null,
          "modelAssetName": null, "inStock": true, "isRemovable": true
        }]
        """
        let items = try JSONDecoder().decode([CatalogItem].self, from: Data(json.utf8))
        #expect(items.count == 1)
        #expect(items[0].dimensions == SIMD3<Float>(2.18, 0.91, 0.84))
        #expect(items[0].category == .sofa)
        #expect(items[0].colorCategory == .darkGrey)
    }

    @Test func outboundURLAppendsAffiliateTag() throws {
        let item = CatalogItem(
            id: "a", name: "A", brand: "B", category: .chair,
            dimensions: SIMD3(0.7, 0.7, 0.9), trueColorRGB: SIMD3(0.5, 0.5, 0.5),
            colorCategory: .lightGrey, material: .fabric, priceCents: 9900,
            retailerName: "R", productURL: URL(string: "https://example.com/p?ref=snug")!,
            affiliateTag: "snug-20"
        )
        let url = item.outboundURL
        #expect(url.absoluteString.contains("tag=snug-20"))
        #expect(url.absoluteString.contains("ref=snug")) // existing query preserved
    }

    @Test func outboundURLIsBareWhenNoTag() {
        #expect(lamp.outboundURL == lamp.productURL)
    }

    // MARK: - Service

    @MainActor
    @Test func serviceLoadsAndFiltersNonRemovable() async {
        let removable = lamp
        var bolted = hugeSofa
        bolted = CatalogItem(
            id: "bolted", name: "Wall Unit", brand: "B", category: .bookshelf,
            dimensions: SIMD3(0.8, 0.3, 1.8), trueColorRGB: SIMD3(1, 1, 1),
            colorCategory: .white, material: .wood, priceCents: 10000,
            retailerName: "R", productURL: URL(string: "https://example.com/b")!,
            isRemovable: false
        )
        let service = CatalogService(source: StubSource(items: [removable, bolted]))
        await service.load()
        #expect(service.isLoaded)
        #expect(service.loadError == nil)
        #expect(service.items.count == 1)               // bolted item filtered out
        #expect(service.items.first?.id == "test-coffee")
    }

    @MainActor
    @Test func serviceFiltersSearchesAndListsCategories() async {
        let service = CatalogService(source: StubSource(items: [lamp, hugeSofa]))
        await service.load()
        #expect(service.items(in: .sofa).map(\.id) == ["test-huge"])
        #expect(service.search("enormous").map(\.id) == ["test-huge"])
        #expect(service.search("table").map(\.id) == ["test-coffee"]) // matches category name
        #expect(Set(service.availableCategories) == Set([.sofa, .coffeeTable]))
    }

    @MainActor
    @Test func serviceReportsFriendlyErrorOnFailure() async {
        struct FailingSource: CatalogSource {
            func load() async throws -> [CatalogItem] { throw BundledCatalogSource.LoadError.missingResource("nope") }
        }
        let service = CatalogService(source: FailingSource())
        await service.load()
        #expect(!service.isLoaded)
        #expect(service.items.isEmpty)
        #expect(service.loadError != nil)
    }

    // MARK: - Footprint bridge

    @Test func makeFootprintSnapsBaseToFloorAndLinksCatalog() {
        let fp = lamp.makeFootprint(at: SIMD2(0.5, -0.3))
        // Y is half the height so the base sits on the y=0 floor plane.
        #expect(fp.worldPosition.y == lamp.dimensions.z / 2)
        #expect(fp.worldPosition.x == 0.5)
        #expect(fp.worldPosition.z == -0.3)
        #expect(fp.catalogItemID == "test-coffee")
        #expect(fp.detectionConfidence == .detected) // real spec ⇒ standard margin
        #expect(fp.isKept)                            // placed product occupies floor
        #expect(!fp.isCleared)
        // Known manufacturer color is carried for BUY true-color rendering.
        #expect(fp.appearance.exactColorRGB == lamp.trueColorRGB)
    }

    @Test func exactColorSurvivesRoundTripAndDefaultsNilForOldBlobs() throws {
        // Catalog footprint keeps its exact color through Codable.
        let fp = lamp.makeFootprint(at: .zero)
        let data = try JSONEncoder().encode(fp)
        let decoded = try JSONDecoder().decode(FurnitureFootprint.self, from: data)
        #expect(decoded.appearance.exactColorRGB == lamp.trueColorRGB)

        // A pre-catalog appearance blob (no exactColorRGB key) decodes as nil.
        let legacy = Data("""
        {"colorCategory":"navy","materialClass":"fabric"}
        """.utf8)
        let appearance = try JSONDecoder().decode(FurnitureAppearance.self, from: legacy)
        #expect(appearance.exactColorRGB == nil)
        #expect(appearance.colorCategory == .navy)
    }

    @Test func placedCatalogItemBecomesAKeptObstacle() {
        let fp = lamp.makeFootprint(at: .zero)
        var room = FitFixtures.rectangularBedroom
        room.detectedFurniture = [fp]
        #expect(room.detectedFurniture.keptObstacles.count == 1)
    }

    // MARK: - Fit helper

    @Test func candidateFitsEmptyRoom() {
        let room = FitFixtures.rectangularBedroom
        let fp = lamp.makeFootprint(at: .zero)
        let result = room.fitResult(for: fp)
        #expect(result.state == .fitsWithRoom)
    }

    @Test func oversizedCandidateWontFit() {
        let room = FitFixtures.rectangularBedroom
        let fp = hugeSofa.makeFootprint(at: .zero)
        let result = room.fitResult(for: fp)
        #expect(result.state == .wontFit)
    }

    @Test func candidateIsNotItsOwnObstacleWhenExcluded() {
        var room = FitFixtures.rectangularBedroom
        let fp = lamp.makeFootprint(at: .zero)
        room.detectedFurniture = [fp]
        // Without excluding, the piece overlaps itself ⇒ won't fit.
        #expect(room.fitResult(for: fp).state == .wontFit)
        // Excluding its own id restores a clean fit.
        #expect(room.fitResult(for: fp, excluding: fp.id).state == .fitsWithRoom)
    }
}
