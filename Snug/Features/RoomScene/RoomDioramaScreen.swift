import SwiftUI
import UIKit

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

    init(stored: StoredRoom) {
        self.stored = stored
        _room = State(initialValue: stored.roomModel)
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
                    onThumbnail: { data in store.setThumbnail(data, for: stored) }
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
