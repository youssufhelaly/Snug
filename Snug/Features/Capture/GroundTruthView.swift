import SwiftUI
import UIKit

/// The tape-measure screen. After a capture, pick a wall, the room diagonal,
/// or an opening, type in what the tape measure says, and the pair (captured
/// vs. measured) lands in the accuracy log. This is the data Phase 0 exists to
/// collect — and now it works for any capture method, since it reads the
/// shared `RoomModel` rather than RoomPlan output directly.
struct GroundTruthView: View {
    let room: RoomModel

    @Environment(AccuracyStore.self) private var store
    @State private var measurementType: AccuracyStore.MeasurementType = .wall
    @State private var selectedCandidateID: String?
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

            capturedSection

            if selectedCandidate != nil {
                Section("Tape measure") {
                    TextField("Measured length in centimeters", text: $measuredText)
                        .keyboardType(.decimalPad)
                        .focused($isMeasuredFieldFocused)
                        .accessibilityLabel("Measured length in centimeters")

                    if let measured = measuredMeters, let candidate = selectedCandidate {
                        LabeledContent(
                            "Difference",
                            value: SnugFormat.errorCentimeters(Double(candidate.capturedMeters) - measured)
                        )
                    }

                    Button("Log measurement") { logMeasurement() }
                        .disabled(measuredMeters == nil)
                }
            }

            loggedSection
        }
        .navigationTitle("Ground truth")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: measurementType) { selectedCandidateID = nil }
    }

    // MARK: - Sections

    @ViewBuilder
    private var capturedSection: some View {
        if candidates.isEmpty {
            Section("Captured value") {
                Text("This room has no \(measurementType.label.lowercased())s to compare against. Try another type.")
                    .foregroundStyle(.secondary)
            }
        } else {
            Section("Captured value") {
                if candidates.count > 1 {
                    Picker("Element", selection: selectionBinding) {
                        ForEach(candidates) { candidate in
                            Text(candidate.label).tag(Optional(candidate.id))
                        }
                    }
                }
                if let candidate = selectedCandidate {
                    LabeledContent("Captured", value: SnugFormat.meters(candidate.capturedMeters))
                    LabeledContent("Method", value: methodLabel)
                }
            }
        }
    }

    @ViewBuilder
    private var loggedSection: some View {
        let roomSamples = store.samples(forRoom: room.id)
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

    private struct Candidate: Identifiable {
        let id: String
        let label: String
        let capturedMeters: Float
    }

    private var candidates: [Candidate] {
        switch measurementType {
        case .wall:
            return room.walls.map { wall in
                Candidate(
                    id: "wall-\(wall.id)",
                    label: "Wall \(wall.id + 1) — \(SnugFormat.meters(wall.length))",
                    capturedMeters: wall.length
                )
            }
        case .diagonal:
            guard room.floorCorners.count >= 2 else { return [] }
            return [Candidate(
                id: "diagonal",
                label: "Room diagonal — \(SnugFormat.meters(room.longestDiagonal))",
                capturedMeters: room.longestDiagonal
            )]
        case .opening:
            return room.openings.enumerated().map { index, opening in
                Candidate(
                    id: "opening-\(opening.id.uuidString)",
                    label: "\(opening.kind.label) \(index + 1) — \(SnugFormat.meters(opening.width)) wide",
                    capturedMeters: opening.width
                )
            }
        }
    }

    private var selectedCandidate: Candidate? {
        candidates.first { $0.id == selectedCandidateID } ?? candidates.first
    }

    private var selectionBinding: Binding<String?> {
        Binding(get: { selectedCandidate?.id }, set: { selectedCandidateID = $0 })
    }

    private var methodLabel: String {
        switch room.provenance {
        case .roomPlan: "LiDAR"
        case .manualAR: "Manual AR"
        }
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
        SnugFormat.meters(parsingCentimeters: measuredText)
    }

    private func logMeasurement() {
        guard let candidate = selectedCandidate, let measured = measuredMeters else { return }
        store.log(
            roomID: room.id,
            type: measurementType,
            scannedMeters: Double(candidate.capturedMeters),
            measuredMeters: measured,
            confidence: methodLabel
        )
        measuredText = ""
        isMeasuredFieldFocused = false
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }
}
