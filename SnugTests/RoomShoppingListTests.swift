import Testing
import Foundation
import simd
@testable import Snug

/// "Shop this room" lists each buyable product once, with its least favorable
/// fit verdict, and leaves out anything that can't be bought.
struct RoomShoppingListTests {

    private func item(_ id: String, width: Float = 0.5, depth: Float = 0.5) -> CatalogItem {
        CatalogItem(
            id: id, name: "Item \(id)", brand: "Snug", category: .chair,
            dimensions: SIMD3(width, depth, 0.8), trueColorRGB: SIMD3(0.5, 0.5, 0.5),
            colorCategory: .other, material: .fabric, priceCents: 1000,
            retailerName: "Test", productURL: URL(string: "https://example.com/\(id)")!
        )
    }

    private func room(_ furniture: [FurnitureFootprint]) -> RoomModel {
        var room = FitFixtures.rectangularBedroom   // 3.6 × 3.0 m, centered
        room.detectedFurniture = furniture
        return room
    }

    @Test func groupsCopiesOfAProductIntoOneEntry() {
        let chair = item("chair")
        let list = RoomShoppingList(room: room([
            chair.makeFootprint(at: SIMD2(-1, 0)),
            chair.makeFootprint(at: SIMD2(1, 0)),
        ]), catalog: [chair])
        #expect(list.entries.count == 1)
        #expect(list.entries.first?.quantity == 2)
        #expect(list.pieceCount == 2)
    }

    @Test func usesTheLeastFavorableFitAmongCopies() {
        let chair = item("chair")
        // One copy in the open, one pushed through the right wall (x = 1.8).
        let list = RoomShoppingList(room: room([
            chair.makeFootprint(at: SIMD2(-1, 0)),
            chair.makeFootprint(at: SIMD2(1.9, 0)),
        ]), catalog: [chair])
        #expect(list.entries.first?.fit == .wontFit)
        #expect(list.fittingCount == 0)
    }

    @Test func leavesOutClearedDetectedAndUnknownPieces() {
        let chair = item("chair")
        var cleared = chair.makeFootprint(at: SIMD2(0, 0))
        cleared.isCleared = true
        let detected = FurnitureFootprint(
            category: .sofa, worldPosition: SIMD3(0, 0.4, 1), dimensions: SIMD3(1, 0.5, 0.8),
            yRotation: 0, appearance: FurnitureAppearance(colorCategory: .other, materialClass: .other),
            detectionConfidence: .detected
        )
        let unknown = item("discontinued").makeFootprint(at: SIMD2(-1, -1))
        let list = RoomShoppingList(room: room([cleared, detected, unknown]), catalog: [chair])
        #expect(list.isEmpty)
    }

    @Test func keepsFirstPlacedOrder() {
        let a = item("a"), b = item("b")
        let list = RoomShoppingList(room: room([
            b.makeFootprint(at: SIMD2(-1, 0)),
            a.makeFootprint(at: SIMD2(1, 0)),
        ]), catalog: [a, b])
        #expect(list.entries.map(\.id) == ["b", "a"])
    }

    @Test func lessFavorableOrdersTheFourStates() {
        #expect(RoomShoppingList.lessFavorable(.fits, .wontFit) == .wontFit)
        #expect(RoomShoppingList.lessFavorable(.fitsWithRoom, .tooCloseToCall) == .tooCloseToCall)
        #expect(RoomShoppingList.lessFavorable(.fitsWithRoom, .fits) == .fits)
    }
}
