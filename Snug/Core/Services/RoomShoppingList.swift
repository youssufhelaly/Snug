import Foundation

/// The buyable products placed in a room, for the "Shop this room" sheet.
///
/// Pure and deterministic: it reads the room's placed pieces, matches them to
/// catalog products, and attaches each piece's fit verdict from `FitService`
/// (via `RoomModel.fitResult`), so the list can never contradict the room.
struct RoomShoppingList: Equatable {

    /// One product in the room. The same product placed twice is one entry
    /// with a quantity of 2.
    struct Entry: Identifiable, Equatable {
        var id: String { item.id }
        let item: CatalogItem
        /// How many copies of this product are placed.
        let quantity: Int
        /// The least favorable fit verdict among this product's copies, so a
        /// list entry never reads better than any piece in the room.
        let fit: FitResult.State
    }

    /// Entries in the order their products were first placed.
    let entries: [Entry]

    /// Total pieces across all entries.
    var pieceCount: Int { entries.reduce(0) { $0 + $1.quantity } }

    /// Entries whose every copy fits ("Fits" or "Fits with room to spare").
    var fittingCount: Int { entries.filter { $0.fit == .fits || $0.fit == .fitsWithRoom }.count }

    var isEmpty: Bool { entries.isEmpty }

    /// A list with nothing in it, e.g. while the room is still loading.
    static var empty: RoomShoppingList { RoomShoppingList(entries: []) }

    private init(entries: [Entry]) {
        self.entries = entries
    }

    /// Builds the list for `room`, using `catalog` to resolve placed products.
    /// Detected furniture, Sandbox sketches, cleared pieces, and products no
    /// longer in the catalog are left out: none of them can be bought here.
    init(room: RoomModel, catalog: [CatalogItem]) {
        let itemsByID = Dictionary(catalog.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var order: [String] = []
        var quantities: [String: Int] = [:]
        var worstFit: [String: FitResult.State] = [:]

        for piece in room.detectedFurniture where !piece.isCleared {
            guard piece.sandboxAssetID == nil,
                  let id = piece.catalogItemID,
                  itemsByID[id] != nil else { continue }
            let fit = room.fitResult(for: piece, excluding: piece.id).state
            if quantities[id] == nil { order.append(id) }
            quantities[id, default: 0] += 1
            worstFit[id] = worstFit[id].map { Self.lessFavorable($0, fit) } ?? fit
        }

        entries = order.compactMap { id in
            guard let item = itemsByID[id], let quantity = quantities[id], let fit = worstFit[id] else { return nil }
            return Entry(item: item, quantity: quantity, fit: fit)
        }
    }

    /// The less favorable of two fit verdicts.
    static func lessFavorable(_ a: FitResult.State, _ b: FitResult.State) -> FitResult.State {
        rank(a) <= rank(b) ? a : b
    }

    private static func rank(_ state: FitResult.State) -> Int {
        switch state {
        case .wontFit: 0
        case .tooCloseToCall: 1
        case .fits: 2
        case .fitsWithRoom: 3
        }
    }
}
