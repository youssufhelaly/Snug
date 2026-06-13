import SwiftUI

@main
struct SnugApp: App {
    /// Single shared accuracy log for the whole app, injected via the
    /// environment per CLAUDE.md's architecture rules. It owns the CSV of
    /// (scanned vs. tape-measured) samples that Phase 0 exists to collect.
    @State private var accuracyStore = AccuracyStore()

    var body: some Scene {
        WindowGroup {
            HomeView()
                .environment(accuracyStore)
        }
    }
}
