import SwiftUI
import UIKit
import simd

/// The room as a place: a full-screen RealityKit diorama with the always-visible
/// PLAY/BUY toggle and a spring "Reset view". This is the Phase 1 centerpiece —
/// where a scanned `RoomModel` stops being a floor plan and becomes a room.
struct RoomDioramaScreen: View {
    let stored: StoredRoom

    @Environment(RoomStore.self) private var store
    @Environment(CatalogService.self) private var catalog
    @Environment(\.openURL) private var openURL

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
    /// Presents the reverse-search sheet for the selected sandbox sketch.
    @State private var showMatchSheet = false
    /// Non-nil while the user is choosing which wall to snap the selected piece to
    /// (set when they tap "snap to wall"; cleared on the wall tap or Cancel).
    @State private var pickingWallForID: UUID?

    private var isPickingWall: Bool { pickingWallForID != nil }
    /// Debounces the SwiftData write while the user drags the sandbox `ColorPicker`,
    /// so a continuous color drag commits once it settles rather than per tick.
    @State private var colorPersistTask: Task<Void, Never>?

    /// Undo history for furniture edits ("undo last change"). Each entry is a full
    /// snapshot of `footprints` taken *before* a change commits, so popping one
    /// restores the prior layout. A full-array snapshot (rather than per-piece
    /// deltas) keeps every action — move, rotate, resize, snap, color, add, swap,
    /// trash — undoable through one path, and the arrays are small (≤8 pieces).
    @State private var undoStack: [[FurnitureFootprint]] = []
    /// Redo stack — the mirror of `undoStack`. An undo pushes the just-replaced
    /// layout here so it can be reapplied; any *new* edit clears it (a fresh change
    /// invalidates the redo timeline). Makes undo safe to experiment with.
    @State private var redoStack: [[FurnitureFootprint]] = []
    /// Coalesces a continuous edit (a color-wheel drag) into a single undo entry:
    /// repeated pushes with the same token after the first are no-ops until a
    /// differently-tokened (or untokened) change resets it.
    @State private var lastUndoToken: String?
    private static let maxUndoDepth = 24
    /// Layout captured when the Fine Tune sheet opens; its live sliders mutate
    /// `footprints` in place, so we record one undo entry on dismiss only if the
    /// layout actually changed.
    @State private var fineTuneSnapshot: [FurnitureFootprint]?

    /// Colorable parts of each placed sandbox clay model, reported by the scene once
    /// its USDZ loads (keyed by footprint id). Drives the per-part recolor chips.
    @State private var sandboxParts: [UUID: [FurnitureEntityBuilder.ColorablePart]] = [:]
    /// Which part of the selected clay piece the color row recolors. `nil` = the
    /// "All" chip (every part at once). Reset to "All" whenever the selection changes.
    @State private var selectedPartKey: String?
    /// Whether the sandbox recolor section is expanded on the inspector card. Hidden
    /// by default so the card stays short and doesn't cover the piece you selected;
    /// the "paint" tool in the action row toggles it. Reset on selection change.
    @State private var showRecolor = false

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

    /// Called when the Fine Tune sheet dismisses. Records a single undo entry (the
    /// layout as it was when the sheet opened) only if the sliders actually changed
    /// something, then persists.
    private func commitFineTune() {
        if let before = fineTuneSnapshot, before != footprints {
            undoStack.append(before)
            if undoStack.count > Self.maxUndoDepth { undoStack.removeFirst() }
            redoStack.removeAll()
            lastUndoToken = nil
        }
        fineTuneSnapshot = nil
        persistFurniture()
    }

    /// Snapshot the current layout onto the undo stack *before* a change is applied.
    /// Pass a `coalesce` token to fold a continuous gesture (e.g. a color-wheel drag)
    /// into one entry: the first push records, subsequent pushes with the same token
    /// are skipped until the next differently-tokened change. Discrete actions pass
    /// `nil`, which always records and clears the coalesce token.
    private func pushUndo(coalesce token: String? = nil) {
        if let token, token == lastUndoToken { return }
        undoStack.append(footprints)
        if undoStack.count > Self.maxUndoDepth { undoStack.removeFirst() }
        redoStack.removeAll()   // a new edit invalidates the redo timeline
        lastUndoToken = token
    }

    /// Revert the most recent furniture change (control-Z). Restores the prior
    /// layout, cancels any pending color write, keeps the selection valid, persists,
    /// and gives a haptic. No-op when there's nothing to undo.
    private func undoLastChange() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(footprints)   // current layout becomes the redo target
        restore(previous)
    }

    /// Reapply the change most recently undone (control-shift-Z). Mirror of
    /// `undoLastChange`: the popped redo layout becomes current, and the layout it
    /// replaces goes back onto the undo stack. No-op when there's nothing to redo.
    private func redoLastChange() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(footprints)
        restore(next)
    }

    /// Shared tail for undo/redo: swap in `layout`, cancel any pending color write,
    /// keep the selection valid, persist, and give a haptic. The undo/redo stacks
    /// themselves are managed by the callers (this must not clear them).
    private func restore(_ layout: [FurnitureFootprint]) {
        lastUndoToken = nil
        colorPersistTask?.cancel()
        footprints = layout
        if let id = selectedFurnitureID,
           !layout.contains(where: { $0.id == id && !$0.isCleared }) {
            selectedFurnitureID = nil
        }
        persistFurniture()
        UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
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
                        // Fires once per finished drag/resize/rotate gesture; the
                        // @State array still holds the pre-gesture layout here, so
                        // one snapshot = one undo entry for the whole gesture.
                        pushUndo()
                        footprints = updated
                        persistFurniture()
                    },
                    isPickingWall: isPickingWall,
                    onPickWallPoint: { snapSelected(toWallNear: $0) },
                    onSandboxParts: { id, parts in sandboxParts[id] = parts },
                    onSelectSandboxPart: { key in
                        selectedPartKey = key
                        UISelectionFeedbackGenerator().selectionChanged()
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
        .overlay(alignment: .bottom) { selectedItemOverlay }
        .overlay(alignment: .topTrailing) { toolCluster }
        .overlay(alignment: .bottom) { carousel }
        .overlay(alignment: .top) { limitToast }
        .overlay(alignment: .top) { wallPickBanner }
        .animation(Self.pillSpring, value: selectedFurnitureID)
        .animation(Self.pillSpring, value: showCarousel)
        .animation(Self.pillSpring, value: showLimitToast)
        .animation(Self.pillSpring, value: pickingWallForID)
        .animation(Self.pillSpring, value: undoStack.isEmpty)
        .animation(Self.pillSpring, value: redoStack.isEmpty)
        // A new selection starts on the "All" parts chip with recolor collapsed.
        .onChange(of: selectedFurnitureID) { selectedPartKey = nil; showRecolor = false }
        .sheet(isPresented: $showFineTune) {
            if let id = selectedFurnitureID {
                FineTuneSheet(footprints: $footprints, footprintID: id, onCommit: commitFineTune)
            }
        }
        .sheet(isPresented: $showMatchSheet) {
            if let room, let footprint = selectedFootprint {
                SandboxMatchSheet(
                    target: footprint.dimensions,
                    category: footprint.category,
                    room: room,
                    floorXZ: SIMD2(footprint.worldPosition.x, footprint.worldPosition.z),
                    yRotation: footprint.yRotation,
                    replacingID: footprint.id,
                    onPick: { swapToVerified($0) }
                )
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

    // MARK: - Selected furniture inspector (one glass card)

    /// One consolidated Liquid-Glass "inspector" for the selected piece, floating
    /// just above the bottom dock. It replaces the old stack of six separate
    /// floating capsules (sketch chip, fit badge, micro-pill, part chips, color
    /// row, find-real button) with a single card: header (icon · name · close),
    /// an honest fit line, an icon action row, then — by piece kind — the clay
    /// recolor section + "find real" bridge (sandbox) or the retailer out-link
    /// (catalog product).
    @ViewBuilder private var selectedItemOverlay: some View {
        if !showFineTune, !showCarousel, !showMatchSheet, !isPickingWall, let footprint = selectedFootprint {
            inspectorCard(footprint)
                .padding(.horizontal, 16)
                .padding(.bottom, 92)   // clears the bottom dock
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private func inspectorCard(_ footprint: FurnitureFootprint) -> some View {
        let isSandbox = footprint.sandboxAssetID != nil
        return VStack(alignment: .leading, spacing: 12) {
            cardHeader(footprint, isSandbox: isSandbox)
            cardActionRow(footprint, isSandbox: isSandbox)
            // Color editing is the bulkiest section, so it's collapsed by default
            // (the "paint" tool reveals it) — keeps the card short so it doesn't
            // cover the piece you just selected.
            if isSandbox, showRecolor {
                sandboxColorControls(footprint)
            }
            if isSandbox {
                findRealButton
            } else if let item = catalogItem(for: footprint) {
                retailerLink(item)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 26))
        .accessibilityElement(children: .contain)
    }

    /// Card title row: the category glyph in a soft clay disc, the name (with the
    /// trust-boundary "Sketch" subtitle for sandbox pieces — CLAUDE.md: a sketch
    /// must never read as buyable), the compact fit chip, and a close button that
    /// deselects. Folding fit into the header keeps the whole card to a few rows.
    private func cardHeader(_ footprint: FurnitureFootprint, isSandbox: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: footprint.category.symbolName)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(SnugTheme.clay)
                .frame(width: 36, height: 36)
                .background(SnugTheme.clay.opacity(0.14), in: Circle())
            VStack(alignment: .leading, spacing: 1) {
                Text(footprint.category.displayName)
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundStyle(SnugTheme.ink)
                if isSandbox {
                    Text("Sketch · resize freely")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(SnugTheme.subtle)
                }
            }
            Spacer(minLength: 8)
            if let state = fitState(for: footprint) {
                fitChip(state)
            }
            Button { selectedFurnitureID = nil } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(SnugTheme.subtle)
                    .frame(width: 30, height: 30)
                    .background(SnugTheme.ink.opacity(0.06), in: Circle())
            }
            .accessibilityLabel("Deselect \(footprint.category.displayName)")
        }
    }

    /// The honest fit read as a compact header chip. Keeps the headline + state tint
    /// so "Too close to call" never reads as a green check (CLAUDE.md: honesty is the
    /// brand); the nudge detail is carried in the VoiceOver label.
    private func fitChip(_ state: FitResult.State) -> some View {
        HStack(spacing: 5) {
            Image(systemName: state.symbol)
                .font(.system(size: 12, weight: .bold))
            Text(state.headline)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .lineLimit(1)
        }
        .foregroundStyle(state.tint)
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(state.tint.opacity(0.14), in: Capsule())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(state.detail.isEmpty ? state.headline : "\(state.headline). \(state.detail)")
    }

    /// The per-piece tools as compact icon tiles: rotate · wall · fine-tune ·
    /// (paint, sandbox only) · remove. Icon-only keeps the row to one line so the
    /// card stays short. The paint tile toggles the recolor section.
    private func cardActionRow(_ footprint: FurnitureFootprint, isSandbox: Bool) -> some View {
        HStack(spacing: 8) {
            cardAction("rotate.right", label: "Rotate \(footprint.category.displayName) 90 degrees") {
                rotateSelected()
            }
            cardAction("arrow.up.to.line.compact", label: "Snap \(footprint.category.displayName) to nearest wall") {
                beginWallPick()
            }
            cardAction("slider.horizontal.3", label: "Fine tune size") {
                fineTuneSnapshot = footprints
                showFineTune = true
            }
            if isSandbox {
                cardAction("paintbrush.fill", isOn: showRecolor, label: "Recolor") {
                    withAnimation(Self.pillSpring) { showRecolor.toggle() }
                }
            }
            Spacer(minLength: 0)
            cardAction("trash", tint: SnugTheme.subtle, label: "Remove \(footprint.category.displayName)") {
                trashSelected()
            }
        }
    }

    /// One compact icon tile for the card's action row. `isOn` paints it as the
    /// active (filled-clay) state for toggles. Callers own their own haptics.
    private func cardAction(_ icon: String, isOn: Bool = false, tint: Color = SnugTheme.clay,
                            label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(isOn ? .white : tint)
                .frame(width: 42, height: 38)
                .background(isOn ? tint : tint.opacity(0.12), in: Capsule())
        }
        .accessibilityLabel(label)
        .accessibilityAddTraits(isOn ? [.isSelected, .isButton] : .isButton)
    }

    private var findRealButton: some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            showMatchSheet = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13, weight: .bold))
                Text("Find real furniture that fits")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 46)
            .background(SnugTheme.clay, in: Capsule())
        }
        .accessibilityHint("Lists real, buyable products that match this footprint")
    }

    // MARK: - Sandbox color editing

    /// The clay-recolor controls: a per-part chip row (only when the model has more
    /// than one part) above the swatch / wheel / "Original" row. Picking a part chip
    /// targets the color row at that part; "All" recolors every part at once — so a
    /// clay bed can keep its frame walnut while the mattress goes sage, just like the
    /// original asset's multi-color look.
    @ViewBuilder private func sandboxColorControls(_ footprint: FurnitureFootprint) -> some View {
        let parts = sandboxParts[footprint.id] ?? []
        // With ≤1 part there's nothing to pick — the row always means "whole piece".
        let target = parts.count > 1 ? selectedPartKey : nil
        VStack(spacing: 8) {
            if parts.count > 1 { sandboxPartChips(footprint, parts: parts) }
            sandboxColorRow(current: effectiveColor(footprint, key: target))
        }
    }

    /// "All" + one chip per model part, each showing the part's current color dot.
    private func sandboxPartChips(_ footprint: FurnitureFootprint,
                                  parts: [FurnitureEntityBuilder.ColorablePart]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                partChip(title: "All", dot: nil, isOn: selectedPartKey == nil) { selectedPartKey = nil }
                ForEach(parts, id: \.key) { part in
                    partChip(title: part.displayName,
                             dot: effectiveColor(footprint, key: part.key),
                             isOn: selectedPartKey == part.key) { selectedPartKey = part.key }
                }
            }
            .padding(.horizontal, 4)
        }
        .frame(maxWidth: 320)
    }

    private func partChip(title: String, dot: SIMD3<Float>?, isOn: Bool,
                          action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let dot {
                    Circle().fill(color(from: dot)).frame(width: 11, height: 11)
                        .overlay(Circle().stroke(.white.opacity(0.6), lineWidth: 0.5))
                }
                Text(title)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
            }
            .foregroundStyle(isOn ? .white : SnugTheme.ink)
            .padding(.horizontal, 12).frame(height: 30)
            .background(isOn ? SnugTheme.clay : SnugTheme.surface, in: Capsule())
        }
        .accessibilityLabel(title == "All" ? "All parts" : "\(title) part")
        .accessibilityAddTraits(isOn ? [.isSelected, .isButton] : .isButton)
    }

    /// The color currently shown for a recolor target: a specific part's color (or
    /// the legacy whole-piece color as a base), or — for "All" (`key == nil`) — the
    /// shared color iff every part matches, else nil (mixed → "Original" unselected).
    private func effectiveColor(_ footprint: FurnitureFootprint, key: String?) -> SIMD3<Float>? {
        let appearance = footprint.appearance
        if let key {
            return appearance.partColors?[key] ?? appearance.exactColorRGB
        }
        let keys = (sandboxParts[footprint.id] ?? []).map(\.key)
        if let parts = appearance.partColors, !keys.isEmpty {
            let first = parts[keys[0]]
            return keys.allSatisfy { parts[$0] == first } ? first : nil
        }
        return appearance.exactColorRGB
    }

    // MARK: - Sandbox color editing

    /// Curated furniture palette for recoloring a clay sketch. Ideation is a free
    /// design space (unlike a Verified product's fixed true color), so the user can
    /// repaint a shape; "Original" returns it to the library model's own colors.
    private static let sandboxSwatches: [SIMD3<Float>] = [
        SIMD3(0.95, 0.93, 0.88),   // cream
        SIMD3(0.30, 0.30, 0.32),   // charcoal
        SIMD3(0.45, 0.30, 0.20),   // walnut
        SIMD3(0.16, 0.22, 0.34),   // navy
        SIMD3(0.50, 0.62, 0.50),   // sage
        SIMD3(0.80, 0.45, 0.32),   // terracotta
    ]

    /// Swatches + an "Original" reset + a free-choice picker. `current` is the
    /// selected piece's chosen color (`nil` = the model's original library colors).
    private func sandboxColorRow(current: SIMD3<Float>?) -> some View {
        HStack(spacing: 8) {
            Button { setSandboxColor(nil) } label: {
                Text("Original")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(current == nil ? .white : SnugTheme.ink)
                    .padding(.horizontal, 10).frame(height: 28)
                    .background(current == nil ? SnugTheme.clay : SnugTheme.surface, in: Capsule())
            }
            .accessibilityLabel("Original colors")
            .accessibilityAddTraits(current == nil ? [.isSelected, .isButton] : .isButton)

            ForEach(Array(Self.sandboxSwatches.enumerated()), id: \.offset) { _, rgb in
                let selected = current == rgb
                Button { setSandboxColor(rgb) } label: {
                    Circle()
                        .fill(color(from: rgb))
                        .frame(width: 26, height: 26)
                        .overlay(Circle().stroke(.white.opacity(0.7), lineWidth: 1))
                        .overlay(Circle().stroke(SnugTheme.ink, lineWidth: selected ? 2.5 : 0))
                }
                .accessibilityLabel("Color swatch")
                .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
            }

            ColorPicker("", selection: customColorBinding, supportsOpacity: false)
                .labelsHidden()
                .frame(width: 28, height: 28)
                .accessibilityLabel("Custom color")
        }
    }

    /// Two-way bridge for the system `ColorPicker`. Reads the chosen color (a
    /// neutral placeholder while on "Original"), writes any picked color through.
    /// The setter is the LIVE path: it recolors in-memory every tick but debounces
    /// the disk write (the picker's `set` fires continuously during a wheel drag).
    private var customColorBinding: Binding<Color> {
        Binding(
            get: {
                guard let fp = selectedFootprint else { return SnugTheme.subtle }
                let parts = sandboxParts[fp.id] ?? []
                let target = parts.count > 1 ? selectedPartKey : nil
                return effectiveColor(fp, key: target).map(color(from:)) ?? SnugTheme.subtle
            },
            set: { setSandboxColorLive(rgb(from: $0)) }
        )
    }

    private func color(from rgb: SIMD3<Float>) -> Color {
        Color(red: Double(rgb.x), green: Double(rgb.y), blue: Double(rgb.z))
    }

    private func rgb(from color: Color) -> SIMD3<Float> {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a)
        return SIMD3(Float(r), Float(g), Float(b))
    }

    /// Set (or clear → original) the selected sandbox piece's color, then persist.
    /// The discrete path (swatch buttons + "Original"): one tap = one write + haptic.
    /// Cancels any pending live-drag write so it can't clobber this choice. The scene
    /// re-tints the clay model on the next sync.
    private func setSandboxColor(_ rgb: SIMD3<Float>?) {
        guard selectedFurnitureID != nil else { return }
        colorPersistTask?.cancel()
        pushUndo()
        mutateSandboxColor(rgb)
        persistFurniture()
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    /// Live path for the continuous `ColorPicker` drag: update the in-memory
    /// footprint every tick so the clay model recolors immediately, but DEBOUNCE
    /// the SwiftData persist (and skip the per-tick haptic) so a wheel drag commits
    /// once ~0.4s after it settles rather than hammering the disk every frame.
    private func setSandboxColorLive(_ rgb: SIMD3<Float>) {
        guard let id = selectedFurnitureID else { return }
        // Coalesce the whole wheel drag into one undo entry (token per piece);
        // the snapshot is taken before the first tick mutates the color.
        pushUndo(coalesce: "color-\(id.uuidString)")
        mutateSandboxColor(rgb)
        colorPersistTask?.cancel()
        colorPersistTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            persistFurniture()
            lastUndoToken = nil   // drag settled — next drag starts a fresh entry
        }
    }

    /// Apply `rgb` (`nil` = original) to the selected sandbox piece — to one part when
    /// a part chip is selected, else to every part. Writes `partColors` (per-part) and
    /// retires the legacy whole-piece `exactColorRGB`, migrating any existing base
    /// color into the per-part map first so a previously whole-tinted piece keeps its
    /// look. Mutation only; callers own persistence/undo/haptics.
    private func mutateSandboxColor(_ rgb: SIMD3<Float>?) {
        guard let id = selectedFurnitureID,
              let index = footprints.firstIndex(where: { $0.id == id }) else { return }
        let keys = (sandboxParts[id] ?? []).map(\.key)
        var appearance = footprints[index].appearance

        if let key = selectedPartKey, keys.contains(key) {
            // Per-part. Seed the map from any legacy whole-piece color first.
            var map = appearance.partColors ?? [:]
            if map.isEmpty, let base = appearance.exactColorRGB {
                for k in keys { map[k] = base }
            }
            appearance.exactColorRGB = nil
            if let rgb { map[key] = rgb } else { map.removeValue(forKey: key) }
            appearance.partColors = map.isEmpty ? nil : map
        } else if !keys.isEmpty {
            // "All", parts known: one color across every part (or fully original).
            appearance.exactColorRGB = nil
            if let rgb {
                appearance.partColors = Dictionary(uniqueKeysWithValues: keys.map { ($0, rgb) })
            } else {
                appearance.partColors = nil
            }
        } else {
            // "All", parts not loaded yet: legacy whole-piece color (the scene
            // applies it across every part once the model's parts resolve).
            appearance.partColors = nil
            appearance.exactColorRGB = rgb
        }
        footprints[index].appearance = appearance
    }

    /// The user-facing four-state fit result for a placed piece, against the room
    /// walls and every OTHER kept piece (it isn't its own obstacle).
    private func fitState(for footprint: FurnitureFootprint) -> FitResult.State? {
        guard let room else { return nil }
        return room.fitResult(for: footprint, excluding: footprint.id).state
    }

    /// The catalog product a footprint was placed from, if any (detected/manual
    /// pieces return nil and show no retailer link).
    private func catalogItem(for footprint: FurnitureFootprint) -> CatalogItem? {
        guard let id = footprint.catalogItemID else { return nil }
        return catalog.items.first { $0.id == id }
    }

    private func retailerLink(_ item: CatalogItem) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            openURL(item.outboundURL)
        } label: {
            HStack(spacing: 6) {
                Text("\(item.formattedPrice) · View at \(item.retailerName)")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 12, weight: .bold))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 46)
            .background(SnugTheme.clay, in: Capsule())
        }
        .accessibilityLabel("View \(item.name) at \(item.retailerName), \(item.formattedPrice)")
        .accessibilityHint("Opens the retailer's page. Snug may earn a commission.")
    }

    /// Rotate the selected piece a quarter-turn (90°) — the precise "snap to wall"
    /// complement to the free two-finger twist. Wraps into [0, 2π) and persists; the
    /// scene re-validates fit on the next sync.
    private func rotateSelected() {
        guard let id = selectedFurnitureID,
              let index = footprints.firstIndex(where: { $0.id == id }) else { return }
        let twoPi = Float.pi * 2
        pushUndo()
        footprints[index].yRotation = (footprints[index].yRotation + .pi / 2).truncatingRemainder(dividingBy: twoPi)
        persistFurniture()
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    /// Enter "tap the wall" mode for the selected piece. The actual snap happens in
    /// `snapSelected(toWallNear:)` once the user taps the floor toward a wall.
    private func beginWallPick() {
        guard selectedFurnitureID != nil else { return }
        pickingWallForID = selectedFurnitureID
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    /// Snap the selected piece flush against the wall nearest the tapped floor point,
    /// back to that wall (front into the room) — most furniture leans on a wall.
    /// `point` is a world (x, z). Fit re-validates on the next sync.
    private func snapSelected(toWallNear point: SIMD2<Float>) {
        defer { pickingWallForID = nil }
        guard let room, let id = selectedFurnitureID,
              let index = footprints.firstIndex(where: { $0.id == id }) else { return }
        let corners = room.floorCorners.map(\.simd2)
        let piece = footprints[index]
        let center = SIMD2(piece.worldPosition.x, piece.worldPosition.z)
        guard let wall = WallSnapService.nearestWallIndex(to: point, corners: corners),
              let snap = WallSnapService.snap(
                pieceCenter: center,
                width: piece.dimensions.x,
                depth: piece.dimensions.y,
                toWall: wall,
                corners: corners,
                isFree: { position, yaw in
                    // A slot is free when the piece, placed there, clears its
                    // neighbors and the room — the SAME check that drives the
                    // red/amber/green badge, so "free" never disagrees with it.
                    var candidate = piece
                    candidate.worldPosition = SIMD3(position.x, piece.worldPosition.y, position.y)
                    candidate.yRotation = yaw
                    return FurniturePlacementValidator.validate(
                        footprint: candidate, against: room, existingFootprints: footprints) != .invalid
                })
        else { return }
        pushUndo()
        // Keep the snapped, rotated box inside the room polygon.
        let clamped = FurniturePlacementService.clampToBoundary(
            position: snap.position,
            dimensions: SIMD2(piece.dimensions.x, piece.dimensions.y),
            rotation: snap.yRotation,
            room: RoomFootprint(corners: corners))
        footprints[index].worldPosition = SIMD3(clamped.x, piece.worldPosition.y, clamped.y)
        footprints[index].yRotation = snap.yRotation
        persistFurniture()
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    /// Top banner shown while choosing a wall: instruction + Cancel.
    @ViewBuilder private var wallPickBanner: some View {
        if isPickingWall {
            HStack(spacing: 10) {
                Image(systemName: "hand.tap")
                    .font(.system(size: 14, weight: .semibold))
                Text("Tap the wall to snap against")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                Button("Cancel") { pickingWallForID = nil }
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(SnugTheme.clay)
            }
            .foregroundStyle(SnugTheme.ink)
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(.regularMaterial, in: Capsule())
            .padding(.top, 12)
            .transition(.move(edge: .top).combined(with: .opacity))
            .accessibilityElement(children: .contain)
        }
    }

    private func trashSelected() {
        guard let id = selectedFurnitureID,
              let index = footprints.firstIndex(where: { $0.id == id }) else { return }
        pushUndo()
        footprints[index].isCleared = true
        selectedFurnitureID = nil
        persistFurniture()
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    // MARK: - Add furniture (carousel)

    @ViewBuilder private var carousel: some View {
        if showCarousel {
            CatalogBrowseOverlay(
                onSelect: { item in
                    addCatalogItem(item)
                    showCarousel = false
                },
                onSelectSandbox: { asset in
                    addSandboxAsset(asset)
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

    /// Drop a catalog product at the room centroid, clamped fully inside, select
    /// it, and persist. The product carries its real dimensions/color, so the
    /// footprint is `.detected` (standard fit margin) — see `makeFootprint`.
    private func addCatalogItem(_ item: CatalogItem) {
        guard let room else { return }
        let corners = room.floorCorners.map(\.simd2)
        let centroid = FurniturePlacementService.centroid(of: corners)
        let xz = FurniturePlacementService.clampToBoundary(
            position: centroid,
            dimensions: SIMD2(item.dimensions.x, item.dimensions.y),
            rotation: 0,
            room: RoomFootprint(corners: corners))
        let footprint = item.makeFootprint(at: xz)
        pushUndo()
        footprints.append(footprint)
        selectedFurnitureID = footprint.id
        persistFurniture()
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    /// Drop an Ideation-Sandbox shape (elastic "digital clay") at the room centroid.
    /// Same placement/clamp path as a catalog product, but it carries no price and
    /// renders as the stylized box — its `sandboxAssetID` routes the selection UI to
    /// the "find real matches" bridge instead of a retailer link.
    private func addSandboxAsset(_ asset: SandboxAsset) {
        guard let room else { return }
        let corners = room.floorCorners.map(\.simd2)
        let centroid = FurniturePlacementService.centroid(of: corners)
        let xz = FurniturePlacementService.clampToBoundary(
            position: centroid,
            dimensions: SIMD2(asset.baseDimensions.x, asset.baseDimensions.y),
            rotation: 0,
            room: RoomFootprint(corners: corners))
        let footprint = asset.makeFootprint(at: xz)
        pushUndo()
        footprints.append(footprint)
        selectedFurnitureID = footprint.id
        persistFurniture()
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    /// Replace the selected sandbox sketch with a real Verified product at the SAME
    /// spot and yaw. The product carries its TRUE dimensions/color (1:1, never the
    /// sketch's elastic size) — the moment it lands, it's an honest, buyable piece
    /// the standard fit/retailer path already handles.
    private func swapToVerified(_ item: CatalogItem) {
        guard let id = selectedFurnitureID,
              let index = footprints.firstIndex(where: { $0.id == id }) else { return }
        let old = footprints[index]
        let xz = SIMD2(old.worldPosition.x, old.worldPosition.z)
        let replacement = item.makeFootprint(at: xz, yRotation: old.yRotation)
        pushUndo()
        footprints[index] = replacement
        selectedFurnitureID = replacement.id
        persistFurniture()
        UINotificationFeedbackGenerator().notificationOccurred(.success)
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

    // MARK: - Bottom dock (always-visible chrome)

    /// The bottom dock holds only the two primary controls — the PLAY/BUY toggle on
    /// the leading edge and the Add FAB on the trailing edge — with a wide,
    /// touch-transparent gap between them so furniture in the lower scene stays
    /// tappable/draggable (the old full-width glass row swallowed those taps).
    /// Limiting it to two items guarantees it fits even a 375 pt iPhone SE — the
    /// earlier four-button row overflowed and clipped Add. The secondary
    /// undo/redo/reset tools live in `toolCluster` at the top-trailing corner.
    private var controls: some View {
        let busy = showCarousel || showFineTune
        return VStack {
            Spacer()
            HStack(spacing: 12) {
                RenderModeToggle(mode: $mode)
                Spacer(minLength: 8)
                addDockButton
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 20)
            .opacity(busy ? 0 : 1)
            .allowsHitTesting(!busy)
        }
    }

    /// undo · redo · reset grouped in one compact glass capsule, floated at the
    /// top-trailing corner (just under the nav bar) where it never collides with the
    /// selected-item card or the bottom dock and can't overflow a narrow phone.
    /// Undo/redo are always present and simply disable (dimmed) when their stack is
    /// empty, so the cluster never reflows and undo is always discoverable — the
    /// earlier complaint was that it hid behind the selected-item stack.
    @ViewBuilder private var toolCluster: some View {
        let busy = showCarousel || showFineTune
        GlassEffectContainer {
            HStack(spacing: 2) {
                toolButton("arrow.uturn.backward", label: "Undo last change",
                           hint: "Reverts the most recent furniture edit",
                           enabled: !undoStack.isEmpty, action: undoLastChange)
                toolButton("arrow.uturn.forward", label: "Redo",
                           hint: "Reapplies the change you just undid",
                           enabled: !redoStack.isEmpty, action: redoLastChange)
                toolButton("arrow.counterclockwise", label: "Reset view",
                           hint: "Recenters the camera on the room", enabled: true) {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    resetToken += 1
                }
            }
            .padding(.horizontal, 4)
            .frame(height: 46)
            .glassEffect(.regular, in: .capsule)
        }
        .padding(.trailing, 16)
        .padding(.top, 8)
        .opacity(busy ? 0 : 1)
        .allowsHitTesting(!busy)
    }

    private func toolButton(_ icon: String, label: String, hint: String,
                            enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(enabled ? SnugTheme.ink : SnugTheme.subtle.opacity(0.4))
                .frame(width: 40, height: 40)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(label)
        .accessibilityHint(hint)
    }

    /// The clay-tinted "add furniture" button at the dock's trailing edge.
    private var addDockButton: some View {
        Button(action: addTapped) {
            Image(systemName: "plus")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 56, height: 56)
        }
        .glassEffect(.regular.tint(SnugTheme.clay).interactive(), in: .circle)
        .accessibilityLabel("Add furniture")
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
        // Glass on the CONTAINER only (it isn't itself tappable, so no
        // `.interactive()` here — that rendered the pill as odd blobs); the
        // segments carry the tap + the sliding clay highlight.
        .glassEffect(.regular, in: .capsule)
        // Selection haptic fires declaratively on an actual mode switch (iOS 17+).
        .sensoryFeedback(.selection, trigger: mode)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Render mode")
    }

    private func segment(_ option: RoomRenderMode) -> some View {
        let isSelected = mode == option
        return Button {
            guard mode != option else { return }
            if reduceMotion {
                mode = option
            } else {
                withAnimation(SnugTheme.spring) { mode = option }
            }
        } label: {
            Label(option.title, systemImage: option.symbol)
                .font(.subheadline.weight(.semibold))
                .labelStyle(.titleAndIcon)
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
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
