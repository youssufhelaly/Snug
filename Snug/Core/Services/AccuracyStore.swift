import Foundation
import Observation
import os

/// The running log of (scanned vs. tape-measured) accuracy samples — the
/// single most important dataset in Phase 0. Every sample records what
/// RoomPlan said, what the tape measure said, and the resulting error,
/// broken out by measurement type (wall length, room diagonal, opening
/// width). The summary it produces decides whether the whole product
/// thesis survives, and the exported CSV belongs in the investor data room.
///
/// Persistence is a single JSON file in Application Support; the dataset is
/// tiny (tens of rows), so everything is synchronous and simple.
@Observable
final class AccuracyStore {

    /// What was physically tape-measured. Diagonal error is the real proxy
    /// for the clearance accuracy FitService depends on — wall lengths can
    /// be right while corners are skewed.
    enum MeasurementType: String, Codable, CaseIterable, Identifiable {
        case wall
        case diagonal
        case opening

        var id: String { rawValue }

        var label: String {
            switch self {
            case .wall: "Wall"
            case .diagonal: "Diagonal"
            case .opening: "Opening"
            }
        }
    }

    /// One ground-truth measurement: a scanned value paired with the
    /// tape-measured real value for the same element.
    struct Sample: Codable, Identifiable, Equatable {
        let id: UUID
        let roomID: UUID
        let type: MeasurementType
        let scannedMeters: Double
        let measuredMeters: Double
        /// RoomPlan's confidence for the measured element, as a label
        /// ("High"/"Medium"/"Low"), so the CSV can correlate error with
        /// confidence.
        let confidence: String
        let loggedAt: Date

        /// Signed error: positive means the scan over-measured.
        var errorMeters: Double { scannedMeters - measuredMeters }
    }

    /// Aggregate error statistics over a set of samples. The "share within"
    /// buckets are the headline numbers for the Phase 0 go/no-go gate.
    struct Summary {
        let count: Int
        let meanAbsoluteErrorMeters: Double
        let maxAbsoluteErrorMeters: Double
        let shareWithin2cm: Double
        let shareWithin5cm: Double
        let shareWithin10cm: Double
    }

    private(set) var samples: [Sample] = []

    private let fileURL: URL
    private let logger = Logger(subsystem: "com.helaly.Snug", category: "AccuracyStore")

    /// - Parameter fileURL: Override for tests; defaults to a JSON file in
    ///   Application Support.
    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultFileURL
        load()
    }

    // MARK: - Logging

    func log(
        roomID: UUID,
        type: MeasurementType,
        scannedMeters: Double,
        measuredMeters: Double,
        confidence: String
    ) {
        let sample = Sample(
            id: UUID(),
            roomID: roomID,
            type: type,
            scannedMeters: scannedMeters,
            measuredMeters: measuredMeters,
            confidence: confidence,
            loggedAt: Date()
        )
        samples.append(sample)
        persist()
    }

    func delete(ids: [UUID]) {
        samples.removeAll { ids.contains($0.id) }
        persist()
    }

    /// Samples logged against one scan, newest first.
    func samples(forRoom roomID: UUID) -> [Sample] {
        samples
            .filter { $0.roomID == roomID }
            .sorted { $0.loggedAt > $1.loggedAt }
    }

    // MARK: - Statistics

    /// Summary over all samples, or over one measurement type only.
    /// Returns nil when there is nothing to summarize.
    func summary(for type: MeasurementType? = nil) -> Summary? {
        let filtered = type.map { t in samples.filter { $0.type == t } } ?? samples
        return Self.summary(of: filtered)
    }

    /// Pure aggregation, kept static so it is trivially unit-testable.
    static func summary(of samples: [Sample]) -> Summary? {
        guard !samples.isEmpty else { return nil }
        let absErrors = samples.map { abs($0.errorMeters) }
        let count = Double(absErrors.count)
        return Summary(
            count: absErrors.count,
            meanAbsoluteErrorMeters: absErrors.reduce(0, +) / count,
            maxAbsoluteErrorMeters: absErrors.max() ?? 0,
            shareWithin2cm: Double(absErrors.filter { $0 <= 0.02 }.count) / count,
            shareWithin5cm: Double(absErrors.filter { $0 <= 0.05 }.count) / count,
            shareWithin10cm: Double(absErrors.filter { $0 <= 0.10 }.count) / count
        )
    }

    // MARK: - CSV export

    /// The full log as CSV, one row per sample. Errors are in centimeters
    /// because that is the unit the go/no-go gate is written in.
    func csvString() -> String {
        let dateFormatter = ISO8601DateFormatter()
        var lines = ["logged_at,room_id,type,scanned_m,measured_m,error_cm,confidence"]
        for sample in samples.sorted(by: { $0.loggedAt < $1.loggedAt }) {
            lines.append(
                [
                    dateFormatter.string(from: sample.loggedAt),
                    sample.roomID.uuidString,
                    sample.type.rawValue,
                    String(format: "%.4f", sample.scannedMeters),
                    String(format: "%.4f", sample.measuredMeters),
                    String(format: "%.1f", sample.errorMeters * 100),
                    sample.confidence,
                ].joined(separator: ",")
            )
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Writes the CSV to a temporary file for the share sheet.
    ///
    /// The filename timestamp deliberately avoids colons: ISO8601's "HH:mm:ss"
    /// is fine in the iOS temp dir but gets mangled or rejected when the user
    /// saves the file to a destination that treats ":" as a path separator
    /// (Files, AirDrop to a Mac). This CSV is an investor-data-room artifact —
    /// it should arrive with a clean name.
    func writeCSVForExport() throws -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: Date())
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SnugAccuracy-\(stamp).csv")
        try csvString().write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - Persistence

    private static var defaultFileURL: URL {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        return support.appendingPathComponent("accuracy-log.json")
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            samples = try decoder.decode([Sample].self, from: data)
        } catch {
            // A corrupt log is a debug-data loss, not a user-facing failure;
            // start empty rather than crash, but make it visible in Console.
            logger.error("Failed to load accuracy log: \(error.localizedDescription)")
        }
    }

    private func persist() {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(samples).write(to: fileURL, options: .atomic)
        } catch {
            logger.error("Failed to persist accuracy log: \(error.localizedDescription)")
        }
    }
}
