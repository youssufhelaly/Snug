import SwiftUI
import simd

/// First-class fallback for adding existing furniture by hand — reached from the
/// detection step's Skip button, or whenever the model isn't available. Not an
/// error state (CLAUDE.md: manual picker is a first-class path).
///
/// The user taps category cards (each added at the currently-selected size), up
/// to a sensible cap, then confirms. Selections become `.manual`-confidence
/// `FurnitureFootprint`s spread across the room floor.
struct ManualFurniturePickerView: View {
    /// The room outline so manual pieces can be placed inside it.
    let roomCorners: [PlanePoint]
    /// Called with the built footprints (empty if the user adds nothing).
    let onComplete: ([FurnitureFootprint]) -> Void

    @Environment(\.dismiss) private var dismiss

    static let maxItems = 8

    /// Relative scale applied to a category's default dimensions.
    private enum Size: String, CaseIterable, Identifiable {
        case small = "Small", medium = "Medium", large = "Large"
        var id: String { rawValue }
        var multiplier: Float {
            switch self { case .small: 0.8; case .medium: 1.0; case .large: 1.2 }
        }
    }

    private struct Selection: Identifiable {
        let id = UUID()
        let category: FurnitureCategory
        let size: Size
    }

    @State private var size: Size = .medium
    @State private var selections: [Selection] = []

    private let columns = [GridItem(.flexible()), GridItem(.flexible())]
    private var pickableCategories: [FurnitureCategory] {
        FurnitureCategory.allCases.filter { $0 != .unknown }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Add your furniture")
                        .font(.system(.title2, design: .rounded).weight(.bold))
                        .foregroundStyle(SnugTheme.ink)

                    Picker("Size", selection: $size) {
                        ForEach(Size.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)

                    LazyVGrid(columns: columns, spacing: 14) {
                        ForEach(pickableCategories, id: \.self) { category in
                            categoryCard(category)
                        }
                    }

                    if !selections.isEmpty {
                        addedSection
                    }
                }
                .padding(20)
            }
            .background(SnugTheme.background.ignoresSafeArea())
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Skip") { finish(with: []) }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { finish(with: buildFootprints()) }
                        .fontWeight(.semibold)
                        .disabled(selections.isEmpty)
                }
            }
        }
    }

    private func categoryCard(_ category: FurnitureCategory) -> some View {
        Button {
            guard selections.count < Self.maxItems else { return }
            selections.append(Selection(category: category, size: size))
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        } label: {
            VStack(spacing: 8) {
                Image(systemName: category.symbolName)
                    .font(.system(size: 28))
                    .foregroundStyle(SnugTheme.clay)
                Text(category.displayName)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(SnugTheme.ink)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
            .background(SnugTheme.surface, in: RoundedRectangle(cornerRadius: 16))
        }
        .disabled(selections.count >= Self.maxItems)
        .opacity(selections.count >= Self.maxItems ? 0.5 : 1)
        .accessibilityLabel("Add \(category.displayName), \(size.rawValue)")
    }

    private var addedSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Added (\(selections.count)/\(Self.maxItems))")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(SnugTheme.subtle)
            ForEach(selections) { selection in
                HStack {
                    Image(systemName: selection.category.symbolName)
                        .foregroundStyle(SnugTheme.sage)
                    Text("\(selection.category.displayName) · \(selection.size.rawValue)")
                        .font(.system(size: 15))
                        .foregroundStyle(SnugTheme.ink)
                    Spacer()
                    Button {
                        selections.removeAll { $0.id == selection.id }
                    } label: {
                        Image(systemName: "minus.circle.fill").foregroundStyle(SnugTheme.subtle)
                    }
                    .accessibilityLabel("Remove \(selection.category.displayName)")
                }
                .padding(.vertical, 6)
            }
        }
    }

    // MARK: - Build

    private func finish(with footprints: [FurnitureFootprint]) {
        onComplete(footprints)
        dismiss()
    }

    /// Place each selection on the floor, fanned out around the room centroid so
    /// they don't all stack on one spot, each clamped inside the room polygon.
    private func buildFootprints() -> [FurnitureFootprint] {
        let cornersXZ = roomCorners.map(\.simd2)
        guard cornersXZ.count >= 3 else { return [] }
        let centroid = cornersXZ.reduce(SIMD2<Float>.zero, +) / Float(cornersXZ.count)

        return selections.enumerated().map { index, selection in
            let dims = selection.category.defaultDimensions * selection.size.multiplier
            let offset = gridOffset(for: index)
            let xz = FurniturePlacementService.clamped(centroid + offset, toRoom: cornersXZ)
            return FurnitureFootprint(
                category: selection.category,
                // Floor-relative Y (RoomModel floor = y=0); see FurniturePlacementService.
                worldPosition: SIMD3(xz.x, dims.z / 2, xz.y),
                dimensions: dims,
                yRotation: 0,
                appearance: FurnitureAppearance(colorCategory: .other,
                                                materialClass: .inferred(for: selection.category)),
                detectionConfidence: .manual
            )
        }
    }

    /// A small spiral/grid of offsets (meters) so up to 8 items spread out.
    private func gridOffset(for index: Int) -> SIMD2<Float> {
        let step: Float = 0.7
        let col = Float(index % 3) - 1   // -1, 0, 1
        let row = Float(index / 3) - 1   // -1, 0, 1 (for up to 9)
        return SIMD2(col * step, row * step)
    }
}
