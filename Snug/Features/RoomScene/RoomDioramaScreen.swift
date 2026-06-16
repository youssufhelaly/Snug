import SwiftUI
import UIKit
import simd

/// The room as a place: a full-screen RealityKit diorama with the always-visible
/// PLAY/BUY toggle and a spring "Reset view". This is the Phase 1 centerpiece —
/// where a scanned `RoomModel` stops being a floor plan and becomes a room.
struct RoomDioramaScreen: View {
    let stored: StoredRoom

    @Environment(RoomStore.self) private var store

    @State private var mode: RoomRenderMode = .play
    @State private var resetToken = 0
    @State private var showingRename = false
    @State private var nameDraft = ""

    /// The decoded geometry, cached for this view's lifetime. `stored.roomModel`
    /// decodes the JSON blob on every access, so we decode it once at init rather
    /// than on every `body` re-eval (mode toggle, reset, rename alert). The
    /// diorama never mutates geometry, so a one-time decode is correct.
    @State private var room: RoomModel?
    /// Editable furniture (live during placement; persisted on gesture end). Seeded
    /// from the saved room; the room view is now a persistent furniture canvas.
    @State private var footprints: [FurnitureFootprint] = []
    @State private var selectedFurnitureID: UUID?
    @State private var showFineTune = false
    @State private var showCarousel = false
    @State private var showLimitToast = false

    private static let pillSpring = Animation.spring(response: 0.3, dampingFraction: 0.85)
    private static let maxFurniture = 8

    private var activeFurnitureCount: Int { footprints.filter { !$0.isCleared }.count }

    private var selectedFootprint: FurnitureFootprint? {
        footprints.first { $0.id == selectedFurnitureID && !$0.isCleared }
    }

    init(stored: StoredRoom) {
        self.stored = stored
        let decoded = stored.roomModel
        _room = State(initialValue: decoded)
        _footprints = State(initialValue: decoded?.detectedFurniture ?? [])
    }

    /// Auto-save: write the current furniture into the stored room. Called on
    /// gesture end (drag/pinch/slider) — there is no "Done" step.
    private func persistFurniture() {
        guard var updated = room else { return }
        updated.detectedFurniture = footprints
        room = updated
        try? store.update(stored, with: updated)
    }

    /// Live fit classification per footprint (recomputed on edits, not per frame).
    private func placementStates(for room: RoomModel) -> [UUID: PlacementState] {
        var states: [UUID: PlacementState] = [:]
        for footprint in footprints where !footprint.isCleared {
            states[footprint.id] = FurniturePlacementValidator.validate(
                footprint: footprint, against: room, existingFootprints: footprints)
        }
        return states
    }

    var body: some View {
        ZStack {
            if let room {
                // The diorama's "void" backdrop. On the old ARView this was
                // `environment.background = .color(...)`; RealityView has no such
                // hook, so it lives here as a SwiftUI layer behind the scene and
                // cross-fades with the mode change (the scene renders transparent).
                Color(uiColor: RoomPalette.palette(for: mode).background)
                    .ignoresSafeArea()

                RoomSceneView(
                    room: room,
                    mode: mode,
                    resetToken: resetToken,
                    onThumbnail: { data in store.setThumbnail(data, for: stored) },
                    editableFurniture: footprints,
                    placementStates: placementStates(for: room),
                    selectedFurnitureID: selectedFurnitureID,
                    onSelectFurniture: { selectedFurnitureID = $0 },
                    onFurnitureChanged: { updated in
                        footprints = updated
                        persistFurniture()
                    }
                )
                .ignoresSafeArea()

                if RoomPalette.palette(for: mode).showsVignette {
                    vignette
                        .ignoresSafeArea()
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }

                controls
            } else {
                unreadableRoom
            }
        }
        .overlay(alignment: .bottom) { microPill }
        .overlay(alignment: .bottomTrailing) { addButton }
        .overlay(alignment: .bottom) { carousel }
        .overlay(alignment: .top) { limitToast }
        .animation(Self.pillSpring, value: selectedFurnitureID)
        .animation(Self.pillSpring, value: showCarousel)
        .animation(Self.pillSpring, value: showLimitToast)
        .sheet(isPresented: $showFineTune) {
            if let id = selectedFurnitureID {
                FineTuneSheet(footprints: $footprints, footprintID: id, onCommit: persistFurniture)
            }
        }
        .navigationTitle(stored.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        nameDraft = stored.name
                        showingRename = true
                    } label: {
                        Label("Rename room", systemImage: "pencil")
                    }
                    if let room {
                        NavigationLink {
                            FitDebugView(room: room)
                        } label: {
                            Label("Fit harness", systemImage: "shippingbox")
                        }
                        NavigationLink {
                            GroundTruthView(room: room)
                        } label: {
                            Label("Log ground truth", systemImage: "ruler")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("Room options")
            }
        }
        .alert("Rename room", isPresented: $showingRename) {
            TextField("Room name", text: $nameDraft)
            Button("Save") { store.rename(stored, to: nameDraft) }
            Button("Cancel", role: .cancel) {}
        }
    }

    // MARK: - Micro-pill (selected furniture)

    @ViewBuilder private var microPill: some View {
        if !showFineTune, !showCarousel, let footprint = selectedFootprint {
            FurnitureMicroPill(
                category: footprint.category,
                onFineTune: { showFineTune = true },
                onTrash: { trashSelected() }
            )
            .padding(.bottom, 120)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private func trashSelected() {
        guard let id = selectedFurnitureID,
              let index = footprints.firstIndex(where: { $0.id == id }) else { return }
        footprints[index].isCleared = true
        selectedFurnitureID = nil
        persistFurniture()
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    // MARK: - Add furniture (+ button + carousel)

    /// Always present in the diorama; hidden (not removed) while the carousel or
    /// Fine Tune sheet is open, so adding furniture is possible at any time.
    private var addButton: some View {
        let hidden = showCarousel || showFineTune
        return Button(action: addTapped) {
            Label("Add", systemImage: "plus")
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .padding(.horizontal, 20)
                .frame(height: 56)
                .background(SnugTheme.clay, in: Capsule())
        }
        .padding(.trailing, 20)
        .padding(.bottom, 88)   // above the reset button
        .opacity(hidden ? 0 : 1)
        .allowsHitTesting(!hidden)
        .accessibilityLabel("Add furniture")
    }

    @ViewBuilder private var carousel: some View {
        if showCarousel {
            FurnitureCarouselOverlay(
                onSelect: { category in
                    addFurniture(category)
                    showCarousel = false
                },
                onClose: { showCarousel = false }
            )
            .transition(.move(edge: .bottom))
        }
    }

    @ViewBuilder private var limitToast: some View {
        if showLimitToast {
            Text("Remove an item to add another")
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .foregroundStyle(SnugTheme.ink)
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(.regularMaterial, in: Capsule())
                .padding(.top, 12)
                .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    private func addTapped() {
        guard activeFurnitureCount < Self.maxFurniture else {
            showLimitToast = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { showLimitToast = false }
            return
        }
        selectedFurnitureID = nil   // hide the pill while the carousel is up
        showCarousel = true
    }

    /// Create a piece at the room centroid, clamped inside, select it, persist.
    private func addFurniture(_ category: FurnitureCategory) {
        guard let room else { return }
        let dims = category.defaultDimensions
        let corners = room.floorCorners.map(\.simd2)
        let centroid = FurniturePlacementService.centroid(of: corners)
        let xz = FurniturePlacementService().clampToBoundary(
            position: centroid, dimensions: SIMD2(dims.x, dims.y), rotation: 0,
            room: RoomFootprint(corners: corners))
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
        selectedFurnitureID = footprint.id
        persistFurniture()
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    // MARK: - Vignette (PLAY only)

    /// A soft corner vignette in the diorama's terracotta, deepening the cozy
    /// "looking into a box" feel. Pure SwiftUI — no RealityKit involvement. The
    /// tint comes from the PLAY palette background so the brand stays centralized.
    private var vignette: some View {
        GeometryReader { geo in
            let maxDim = max(geo.size.width, geo.size.height)
            RadialGradient(
                gradient: Gradient(colors: [
                    .clear,
                    Color(RoomPalette.palette(for: .play).background).opacity(0.12),
                ]),
                center: .center,
                startRadius: maxDim * 0.30,
                endRadius: maxDim * 0.82
            )
        }
    }

    // MARK: - Controls overlay

    private var controls: some View {
        VStack {
            Spacer()
            HStack(alignment: .bottom) {
                RenderModeToggle(mode: $mode)
                Spacer()
                resetButton
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
        }
    }

    private var resetButton: some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            resetToken += 1
        } label: {
            Image(systemName: "arrow.counterclockwise")
                .font(.system(size: 18, weight: .semibold))
                .padding(14)
                .background(.ultraThinMaterial, in: Circle())
                .foregroundStyle(SnugTheme.ink)
        }
        .accessibilityLabel("Reset view")
        .accessibilityHint("Recenters the camera on the room")
    }

    private var unreadableRoom: some View {
        ContentUnavailableView(
            "We couldn't open this room",
            systemImage: "exclamationmark.triangle",
            description: Text("The saved data looks damaged. Try scanning the room again.")
        )
    }
}

/// The always-visible, one-tap PLAY/BUY pill. A sliding highlight (spring,
/// reduced-motion aware) gives the brand bounce; the scene handles the < 400 ms
/// cross-fade. Haptic on every switch.
private struct RenderModeToggle: View {
    @Binding var mode: RoomRenderMode
    @Namespace private var highlight
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 4) {
            ForEach(RoomRenderMode.allCases) { option in
                segment(option)
            }
        }
        .padding(4)
        .background(.ultraThinMaterial, in: Capsule())
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Render mode")
    }

    private func segment(_ option: RoomRenderMode) -> some View {
        let isSelected = mode == option
        return Button {
            guard mode != option else { return }
            UIImpactFeedbackGenerator(style: .soft).impactOccurred()
            if reduceMotion {
                mode = option
            } else {
                withAnimation(SnugTheme.spring) { mode = option }
            }
        } label: {
            Label(option.title, systemImage: option.symbol)
                .font(.subheadline.weight(.semibold))
                .labelStyle(.titleAndIcon)
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .foregroundStyle(isSelected ? Color.white : SnugTheme.ink)
                .background {
                    if isSelected {
                        Capsule()
                            .fill(SnugTheme.clay)
                            .matchedGeometryEffect(id: "modeHighlight", in: highlight)
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
        .accessibilityHint(option == .buy ? "True-to-scale view with dimension labels" : "Playful stylized view")
    }
}
