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

    init() {
        let schema = Schema(versionedSchema: SnugSchemaV1.self)
        do {
            container = try ModelContainer(
                for: schema,
                migrationPlan: SnugMigrationPlan.self,
                configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)]
            )
        } catch {
            // A failed store is unrecoverable and would mean every room save
            // fails silently; fail loudly in development instead.
            fatalError("Could not create the Snug data store: \(error)")
        }
        _roomStore = State(initialValue: RoomStore(context: container.mainContext))
    }

    var body: some Scene {
        WindowGroup {
            MyRoomsView()
                .environment(accuracyStore)
                .environment(roomStore)
        }
        .modelContainer(container)
    }
}
