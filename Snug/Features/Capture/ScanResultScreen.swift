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
    @State private var isExporting = false

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
            .exportPresentation(shareItem: $shareItem, errorMessage: $exportErrorMessage)
        }
    }

    private var detailList: some View {
        List {
            Section("Export & ground truth") {
                Button {
                    export { try FixtureExporter.exportUSDZ(for: record) }
                } label: {
                    exportLabel("Export USDZ", systemImage: "square.and.arrow.up")
                }
                .disabled(isExporting)
                Button {
                    export { try FixtureExporter.exportFixture(for: record) }
                } label: {
                    exportLabel("Export test fixture (JSON)", systemImage: "doc.badge.gearshape")
                }
                .disabled(isExporting)
                NavigationLink {
                    // Convert RoomPlan output into the shared RoomModel so the
                    // accuracy logger is identical across capture methods.
                    GroundTruthView(room: RoomModel(capturedRoom: record.room, id: record.id, capturedAt: record.capturedAt))
                } label: {
                    Label("Log ground truth", systemImage: "ruler")
                }
            }

            surfaceSection("Walls", singular: "Wall", surfaces: record.room.walls)
            surfaceSection("Doors", singular: "Door", surfaces: record.room.doors)
            surfaceSection("Windows", singular: "Window", surfaces: record.room.windows)
            surfaceSection("Openings", singular: "Opening", surfaces: record.room.openings)
            surfaceSection("Floor", singular: "Floor", surfaces: record.room.floors) { surface in
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

    /// `singular` is passed explicitly rather than derived by trimming an "s"
    /// off the section title — that string trick mislabels irregular plurals.
    /// `subtitle` defaults to the "W wide × H tall" form every surface but the
    /// floor uses.
    @ViewBuilder
    private func surfaceSection(
        _ title: String,
        singular: String,
        surfaces: [CapturedRoom.Surface],
        subtitle: @escaping (CapturedRoom.Surface) -> String = { surface in
            "\(SnugFormat.meters(surface.dimensions.x)) wide × \(SnugFormat.meters(surface.dimensions.y)) tall"
        }
    ) -> some View {
        if !surfaces.isEmpty {
            Section(title) {
                ForEach(Array(surfaces.enumerated()), id: \.element.identifier) { index, surface in
                    row(
                        title: "\(singular) \(index + 1)",
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

    /// A row label that swaps in a spinner while an export is running, so the
    /// (off-main) file work reads as "working," not "frozen."
    @ViewBuilder
    private func exportLabel(_ title: String, systemImage: String) -> some View {
        if isExporting {
            Label { Text(title) } icon: { ProgressView() }
        } else {
            Label(title, systemImage: systemImage)
        }
    }

    /// Runs file generation off the main thread (USDZ export and the fixture
    /// round-trip can take a noticeable beat on a large room — CLAUDE.md keeps
    /// RoomPlan/RealityKit work off-main), then presents the share sheet back
    /// on the main actor.
    private func export(_ makeFile: @escaping () throws -> URL) {
        guard !isExporting else { return }
        isExporting = true
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try makeFile() }
            DispatchQueue.main.async {
                isExporting = false
                switch result {
                case .success(let url): shareItem = ShareItem(url: url)
                case .failure(let error): exportErrorMessage = error.localizedDescription
                }
            }
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
