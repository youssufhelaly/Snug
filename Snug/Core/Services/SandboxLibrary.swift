import Foundation
import Observation

/// Where Ideation-Sandbox shapes come from. The deliberate twin of `CatalogSource`
/// (real products), kept separate so the two tracks never share a loader, a file,
/// or a type — the isolation that keeps the Verified track a strict 1:1 zone.
protocol SandboxSource: Sendable {
    func load() async throws -> [SandboxAsset]
}

/// Loads sandbox shapes from the bundled `sandbox_assets.json`. Offline-first,
/// like `BundledCatalogSource` — generic CC0-style shapes ship in the app.
struct BundledSandboxSource: SandboxSource {
    let resourceName: String
    let bundle: Bundle

    init(resourceName: String = "sandbox_assets", bundle: Bundle = .main) {
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

    func load() async throws -> [SandboxAsset] {
        guard let url = bundle.url(forResource: resourceName, withExtension: "json") else {
            throw LoadError.missingResource(resourceName)
        }
        // Hop off the cooperative pool for the blocking file read — same shape as
        // `BundledCatalogSource`, correct once this moves behind a remote source.
        return try await Task.detached(priority: .userInitiated) {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode([SandboxAsset].self, from: data)
        }.value
    }
}

/// The read model for the Ideation Sandbox — the engagement/design playground.
/// Mirrors `CatalogService`'s shape (load once, serve synchronously, friendly
/// error copy) but over `SandboxAsset`. It never mutates rooms; placement goes
/// through `RoomStore` exactly like a catalog product.
@MainActor
@Observable
final class SandboxLibrary {
    private(set) var assets: [SandboxAsset] = []
    private(set) var isLoaded = false
    /// Friendly, non-technical message when the library can't load (CLAUDE.md:
    /// errors are never blank or raw). `nil` while loading or on success.
    private(set) var loadError: String?

    private let source: SandboxSource

    init(source: SandboxSource = BundledSandboxSource()) {
        self.source = source
    }

    /// Load the library. Idempotent on success — safe to call from `.task`.
    func load() async {
        guard !isLoaded else { return }
        do {
            assets = try await source.load()
            isLoaded = true
            loadError = nil
        } catch {
            loadError = "We couldn't load the design shapes. Close and try again."
            assets = []
        }
    }

    /// Assets in a category, or all when `category` is nil, in authored order.
    func assets(in category: FurnitureCategory? = nil) -> [SandboxAsset] {
        category.map { c in assets.filter { $0.category == c } } ?? assets
    }

    /// The categories that actually have shapes, in `FurnitureCategory`
    /// declaration order — for building filter chips without empty buckets.
    var availableCategories: [FurnitureCategory] {
        FurnitureCategory.allCases.filter { category in
            assets.contains { $0.category == category }
        }
    }
}
