import SwiftUI
import RoomPlan
import UIKit

/// The tape-measure screen. After a scan, pick a wall, the room diagonal, or
/// an opening, type in what the tape measure says, and the pair (scanned vs.
/// measured) lands in the accuracy log. This is the data Phase 0 exists to
/// collect.
struct GroundTruthView: View {
    let record: ScanRecord

    @Environment(AccuracyStore.self) private var store
    @State private var measurementType: AccuracyStore.MeasurementType = .wall
    @State private var selectedCandidateID: UUID?
    @State private var measuredText = ""
    @FocusState private var isMeasuredFieldFocused: Bool

    var body: some View {
        Form {
            Section {
                Picker("What did you measure?", selection: $measurementType) {
                    ForEach(AccuracyStore.MeasurementType.allCases) { type in
                        Text(type.label).tag(type)
                    }
                }
                .pickerStyle(.segmented)
            } footer: {
                Text(typeHint)
            }

            scannedSection

            if selectedCandidate != nil {
                Section("Tape measure") {
                    TextField("Measured length in centimeters", text: $measuredText)
                        .keyboardType(.decimalPad)
                        .focused($isMeasuredFieldFocused)
                        .accessibilityLabel("Measured length in centimeters")

                    if let measured = measuredMeters, let candidate = selectedCandidate {
                        LabeledContent(
                            "Difference",
                            value: SnugFormat.errorCentimeters(candidate.scannedMeters - measured)
                        )
                    }

                    Button("Log measurement") {
                        logMeasurement()
                    }
                    .disabled(measuredMeters == nil)
                }
            }

            loggedSection
        }
        .navigationTitle("Ground truth")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: measurementType) {
            selectedCandidateID = nil
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var scannedSection: some View {
        if candidates.isEmpty {
            Section("Scanned value") {
                Text("This scan didn't detect any \(measurementType.label.lowercased())s to compare against. Try another type, or rescan.")
                    .foregroundStyle(.secondary)
            }
        } else {
            Section("Scanned value") {
                if candidates.count > 1 {
                    Picker("Element", selection: selectionBinding) {
                        ForEach(candidates) { candidate in
                            Text(candidate.label).tag(Optional(candidate.id))
                        }
                    }
                }
                if let candidate = selectedCandidate {
                    LabeledContent("Scanned", value: SnugFormat.meters(candidate.scannedMeters))
                    LabeledContent("Confidence", value: candidate.confidence)
                }
            }
        }
    }

    @ViewBuilder
    private var loggedSection: some View {
        let roomSamples = store.samples(forRoom: record.id)
        if !roomSamples.isEmpty {
            Section("Logged for this room") {
                ForEach(roomSamples) { sample in
                    SampleRow(sample: sample)
                }
                .onDelete { offsets in
                    store.delete(ids: offsets.map { roomSamples[$0].id })
                }
            }
        }
    }

    // MARK: - Candidates

    /// One selectable scanned element (a wall, the diagonal, or an opening).
    private struct Candidate: Identifiable {
        let id: UUID
        let label: String
        let scannedMeters: Double
        let confidence: String
    }

    private var candidates: [Candidate] {
        switch measurementType {
        case .wall:
            return record.room.walls.enumerated().map { index, wall in
                Candidate(
                    id: wall.identifier,
                    label: "Wall \(index + 1) — \(SnugFormat.meters(wall.dimensions.x))",
                    scannedMeters: Double(wall.dimensions.x),
                    confidence: wall.confidence.snugLabel
                )
            }
        case .diagonal:
            guard let diagonal = record.room.scannedDiagonalMeters else { return [] }
            // The record's own id doubles as a stable id for the single
            // synthetic "diagonal" candidate.
            return [
                Candidate(
                    id: record.id,
                    label: "Room diagonal — \(SnugFormat.meters(diagonal))",
                    scannedMeters: diagonal,
                    confidence: record.room.scannedDiagonalConfidence?.snugLabel ?? "Unknown"
                )
            ]
        case .opening:
            let groups: [(String, [CapturedRoom.Surface])] = [
                ("Door", record.room.doors),
                ("Window", record.room.windows),
                ("Opening", record.room.openings),
            ]
            return groups.flatMap { name, surfaces in
                surfaces.enumerated().map { index, surface in
                    Candidate(
                        id: surface.identifier,
                        label: "\(name) \(index + 1) — \(SnugFormat.meters(surface.dimensions.x)) wide",
                        scannedMeters: Double(surface.dimensions.x),
                        confidence: surface.confidence.snugLabel
                    )
                }
            }
        }
    }

    /// Falls back to the first candidate so the screen is usable without an
    /// explicit pick; the binding still tracks manual selections.
    private var selectedCandidate: Candidate? {
        candidates.first { $0.id == selectedCandidateID } ?? candidates.first
    }

    private var selectionBinding: Binding<UUID?> {
        Binding(
            get: { selectedCandidate?.id },
            set: { selectedCandidateID = $0 }
        )
    }

    private var typeHint: String {
        switch measurementType {
        case .wall:
            "Tape-measure the full length of one wall, baseboard to baseboard."
        case .diagonal:
            "Measure the floor corner to the opposite corner — diagonal error is the best proxy for fit accuracy."
        case .opening:
            "Measure the width of a door, window, or open passage."
        }
    }

    // MARK: - Logging

    private var measuredMeters: Double? {
        let normalized = measuredText.replacingOccurrences(of: ",", with: ".")
        guard let centimeters = Double(normalized), centimeters > 0 else { return nil }
        return centimeters / 100
    }

    private func logMeasurement() {
        guard let candidate = selectedCandidate, let measured = measuredMeters else { return }
        store.log(
            roomID: record.id,
            type: measurementType,
            scannedMeters: candidate.scannedMeters,
            measuredMeters: measured,
            confidence: candidate.confidence
        )
        measuredText = ""
        isMeasuredFieldFocused = false
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }
}
