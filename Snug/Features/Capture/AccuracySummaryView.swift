import SwiftUI

/// The running accuracy report: count, mean/max absolute error, and the
/// share of samples within 2/5/10 cm — overall and broken out by type.
/// These numbers ARE the Phase 0 gate (mean ≤ ~3 cm green light, > ~6–8 cm
/// pivot moment), and the CSV export is the take-home artifact.
struct AccuracySummaryView: View {
    @Environment(AccuracyStore.self) private var store
    @State private var shareItem: ShareItem?
    @State private var exportErrorMessage: String?

    var body: some View {
        Group {
            if store.samples.isEmpty {
                emptyState
            } else {
                summaryList
            }
        }
        .navigationTitle("Accuracy log")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $shareItem) { item in
            ShareSheet(items: [item.url])
        }
        .alert(
            "Export didn't work",
            isPresented: Binding(
                get: { exportErrorMessage != nil },
                set: { if !$0 { exportErrorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(exportErrorMessage ?? "")
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "ruler")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("No measurements yet")
                .font(.title3.bold())
            Text("After a scan, open “Log ground truth” and enter a few tape-measured walls. Every sample makes the fit check more honest.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .padding()
    }

    private var summaryList: some View {
        List {
            if let overall = store.summary() {
                summarySection("All measurements", summary: overall)
            }
            ForEach(AccuracyStore.MeasurementType.allCases) { type in
                if let summary = store.summary(for: type) {
                    summarySection("\(type.label)s", summary: summary)
                }
            }

            Section {
                Button {
                    do {
                        shareItem = ShareItem(url: try store.writeCSVForExport())
                    } catch {
                        exportErrorMessage = error.localizedDescription
                    }
                } label: {
                    Label("Export CSV", systemImage: "square.and.arrow.up")
                }
            } footer: {
                Text("One row per sample: scanned vs. measured, error in cm, and RoomPlan's confidence.")
            }

            samplesSection
        }
        .listStyle(.insetGrouped)
    }

    private func summarySection(_ title: String, summary: AccuracyStore.Summary) -> some View {
        Section(title) {
            LabeledContent("Samples", value: "\(summary.count)")
            LabeledContent(
                "Mean abs. error",
                value: SnugFormat.absoluteCentimeters(summary.meanAbsoluteErrorMeters)
            )
            LabeledContent(
                "Max abs. error",
                value: SnugFormat.absoluteCentimeters(summary.maxAbsoluteErrorMeters)
            )
            LabeledContent("Within 2 cm", value: SnugFormat.percent(summary.shareWithin2cm))
            LabeledContent("Within 5 cm", value: SnugFormat.percent(summary.shareWithin5cm))
            LabeledContent("Within 10 cm", value: SnugFormat.percent(summary.shareWithin10cm))
        }
    }

    private var samplesSection: some View {
        let sorted = store.samples.sorted { $0.loggedAt > $1.loggedAt }
        return Section("Samples (\(sorted.count))") {
            ForEach(sorted) { sample in
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(sample.type.label) — scanned \(SnugFormat.meters(sample.scannedMeters)), measured \(SnugFormat.meters(sample.measuredMeters))")
                    Text("Error \(SnugFormat.errorCentimeters(sample.errorMeters)) · confidence \(sample.confidence) · \(sample.loggedAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
            .onDelete { offsets in
                store.delete(ids: offsets.map { sorted[$0].id })
            }
        }
    }
}

#Preview {
    NavigationStack {
        AccuracySummaryView()
    }
    .environment(AccuracyStore())
}
