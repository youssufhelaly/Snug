import SwiftUI
import simd

/// Compact precision editor for the selected furniture piece — the fallback for
/// when direct drag/pinch isn't precise enough. Presented as a ≤40%-height sheet
/// so the diorama stays visible above it. Four sliders only (no position X/Z —
/// position is the drag gesture's job). Sliders are the single source of truth:
/// they mutate the shared `footprints` binding directly, so the 3D entity updates
/// live through the same path as drag/pinch. There's no "Done"; the sheet is
/// dismissed by swiping down, and changes are persisted via `onCommit` on dismiss.
struct FineTuneSheet: View {
    @Binding var footprints: [FurnitureFootprint]
    let footprintID: UUID
    /// Persist the current footprints (called when the sheet disappears).
    let onCommit: () -> Void

    private let haptic = UIImpactFeedbackGenerator(style: .light)

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let footprint = selected {
                Label(footprint.category.displayName, systemImage: footprint.category.symbolName)
                    .font(.system(.headline, design: .rounded))
                    .foregroundStyle(SnugTheme.ink)
            }
            slider("Width", value: dimensionBinding(\.x), range: 0.30...3.50, step: 0.05, unit: "m")
            slider("Depth", value: dimensionBinding(\.y), range: 0.30...2.50, step: 0.05, unit: "m")
            slider("Height", value: dimensionBinding(\.z), range: 0.30...2.50, step: 0.05, unit: "m")
            Divider()
            slider("Rotation", value: rotationDegreesBinding, range: -180...180, step: 5, unit: "°")
            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .presentationDetents([.fraction(0.4)])
        .presentationDragIndicator(.visible)
        .onDisappear { onCommit() }
    }

    private func slider(_ label: String, value: Binding<Float>,
                        range: ClosedRange<Float>, step: Float, unit: String) -> some View {
        VStack(spacing: 2) {
            HStack {
                Text(label)
                    .font(.system(size: 14, design: .rounded))
                    .foregroundStyle(SnugTheme.ink)
                Spacer()
                Text(unit == "°" ? "\(Int(value.wrappedValue))°" : String(format: "%.2f %@", value.wrappedValue, unit))
                    .font(.system(size: 14).monospacedDigit())
                    .foregroundStyle(SnugTheme.subtle)
            }
            Slider(value: value, in: range, step: step) { editing in
                if editing { haptic.prepare() }
                haptic.impactOccurred()
            }
            .tint(SnugTheme.clay)
        }
    }

    // MARK: - Bindings (mutate the selected footprint directly)

    private var selected: FurnitureFootprint? { footprints.first { $0.id == footprintID } }

    private func dimensionBinding(_ axis: WritableKeyPath<SIMD3<Float>, Float>) -> Binding<Float> {
        Binding(
            get: { selected?.dimensions[keyPath: axis] ?? 0 },
            set: { newValue in mutate { $0.dimensions[keyPath: axis] = newValue } }
        )
    }

    private var rotationDegreesBinding: Binding<Float> {
        Binding(
            get: { (selected?.yRotation ?? 0) * 180 / .pi },
            set: { newValue in mutate { $0.yRotation = newValue * .pi / 180 } }
        )
    }

    private func mutate(_ change: (inout FurnitureFootprint) -> Void) {
        guard let index = footprints.firstIndex(where: { $0.id == footprintID }) else { return }
        change(&footprints[index])
    }
}
