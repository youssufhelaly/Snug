import Testing
import Foundation
@testable import Snug

/// The sample room must be honest (labeled as a sample) and must show the fit
/// check working: every starting product exists in the bundled catalog and fits.
struct SampleRoomTests {

    private func bundledCatalog() async throws -> [CatalogItem] {
        try await BundledCatalogSource().load()
    }

    @Test func isLabeledAsASampleNotAScan() async throws {
        let room = SampleRoom.make(catalog: try await bundledCatalog())
        #expect(room.provenance == .sample)
        #expect(SampleRoom.name.localizedCaseInsensitiveContains("sample"))
    }

    @Test func everyStartingProductIsInTheBundledCatalog() async throws {
        let ids = Set(try await bundledCatalog().map(\.id))
        for placement in SampleRoom.placements {
            #expect(ids.contains(placement.catalogItemID), "missing \(placement.catalogItemID)")
        }
    }

    @Test func everyPlacedPieceFitsUnderTheRealFitCheck() async throws {
        let room = SampleRoom.make(catalog: try await bundledCatalog())
        #expect(room.detectedFurniture.count == SampleRoom.placements.count)
        for piece in room.detectedFurniture {
            let state = room.fitResult(for: piece, excluding: piece.id).state
            #expect(state == .fits || state == .fitsWithRoom, "\(piece.catalogItemID ?? "?") is \(state)")
        }
    }

    @Test func skipsProductsMissingFromTheCatalog() {
        let room = SampleRoom.make(catalog: [])
        #expect(room.detectedFurniture.isEmpty)
        #expect(room.floorCorners.count == 4)
    }
}
