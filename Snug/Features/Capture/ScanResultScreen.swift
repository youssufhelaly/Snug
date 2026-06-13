import SwiftUI
import RoomPlan

/// Post-scan review: the gray orbitable 3D model up top, then the debug
/// panel — every detected surface and object with dimensions and RoomPlan's
/// confidence — plus the Phase 0 export and ground-truth tools.
struct ScanResultScreen: View {
    let record: ScanRecord
    let onDone: () -> Void
    let onRescan: () -> Void

    @State private var shareItem: ShareItem?
    @State private var exportErrorMessage: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                RoomModelView(room: record.room)
                    .frame(height: 300)
                    .accessibilityLabel("3D model of your scanned room")
                    .accessibilityHint("Drag to orbit, pinch to zoom")

                detailList
            }
            .navigationTitle("Your room")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Rescan", action: onRescan)
                        .accessibilityHint("Throws this scan away and starts a new one")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done", action: onDone)
                        .fontWeight(.semibold)
                }
            }
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
    }

    private var detailList: some View {
        List {
            Section("Export & ground truth") {
                Button {
                    export { try FixtureExporter.exportUSDZ(for: record) }
                } label: {
                    Label("Export USDZ", systemImage: "square.and.arrow.up")
                }
                Button {
                    export { try FixtureExporter.exportFixture(for: record) }
                } label: {
                    Label("Export test fixture (JSON)", systemImage: "doc.badge.gearshape")
                }
                NavigationLink {
                    GroundTruthView(record: record)
                } label: {
                    Label("Log ground truth", systemImage: "ruler")
                }
            }

            surfaceSection("Walls", surfaces: record.room.walls) { surface in
                "\(SnugFormat.meters(surface.dimensions.x)) wide × \(SnugFormat.meters(surface.dimensions.y)) tall"
            }
            surfaceSection("Doors", surfaces: record.room.doors) { surface in
                "\(SnugFormat.meters(surface.dimensions.x)) wide × \(SnugFormat.meters(surface.dimensions.y)) tall"
            }
            surfaceSection("Windows", surfaces: record.room.windows) { surface in
                "\(SnugFormat.meters(surface.dimensions.x)) wide × \(SnugFormat.meters(surface.dimensions.y)) tall"
            }
            surfaceSection("Openings", surfaces: record.room.openings) { surface in
                "\(SnugFormat.meters(surface.dimensions.x)) wide × \(SnugFormat.meters(surface.dimensions.y)) tall"
            }
            surfaceSection("Floor", surfaces: record.room.floors) { surface in
                "\(SnugFormat.meters(surface.dimensions.x)) × \(SnugFormat.meters(surface.dimensions.y)) footprint"
            }

            if !record.room.objects.isEmpty {
                Section("Objects") {
                    ForEach(Array(record.room.objects.enumerated()), id: \.element.identifier) { index, object in
                        row(
                            title: "\(index + 1). \(object.category.snugLabel)",
                            subtitle: "\(SnugFormat.meters(object.dimensions.x)) W × \(SnugFormat.meters(object.dimensions.y)) H × \(SnugFormat.meters(object.dimensions.z)) D",
                            confidence: object.confidence
                        )
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    @ViewBuilder
    private func surfaceSection(
        _ title: String,
        surfaces: [CapturedRoom.Surface],
        subtitle: @escaping (CapturedRoom.Surface) -> String
    ) -> some View {
        if !surfaces.isEmpty {
            Section(title) {
                ForEach(Array(surfaces.enumerated()), id: \.element.identifier) { index, surface in
                    row(
                        title: "\(title.hasSuffix("s") ? String(title.dropLast()) : title) \(index + 1)",
                        subtitle: subtitle(surface),
                        confidence: surface.confidence
                    )
                }
            }
        }
    }

    private func row(
        title: String,
        subtitle: String,
        confidence: CapturedRoom.Confidence
    ) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            ConfidenceBadge(confidence: confidence)
        }
        .accessibilityElement(children: .combine)
    }

    private func export(_ makeFile: () throws -> URL) {
        do {
            shareItem = ShareItem(url: try makeFile())
        } catch {
            exportErrorMessage = error.localizedDescription
        }
    }
}

/// Small capsule surfacing RoomPlan's per-surface confidence — Phase 0 is
/// explicitly about seeing this data, so it sits on every row.
private struct ConfidenceBadge: View {
    let confidence: CapturedRoom.Confidence

    var body: some View {
        Text(confidence.snugLabel)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
            .accessibilityLabel("Confidence \(confidence.snugLabel)")
    }

    private var color: Color {
        switch confidence {
        case .high: .green
        case .medium: .orange
        case .low: .red
        @unknown default: .gray
        }
    }
}
