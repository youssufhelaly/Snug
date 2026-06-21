import Foundation
import Observation

/// Where catalog items come from. V1 has exactly one conformer
/// (`BundledCatalogSource`); the protocol exists so a remote catalog can replace
/// the bundle later without changing `CatalogService` or any view. Kept
/// deliberately thin — one async load, nothing more.
protocol CatalogSource: Sendable {
    func load() async throws -> [CatalogItem]
}

/// Loads the catalog from the bundled `catalog.json` resource pack. Offline-first
/// (CLAUDE.md hard rule): no network, the JSON ships in the app bundle.
struct BundledCatalogSource: CatalogSource {
    let resourceName: String
    let bundle: Bundle

    init(resourceName: String = "catalog", bundle: Bundle = .main) {
        self.resourceName = resourceName
        self.bundle = bundle
    }

    enum LoadError: Error, LocalizedError {
        case missingResource(String)

        var errorDescription: String? {
            switch self {
            case .missingResource(let name):
                return "Couldn't find \(name).json in the app bundle."
            }
        }
    }

    func load() async throws -> [CatalogItem] {
        guard let url = bundle.url(forResource: resourceName, withExtension: "json") else {
            throw LoadError.missingResource(resourceName)
        }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode([CatalogItem].self, from: data)
    }
}

/// The catalog read model for the UI. Loads once from a `CatalogSource`, then
/// serves browse / filter / search synchronously off the in-memory list.
///
/// `@MainActor @Observable` so SwiftUI views can read `items` / `isLoaded`
/// reactively; like `RoomStore` it is a plain observable used on the main thread,
/// not an actor-isolated service with its own queue. It never mutates rooms —
/// placement (turning a `CatalogItem` into a `FurnitureFootprint`) goes through
/// `RoomStore`, keeping this read-only over the catalog.
@MainActor
@Observable
final class CatalogService {
    private(set) var items: [CatalogItem] = []
    private(set) var isLoaded = false
    /// Friendly, non-technical message when the catalog can't load (CLAUDE.md:
    /// errors are never blank or raw). `nil` while loading or on success.
    private(set) var loadError: String?

    private let source: CatalogSource

    init(source: CatalogSource = BundledCatalogSource()) {
        self.source = source
    }

    /// Load the catalog. Idempotent on success — a second call is a no-op once
    /// loaded — so views can call it freely in `.task`.
    func load() async {
        guard !isLoaded else { return }
        do {
            let loaded = try await source.load()
            // V1 only offers renter-safe items (CLAUDE.md ICP). Filtering here,
            // not in the JSON, keeps the bundled pack a plain product list.
            items = loaded.filter(\.isRemovable)
            isLoaded = true
            loadError = nil
        } catch {
            loadError = "We couldn't load the catalog. Pull to retry."
            items = []
        }
    }

    /// Items in a category, or all items when `category` is nil. In-stock items
    /// sort ahead of out-of-stock ones; ties keep the catalog's authored order.
    func items(in category: FurnitureCategory? = nil) -> [CatalogItem] {
        let base = category.map { c in items.filter { $0.category == c } } ?? items
        return base.sorted { lhs, rhs in lhs.inStock && !rhs.inStock }
    }

    /// Case-insensitive search over name, brand, and category display name.
    func search(_ query: String) -> [CatalogItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return items }
        let needle = trimmed.lowercased()
        return items.filter { item in
            item.name.lowercased().contains(needle)
                || item.brand.lowercased().contains(needle)
                || item.category.displayName.lowercased().contains(needle)
        }
    }

    /// The set of categories that actually have items, in `FurnitureCategory`
    /// declaration order — for building filter chips without empty buckets.
    var availableCategories: [FurnitureCategory] {
        FurnitureCategory.allCases.filter { category in
            items.contains { $0.category == category }
        }
    }
}
