import SwiftUI
import simd

/// Persistent bottom tray for arranging furniture over the diorama. Two states:
/// a category carousel (nothing selected) and transform controls (a piece
/// selected). It mutates the shared `footprints` binding directly — the sliders
/// are the single source of truth. Red/amber/green entity tinting is driven
/// reactively by the parent (which recomputes `PlacementState` from these
/// footprints), so the tray never touches RealityKit.
struct FurniturePlacementTray: View {
    @Binding var footprints: [FurnitureFootprint]
    let room: RoomModel
    @Binding var selectedFootprintID: UUID?

    static let maxItems = 8
    private static let categories: [FurnitureCategory] =
        [.sofa, .chair, .diningChair, .bed, .desk, .diningTable, .coffeeTable, .dresser, .bookshelf, .tvStand]

    private let haptic = UIImpactFeedbackGenerator(style: .light)

    var body: some View {
        VStack(spacing: 0) {
            if let footprint = selectedFootprint {
                transformControls(for: footprint)
            } else {
                carousel
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity)
        .background(.regularMaterial, in: UnevenRoundedRectangle(topLeadingRadius: 20, topTrailingRadius: 20))
        .animation(SnugTheme.spring, value: selectedFootprintID)
    }

    // MARK: - State A: carousel

    private var carousel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Add furniture")
                    .font(.system(.headline, design: .rounded))
                    .foregroundStyle(SnugTheme.ink)
                Spacer()
                if atLimit {
                    Text("Remove an item to add another")
                        .font(.system(size: 12))
                        .foregroundStyle(SnugTheme.subtle)
                }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(Self.categories, id: \.self) { category in
                        categoryCard(category)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    private func categoryCard(_ category: FurnitureCategory) -> some View {
        Button {
            add(category)
        } label: {
            VStack(spacing: 6) {
                Image(systemName: category.symbolName)
                    .font(.system(size: 24))
                    .foregroundStyle(SnugTheme.clay)
                Text(category.displayName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(SnugTheme.ink)
                    .lineLimit(1)
            }
            .frame(width: 80, height: 80)
            .background(SnugTheme.surface, in: RoundedRectangle(cornerRadius: 16))
        }
        .disabled(atLimit)
        .opacity(atLimit ? 0.4 : 1)
        .accessibilityLabel("Add \(category.displayName)")
    }

    // MARK: - State B: transform

    private func transformControls(for footprint: FurnitureFootprint) -> some View {
        VStack(spacing: 10) {
            HStack {
                Button { select(nil) } label: { Label("Back", systemImage: "chevron.left") }
                    .font(.system(size: 15, weight: .medium))
                Spacer()
                Label(footprint.category.displayName, systemImage: footprint.category.symbolName)
                    .font(.system(.headline, design: .rounded))
                    .foregroundStyle(SnugTheme.ink)
                Spacer()
                Button(role: .destructive) { remove(footprint) } label: { Label("Remove", systemImage: "trash") }
                    .font(.system(size: 15, weight: .medium))
            }
            .labelStyle(.titleAndIcon)

            slider("Width", systemImage: "arrow.left.and.right", value: dimensionBinding(\.x),
                   range: 0.3...3.5, step: 0.05, unit: "m")
            slider("Depth", systemImage: "arrow.up.and.down", value: dimensionBinding(\.y),
                   range: 0.3...2.5, step: 0.05, unit: "m")
            slider("Height", systemImage: "arrow.up.to.line", value: dimensionBinding(\.z),
                   range: 0.3...2.5, step: 0.05, unit: "m")

            slider("← Position →", systemImage: "arrow.left.and.right.square", value: positionBinding(\.x),
                   range: centroidX - 8...centroidX + 8, step: 0.05, unit: "m")
            slider("↑ Position ↓", systemImage: "arrow.up.and.down.square", value: positionBinding(\.z),
                   range: centroidZ - 8...centroidZ + 8, step: 0.05, unit: "m")
            slider("↻ Rotation", systemImage: "rotate.right", value: rotationDegreesBinding,
                   range: -180...180, step: 5, unit: "°")
        }
    }

    private func slider(_ label: String, systemImage: String, value: Binding<Float>,
                        range: ClosedRange<Float>, step: Float, unit: String) -> some View {
        VStack(spacing: 2) {
            HStack {
                Label(label, systemImage: systemImage)
                    .font(.system(size: 14, design: .rounded))
                    .foregroundStyle(SnugTheme.ink)
                Spacer()
                Text(unit == "°" ? "\(Int(value.wrappedValue))°" : String(format: "%.2f %@", value.wrappedValue, unit))
                    .font(.system(size: 14).monospacedDigit())
                    .foregroundStyle(SnugTheme.subtle)
            }
            Slider(value: value, in: range, step: step) { editing in
                // Haptic once per drag start/end — never 60×/sec.
                if editing { haptic.prepare() }
                haptic.impactOccurred()
            }
            .tint(SnugTheme.clay)
        }
    }

    // MARK: - Bindings (sliders are the source of truth — mutate footprints directly)

    private var selectedFootprint: FurnitureFootprint? {
        guard let id = selectedFootprintID else { return nil }
        return footprints.first { $0.id == id }
    }

    private func dimensionBinding(_ axis: WritableKeyPath<SIMD3<Float>, Float>) -> Binding<Float> {
        Binding(
            get: { selectedFootprint?.dimensions[keyPath: axis] ?? 0 },
            set: { newValue in mutateSelected { $0.dimensions[keyPath: axis] = newValue } }
        )
    }

    private func positionBinding(_ axis: WritableKeyPath<SIMD3<Float>, Float>) -> Binding<Float> {
        Binding(
            get: { selectedFootprint?.worldPosition[keyPath: axis] ?? 0 },
            set: { newValue in mutateSelected { $0.worldPosition[keyPath: axis] = newValue } }
        )
    }

    private var rotationDegreesBinding: Binding<Float> {
        Binding(
            get: { (selectedFootprint?.yRotation ?? 0) * 180 / .pi },
            set: { newValue in mutateSelected { $0.yRotation = newValue * .pi / 180 } }
        )
    }

    /// Apply an in-place change to the currently selected footprint.
    private func mutateSelected(_ change: (inout FurnitureFootprint) -> Void) {
        guard let id = selectedFootprintID,
              let index = footprints.firstIndex(where: { $0.id == id }) else { return }
        change(&footprints[index])
    }

    // MARK: - Actions

    private var activeCount: Int { footprints.filter { !$0.isCleared }.count }
    private var atLimit: Bool { activeCount >= Self.maxItems }

    private var roomCorners: [SIMD2<Float>] { room.floorCorners.map(\.simd2) }
    private var centroidX: Float { FurniturePlacementService.centroid(of: roomCorners).x }
    private var centroidZ: Float { FurniturePlacementService.centroid(of: roomCorners).y }

    private func add(_ category: FurnitureCategory) {
        guard !atLimit else { return }
        let dims = category.defaultDimensions
        let centroid = FurniturePlacementService.centroid(of: roomCorners)
        let xz = FurniturePlacementService().clampToBoundary(
            position: centroid,
            dimensions: SIMD2(dims.x, dims.y),
            rotation: 0,
            room: RoomFootprint(corners: roomCorners)
        )
        let footprint = FurnitureFootprint(
            category: category,
            worldPosition: SIMD3(xz.x, dims.z / 2, xz.y),
            dimensions: dims,
            yRotation: 0,
            appearance: FurnitureAppearance(colorCategory: .other, materialClass: .inferred(for: category)),
            detectionConfidence: .manual,
            isKept: true
        )
        footprints.append(footprint)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        select(footprint.id)
    }

    private func remove(_ footprint: FurnitureFootprint) {
        if let index = footprints.firstIndex(where: { $0.id == footprint.id }) {
            footprints[index].isCleared = true
        }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        select(nil)
    }

    private func select(_ id: UUID?) {
        withAnimation(SnugTheme.spring) { selectedFootprintID = id }
    }
}
