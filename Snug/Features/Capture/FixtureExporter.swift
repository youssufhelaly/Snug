import Foundation
import RoomPlan

/// Exports a scan as shareable files.
///
/// The JSON fixture is a real feature, not debug scaffolding: every future
/// FitService unit test runs against these serialized CapturedRooms, so each
/// export is round-trip verified (encode → write → read back → decode)
/// before the share sheet ever opens. A fixture that can't re-import is
/// worthless, and we'd rather fail loudly here than discover it in Phase 0.5.
enum FixtureExporter {
    enum ExportError: LocalizedError {
        case fixtureVerificationFailed(underlying: Error)

        var errorDescription: String? {
            switch self {
            case .fixtureVerificationFailed(let underlying):
                "The exported fixture failed its re-import check, so it was discarded: \(underlying.localizedDescription)"
            }
        }
    }

    /// Serializes the CapturedRoom to pretty-printed JSON, verifies the file
    /// decodes back into a CapturedRoom, and returns the file URL to share.
    static func exportFixture(for record: ScanRecord) throws -> URL {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(record.room)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SnugFixture-\(record.id.uuidString).json")
        try data.write(to: url, options: .atomic)

        do {
            let reread = try Data(contentsOf: url)
            _ = try JSONDecoder().decode(CapturedRoom.self, from: reread)
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw ExportError.fixtureVerificationFailed(underlying: error)
        }
        return url
    }

    /// Exports the room as a parametric USDZ for viewing in other tools.
    static func exportUSDZ(for record: ScanRecord) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SnugRoom-\(record.id.uuidString).usdz")
        try record.room.export(to: url, exportOptions: .parametric)
        return url
    }
}
