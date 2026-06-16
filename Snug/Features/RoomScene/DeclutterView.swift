import SwiftUI

/// The de-clutter step: over the live PLAY diorama of the user's room, decide
/// what to clear out and what to keep. Kept pieces feed `FitService` as
/// obstacles (via `FurnitureFootprint.keptObstacles`); cleared pieces are hidden
/// but not deleted, so a decision is always reversible.
///
/// ## Scope note
/// This screen owns the de-clutter *decision* over the real diorama backdrop. The
/// in-scene interactive furniture boxes (built by `FurnitureEntityBuilder`, with
/// 3D tap-to-clear via RealityView targeted gestures) hang off extending
/// `RoomSceneController`'s hit-testing — wired on device where it can be verified.
/// The model contract here (`isKept` / `isCleared`) is the same either way.
struct DeclutterView: View {
    let room: RoomModel
    /// Called with the room whose `detectedFurniture` flags reflect the user's
    /// keep/clear choices. The caller persists it (via `RoomStore`).
    let onCommit: (RoomModel) -> Void

    @State private var items: [FurnitureFootprint]

    init(room: RoomModel, onCommit: @escaping (RoomModel) -> Void) {
        self.room = room
        self.onCommit = onCommit
        _items = State(initialValue: room.detectedFurniture)
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            RoomSceneView(room: room, mode: .play)
                .ignoresSafeArea()

            if items.isEmpty {
                emptyState
            } else {
                controlPanel
            }
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "sparkles")
                .font(.system(size: 40))
                .foregroundStyle(SnugTheme.sage)
            Text("No furniture detected")
                .font(.system(.title3, design: .rounded).weight(.bold))
                .foregroundStyle(SnugTheme.ink)
            Text("Your room’s a blank canvas — let’s start designing.")
                .font(.system(size: 16))
                .foregroundStyle(SnugTheme.subtle)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            doneButton(title: "Start designing")
                .padding(.horizontal, 24)
                .padding(.bottom, 28)
        }
        .frame(maxWidth: .infinity)
        .background(SnugTheme.background.opacity(0.95).ignoresSafeArea(edges: .bottom))
    }

    // MARK: - Control panel

    private var controlPanel: some View {
        VStack(spacing: 14) {
            HStack {
                Text("What’s staying?")
                    .font(.system(.headline, design: .rounded))
                    .foregroundStyle(SnugTheme.ink)
                Spacer()
                Text("\(keptCount) kept")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(SnugTheme.subtle)
            }

            ScrollView {
                VStack(spacing: 10) {
                    ForEach(items) { item in
                        itemRow(item)
                    }
                }
            }
            .frame(maxHeight: 280)

            HStack(spacing: 12) {
                bulkButton("Clear all", systemImage: "trash") { setAll(kept: false) }
                bulkButton("Keep all", systemImage: "checkmark.circle") { setAll(kept: true) }
            }

            doneButton(title: "Done")
        }
        .padding(20)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 28))
        .padding(16)
    }

    private func itemRow(_ item: FurnitureFootprint) -> some View {
        let isKept = item.isKept && !item.isCleared
        let isCleared = item.isCleared
        return HStack(spacing: 12) {
            Image(systemName: item.category.symbolName)
                .font(.system(size: 22))
                .foregroundStyle(isCleared ? SnugTheme.subtle : SnugTheme.clay)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.category.displayName)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(SnugTheme.ink)
                Text(subtitle(for: item))
                    .font(.system(size: 13))
                    .foregroundStyle(SnugTheme.subtle)
            }
            .strikethrough(isCleared, color: SnugTheme.subtle)

            Spacer()

            // Clear / Keep segmented choice.
            HStack(spacing: 6) {
                choiceChip("Clear", systemImage: "trash", active: isCleared) {
                    update(item) { $0.isCleared = true; $0.isKept = false }
                }
                choiceChip("Keep", systemImage: "checkmark", active: isKept) {
                    update(item) { $0.isKept = true; $0.isCleared = false }
                }
            }
        }
        .padding(.vertical, 6)
    }

    private func choiceChip(_ title: String, systemImage: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: {
            action()
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(active ? SnugTheme.clay.opacity(0.18) : SnugTheme.surface,
                            in: Capsule())
                .foregroundStyle(active ? SnugTheme.clay : SnugTheme.subtle)
        }
        .accessibilityLabel("\(title) this item")
        .accessibilityAddTraits(active ? .isSelected : [])
    }

    private func bulkButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 15, weight: .semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(SnugTheme.surface, in: Capsule())
                .foregroundStyle(SnugTheme.ink)
        }
    }

    private func doneButton(title: String) -> some View {
        Button {
            var updated = room
            updated.detectedFurniture = items
            onCommit(updated)
        } label: {
            Text(title)
                .font(.system(size: 17, weight: .semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 15)
                .background(SnugTheme.clay, in: Capsule())
                .foregroundStyle(.white)
        }
    }

    // MARK: - Mutation

    private var keptCount: Int { items.filter { $0.isKept && !$0.isCleared }.count }

    private func subtitle(for item: FurnitureFootprint) -> String {
        let w = Int((item.dimensions.x * 100).rounded())
        let d = Int((item.dimensions.y * 100).rounded())
        let confidence: String
        switch item.detectionConfidence {
        case .detected:  confidence = item.appearance.colorCategory.displayName
        case .estimated: confidence = "Estimated"
        case .manual:    confidence = "Added by you"
        }
        return "\(confidence) · \(w)×\(d) cm"
    }

    private func update(_ item: FurnitureFootprint, _ change: (inout FurnitureFootprint) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        withAnimation(SnugTheme.spring) { change(&items[index]) }
    }

    private func setAll(kept: Bool) {
        withAnimation(SnugTheme.spring) {
            for i in items.indices {
                items[i].isKept = kept
                items[i].isCleared = !kept
            }
        }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }
}
