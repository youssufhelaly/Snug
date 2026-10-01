import SwiftUI
import SwiftData
import os

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

    /// The bundled furniture catalog. Loaded once on launch; read-only
    /// over its items. Replaceable by a remote source later via `CatalogSource`.
    @State private var catalog = CatalogService()

    /// The bundled Ideation-Sandbox library (generic "digital clay" shapes). Loaded
    /// once on launch; isolated from the Verified `catalog` so the two tracks never
    /// share a source or a type. See `SandboxLibrary` / `sandbox_assets.json`.
    @State private var sandbox = SandboxLibrary()

    /// First-run gate. Shows the onboarding flow (value slides + camera primer)
    /// once, then the home. Re-triggerable from the home's More menu by flipping
    /// this back to `false`.
    @AppStorage("hasOnboarded") private var hasOnboarded = false

    /// True when the saved-rooms store couldn't be opened this launch and the app
    /// is running on a temporary in-memory store instead (release builds only).
    @State private var storeOpenFailed = false

    init() {
        let (container, openFailed) = Self.openStore()
        self.container = container
        _roomStore = State(initialValue: RoomStore(context: container.mainContext))
        _storeOpenFailed = State(initialValue: openFailed)
    }

    /// Opens the on-disk store. Returns the container plus whether it had to fall
    /// back to a temporary in-memory store (release builds only).
    private static func openStore() -> (ModelContainer, fellBack: Bool) {
        let schema = Schema(versionedSchema: SnugSchemaV1.self)
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        do {
            return (try makeContainer(schema: schema, configuration: configuration), false)
        } catch {
            #if DEBUG
            // The on-disk store is incompatible with the current schema. Pre-release,
            // the V1 schema is still settling and we add no migration stage for a
            // dev-time storage change (e.g. flipping `thumbnailData` off
            // `.externalStorage`), so an old store can fail to load. Rather than
            // brick launch, recreate it once from scratch — dev builds only carry
            // dev data. Logged loudly; never silent.
            SnugLog.persistence.error("Data store incompatible (\(String(describing: error), privacy: .public)). Recreating it fresh.")
            destroyStore(at: configuration.url)
            do {
                return (try makeContainer(schema: schema, configuration: configuration), false)
            } catch {
                fatalError("Could not create the Snug data store after reset: \(error)")
            }
            #else
            // NEVER auto-destroy a user's store in release: a container load
            // failure can also be transient (disk full, corruption in flight),
            // and wiping it here would delete every saved room. The files on disk
            // stay untouched and recoverable; this session runs on a temporary
            // in-memory store and the UI says so plainly, instead of crashing on
            // launch. A shipped schema change must land as a SnugMigrationPlan stage.
            SnugLog.persistence.fault("Could not open the data store: \(String(describing: error), privacy: .public). Using a temporary in-memory store.")
            let fallback = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
            do {
                return (try makeContainer(schema: schema, configuration: fallback), true)
            } catch {
                fatalError("Could not create even an in-memory Snug data store: \(error)")
            }
            #endif
        }
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
            Group {
                if hasOnboarded {
                    MyRoomsView()
                } else {
                    // Prime camera permission with context before the home (and
                    // its capture flow) can ever cold-prompt for it.
                    OnboardingFlow(onFinished: { hasOnboarded = true })
                }
            }
            .environment(accuracyStore)
            .environment(roomStore)
            .environment(catalog)
            .environment(sandbox)
            .task { await catalog.load() }
            .task { await sandbox.load() }
            .alert("Your saved rooms couldn't be opened", isPresented: $storeOpenFailed) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Your rooms are still on this iPhone. Close Snug completely and open it again. Until then, new rooms you scan won't be saved.")
            }
        }
        .modelContainer(container)
    }
}
