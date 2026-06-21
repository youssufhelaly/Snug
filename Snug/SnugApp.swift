import SwiftUI
import SwiftData

@main
struct SnugApp: App {
    /// The local SwiftData store, built from the native `VersionedSchema` so the
    /// model can evolve through migration stages later (CLAUDE.md).
    private let container: ModelContainer

    /// Single shared accuracy log for the whole app, injected via the
    /// environment per CLAUDE.md's architecture rules. It owns the CSV of
    /// (scanned vs. tape-measured) samples that Phase 0 exists to collect.
    @State private var accuracyStore = AccuracyStore()

    /// The room persistence service, the one writer of saved rooms.
    @State private var roomStore: RoomStore

    /// The bundled furniture catalog (BUY mode). Loaded once on launch; read-only
    /// over its items. Replaceable by a remote source later via `CatalogSource`.
    @State private var catalog = CatalogService()

    init() {
        let schema = Schema(versionedSchema: SnugSchemaV1.self)
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        do {
            container = try Self.makeContainer(schema: schema, configuration: configuration)
        } catch {
            // The on-disk store is incompatible with the current schema. Pre-release,
            // the V1 schema is still settling and we add no migration stage for a
            // dev-time storage change (e.g. flipping `thumbnailData` off
            // `.externalStorage`), so an old store can fail to load. Rather than
            // brick launch, recreate it once from scratch — there is no shipped data
            // and no cloud, so this is safe in V1. Logged loudly; never silent.
            print("⚠️ Snug: data store incompatible (\(error)). Recreating it fresh.")
            Self.destroyStore(at: configuration.url)
            do {
                container = try Self.makeContainer(schema: schema, configuration: configuration)
            } catch {
                fatalError("Could not create the Snug data store after reset: \(error)")
            }
        }
        _roomStore = State(initialValue: RoomStore(context: container.mainContext))
    }

    private static func makeContainer(schema: Schema, configuration: ModelConfiguration) throws -> ModelContainer {
        try ModelContainer(for: schema, migrationPlan: SnugMigrationPlan.self, configurations: [configuration])
    }

    /// Remove the SQLite store and its write-ahead-log siblings so a fresh one can
    /// be created. Used only after a load failure (the launch-blocking path).
    private static func destroyStore(at url: URL) {
        let fileManager = FileManager.default
        for path in [url.path, url.path + "-wal", url.path + "-shm"] {
            try? fileManager.removeItem(at: URL(fileURLWithPath: path))
        }
    }

    var body: some Scene {
        WindowGroup {
            MyRoomsView()
                .environment(accuracyStore)
                .environment(roomStore)
                .environment(catalog)
                .task { await catalog.load() }
        }
        .modelContainer(container)
    }
}
