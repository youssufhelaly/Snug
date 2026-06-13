import SwiftUI

/// One logged accuracy sample, rendered for a list. Shared by the
/// ground-truth screen and the accuracy summary so the two screens always
/// describe a sample — and its VoiceOver reading — identically.
struct SampleRow: View {
    let sample: AccuracyStore.Sample
    /// The summary screen shows when each sample was logged; the per-room
    /// ground-truth screen omits it (they're all from the current session).
    var showsDate: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(sample.type.label) — scanned \(SnugFormat.meters(sample.scannedMeters)), measured \(SnugFormat.meters(sample.measuredMeters))")
            Text(secondaryLine)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private var secondaryLine: String {
        var parts = [
            "Error \(SnugFormat.errorCentimeters(sample.errorMeters))",
            "confidence \(sample.confidence)",
        ]
        if showsDate {
            parts.append(sample.loggedAt.formatted(date: .abbreviated, time: .shortened))
        }
        return parts.joined(separator: " · ")
    }
}
