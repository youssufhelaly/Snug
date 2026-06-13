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

    /// The date strategy fixtures are written and must be read with. Pinned so
    /// FitService tests decode `RoomModel` fixtures with a matching decoder
    /// (`JSONDecoder` defaults to `.deferredToDate`, which would fail on the
    /// ISO-8601 string we emit).
    static let fixtureDateStrategy: (
        encode: JSONEncoder.DateEncodingStrategy,
        decode: JSONDecoder.DateDecodingStrategy
    ) = (.iso8601, .iso8601)

    /// Serializes a `RoomModel` to JSON for sharing / as a test fixture. Works
    /// for every capture method, since `RoomModel` is the shared type. Like the
    /// `CapturedRoom` export, the fixture is round-trip verified before the
    /// share sheet opens — a fixture that can't re-import is worthless.
    static func exportFixture(for room: RoomModel) throws -> URL {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = fixtureDateStrategy.encode
        let data = try encoder.encode(room)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SnugRoomModel-\(room.id.uuidString).json")
        try data.write(to: url, options: .atomic)

        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = fixtureDateStrategy.decode
            _ = try decoder.decode(RoomModel.self, from: Data(contentsOf: url))
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw ExportError.fixtureVerificationFailed(underlying: error)
        }
        return url
    }
}
