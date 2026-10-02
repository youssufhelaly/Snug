import SwiftUI
import SwiftData
import UIKit

/// The app home: the renter's saved rooms, newest first, with a prominent
/// "Scan my room" action. Tapping a room opens its 3D diorama; finishing a scan
/// saves the room and drops you straight into it.
struct MyRoomsView: View {
    @Environment(RoomStore.self) private var store
    @Environment(CatalogService.self) private var catalog
    @Query(sort: \StoredRoom.capturedAt, order: .reverse) private var rooms: [StoredRoom]

    /// Flipping this back to `false` re-shows the onboarding flow (value slides +
    /// camera primer). The gate itself lives in `SnugApp`.
    @AppStorage("hasOnboarded") private var hasOnboarded = false

    @State private var activeCapture: ActiveCapture?
    @State private var openRoom: StoredRoom?
    @State private var showMethodDialog = false
    @State private var roomPendingDelete: StoredRoom?
    @State private var roomPendingRename: StoredRoom?
    @State private var roomPendingDuplicate: StoredRoom?
    @State private var renameDraft = ""
    @State private var failedSave: FailedSave?
    @State private var deleteErrorMessage: String?
    @State private var renameErrorMessage: String?
    @State private var duplicateErrorMessage: String?
    /// Toggled on each scan-button tap purely to drive its tap haptic.
    @State private var scanTapped = false
    @State private var isCreatingSample = false
    @State private var showSampleError = false

    private var methods: [any RoomCaptureMethod] { CaptureMethodRegistry.supported }

    /// Whether to show the normal home rather than the unsupported-device page.
    /// The screenshot harness runs in the simulator, which has no AR, so it
    /// shows the home anyway; nothing there starts a capture.
    private var showsHome: Bool {
        #if DEBUG
        if ScreenshotHarness.isActive { return true }
        #endif
        return !methods.isEmpty
    }

    /// One wide card per row on a phone: a room is something you come back to,
    /// so its picture gets room to breathe.
    private let columns = [GridItem(.adaptive(minimum: 300), spacing: 18)]

    var body: some View {
        NavigationStack {
            Group {
                if !showsHome {
                    UnsupportedDeviceView()
                } else if rooms.isEmpty {
                    emptyState
                } else {
                    roomGrid
                }
            }
            .background(SnugTheme.background.ignoresSafeArea())
            .navigationTitle("My rooms")
            .toolbar { toolbarContent }
            #if DEBUG
            .task { await runScreenshotHarness() }
            #endif
            .navigationDestination(item: $openRoom) { stored in
                RoomDioramaScreen(stored: stored)
            }
            .sheet(item: $roomPendingDuplicate) { stored in
                DuplicateRoomSheet(
                    furniture: activeFurniture(of: stored),
                    onDuplicate: { ids in duplicate(stored, keeping: ids) }
                )
            }
            .safeAreaInset(edge: .bottom) {
                if showsHome && !rooms.isEmpty {
                    scanButton.padding()
                }
            }
        }
        .tint(SnugTheme.clay)
        .fullScreenCover(item: $activeCapture) { active in
            RoomCaptureFlowView(
                method: active.method,
                onComplete: { room in handleCaptured(room) },
                onClose: { activeCapture = nil }
            )
        }
        .confirmationDialog("Choose a capture method", isPresented: $showMethodDialog, titleVisibility: .visible) {
            ForEach(methods, id: \.id) { method in
                Button(method.displayName) { startCapture(method) }
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(
            "Delete this room?",
            isPresented: Binding(get: { roomPendingDelete != nil }, set: { if !$0 { roomPendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let room = roomPendingDelete {
                    do {
                        try store.delete(room)
                    } catch {
                        deleteErrorMessage = "We couldn't delete this room. Please try again."
                    }
                }
                roomPendingDelete = nil
            }
            Button("Cancel", role: .cancel) { roomPendingDelete = nil }
        } message: {
            Text("This removes the saved room from your device. It can't be undone.")
        }
        .alert(
            "Rename room",
            isPresented: Binding(get: { roomPendingRename != nil }, set: { if !$0 { roomPendingRename = nil } })
        ) {
            TextField("Room name", text: $renameDraft)
            Button("Save") {
                if let room = roomPendingRename {
                    do {
                        try store.rename(room, to: renameDraft)
                    } catch {
                        renameErrorMessage = "We couldn't save the new name. Please try again."
                    }
                }
                roomPendingRename = nil
            }
            Button("Cancel", role: .cancel) { roomPendingRename = nil }
        }
        .alert(
            "Couldn't save room",
            isPresented: Binding(get: { failedSave != nil }, set: { if !$0 { failedSave = nil } })
        ) {
            Button("Try Again") {
                guard let room = failedSave?.room else { return }
                failedSave = nil
                // Re-attempt on the next runloop tick so the alert fully
                // dismisses before a failure can re-present it.
                DispatchQueue.main.async { handleCaptured(room) }
            }
            Button("Discard", role: .destructive) { failedSave = nil }
        } message: {
            Text("We couldn't save this scan to your device. Try again, or discard it and rescan.")
        }
        .alert(
            "Couldn't delete room",
            isPresented: Binding(get: { deleteErrorMessage != nil }, set: { if !$0 { deleteErrorMessage = nil } })
        ) {
            Button("OK", role: .cancel) { deleteErrorMessage = nil }
        } message: {
            Text(deleteErrorMessage ?? "")
        }
        .alert(
            "Couldn't rename room",
            isPresented: Binding(get: { renameErrorMessage != nil }, set: { if !$0 { renameErrorMessage = nil } })
        ) {
            Button("OK", role: .cancel) { renameErrorMessage = nil }
        } message: {
            Text(renameErrorMessage ?? "")
        }
        .alert("Couldn't open the sample room", isPresented: $showSampleError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Please try again.")
        }
        .alert(
            "Couldn't duplicate room",
            isPresented: Binding(get: { duplicateErrorMessage != nil }, set: { if !$0 { duplicateErrorMessage = nil } })
        ) {
            Button("OK", role: .cancel) { duplicateErrorMessage = nil }
        } message: {
            Text(duplicateErrorMessage ?? "")
        }
    }

    // MARK: - Pieces

    /// The published privacy policy (also the URL given to App Store Connect).
    private static let privacyPolicyURL = URL(string: "https://youssufhelaly.github.io/Snug/privacy.html")!

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                // Measurement tools for the accuracy benchmark. Debug builds only,
                // so TestFlight and App Store users never see them.
                #if DEBUG
                NavigationLink {
                    AccuracySummaryView()
                } label: {
                    Label("Accuracy log", systemImage: "ruler")
                }
                NavigationLink {
                    FitDebugView(room: .fitHarnessSample)
                } label: {
                    Label("Fit harness (debug)", systemImage: "shippingbox")
                }
                Divider()
                #endif
                Button {
                    hasOnboarded = false
                } label: {
                    Label("Show intro again", systemImage: "sparkles")
                }
                Button {
                    Task { await addSampleRoom() }
                } label: {
                    Label("Add sample room", systemImage: "sparkles")
                }
                .disabled(isCreatingSample)
                Link(destination: Self.privacyPolicyURL) {
                    Label("Privacy policy", systemImage: "hand.raised")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .accessibilityLabel("More")
        }
    }

    private var roomGrid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(rooms) { stored in
                    Button {
                        openRoom = stored
                    } label: {
                        RoomCard(stored: stored)
                    }
                    .buttonStyle(PressableCardStyle())
                    .contextMenu {
                        Button {
                            renameDraft = stored.name
                            roomPendingRename = stored
                        } label: {
                            Label("Rename", systemImage: "pencil")
                        }
                        Button {
                            roomPendingDuplicate = stored
                        } label: {
                            Label("Duplicate", systemImage: "plus.square.on.square")
                        }
                        Button(role: .destructive) {
                            roomPendingDelete = stored
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }
            .padding(.horizontal)
            .padding(.top, 8)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 8)
            Image("SampleRoomHero")
                .resizable()
                .scaledToFit()
                .clipShape(.rect(cornerRadius: 32))
                .shadow(color: SnugTheme.clay.opacity(0.25), radius: 24, y: 12)
                .padding(.horizontal, 36)
                .accessibilityHidden(true)
            VStack(spacing: 10) {
                Text("See it in your room\nbefore you buy it")
                    .font(.system(.title, design: .rounded).weight(.bold))
                    .foregroundStyle(SnugTheme.ink)
                    .multilineTextAlignment(.center)
                Text("Scan a room, drop in real furniture at its true size, and get an honest fit check on every piece.")
                    .font(.body)
                    .foregroundStyle(SnugTheme.subtle)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 28)
            .padding(.horizontal, 32)
            Spacer(minLength: 16)
            VStack(spacing: 12) {
                scanButton
                sampleRoomButton
            }
            .padding(.horizontal)
        }
        .padding(.bottom, 24)
    }

    /// Opens a furnished example bedroom, so the core loop (place, check fit,
    /// share, shop) can be tried in seconds before scanning anything.
    private var sampleRoomButton: some View {
        Button {
            Task { await addSampleRoom() }
        } label: {
            Label("Try a sample room", systemImage: "sparkles")
                .font(.headline)
                .foregroundStyle(SnugTheme.clay)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(SnugTheme.surface, in: .capsule)
                .overlay(Capsule().strokeBorder(SnugTheme.clay.opacity(0.25), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(isCreatingSample)
        .accessibilityHint("Opens an example bedroom with real furniture you can move around")
    }

    private var scanButton: some View {
        Button {
            scanTapped.toggle()
            if methods.count > 1 {
                showMethodDialog = true
            } else if let method = methods.first {
                startCapture(method)
            }
        } label: {
            Label("Scan my room", systemImage: "camera.viewfinder")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
        }
        .buttonStyle(.borderedProminent)
        .tint(SnugTheme.clay)
        .clipShape(Capsule())
        // Tap feedback fires declaratively off the toggle (iOS 17+).
        .sensoryFeedback(.impact(weight: .medium), trigger: scanTapped)
        .accessibilityHint("Starts capturing a new room")
    }

    // MARK: - Actions

    private func startCapture(_ method: any RoomCaptureMethod) {
        activeCapture = ActiveCapture(method: method)
    }

    /// The active (non-cleared) furniture offered when duplicating a room. Decodes
    /// the source blob once when the sheet is built.
    private func activeFurniture(of stored: StoredRoom) -> [FurnitureFootprint] {
        (stored.roomModel?.detectedFurniture ?? []).filter { !$0.isCleared }
    }

    /// Forks a room with the chosen furniture and drops straight into the copy,
    /// mirroring the finished-scan flow. The open is deferred to the next runloop
    /// tick so the duplicate sheet finishes dismissing before the push (otherwise
    /// SwiftUI can drop the navigation, same reason as the failed-save retry).
    private func duplicate(_ stored: StoredRoom, keeping ids: Set<UUID>) {
        do {
            let copy = try store.duplicate(stored, keepingFurnitureIDs: ids)
            DispatchQueue.main.async { openRoom = copy }
        } catch {
            duplicateErrorMessage = "We couldn't duplicate this room. Please try again."
        }
    }

    #if DEBUG
    /// Screenshot harness: seed the sample room, and open it for room screens.
    private func runScreenshotHarness() async {
        guard ScreenshotHarness.seedsSampleRoom, rooms.isEmpty else { return }
        await catalog.load()
        guard let stored = try? store.save(SampleRoom.make(catalog: catalog.items), name: SampleRoom.name) else { return }
        if ScreenshotHarness.opensSampleRoom { openRoom = stored }
    }
    #endif

    /// Saves a new furnished sample room and opens it. Waits for the catalog so
    /// the sample arrives furnished even on a cold launch.
    private func addSampleRoom() async {
        guard !isCreatingSample else { return }
        isCreatingSample = true
        defer { isCreatingSample = false }
        await catalog.load()
        do {
            let stored = try store.save(SampleRoom.make(catalog: catalog.items), name: SampleRoom.name)
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            openRoom = stored
        } catch {
            showSampleError = true
        }
    }

    /// A finished capture: persist it, dismiss the capture flow, and open the
    /// new room's diorama.
    private func handleCaptured(_ room: RoomModel) {
        do {
            let stored = try store.save(room)
            activeCapture = nil
            openRoom = stored
        } catch {
            // Don't silently drop a freshly scanned room. Dismiss the capture
            // flow and surface a retry path so the scan isn't lost without the
            // user's consent (honest > convenient — see CLAUDE.md hard rules).
            // Present the alert on the next tick so the full-screen cover has
            // finished dismissing first (otherwise SwiftUI can drop the alert).
            activeCapture = nil
            DispatchQueue.main.async { failedSave = FailedSave(room: room) }
        }
    }
}

/// One room card: a wide picture of the room, its name, and what's in it.
private struct RoomCard: View {
    let stored: StoredRoom

    /// "4 pieces · 10.8 m²", decoded off the body so scrolling stays cheap.
    @State private var details: String?
    @State private var isSample = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // A fixed-shape frame the picture fills; a fill-scaled image would
            // otherwise grow the frame to its own (square) shape.
            Color.clear
                .aspectRatio(16.0 / 10.0, contentMode: .fit)
                .overlay { RoomThumbnail(stored: stored) }
                .clipShape(.rect(cornerRadius: 20))

            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(stored.name)
                        .font(.system(.title3, design: .rounded).weight(.bold))
                        .foregroundStyle(SnugTheme.ink)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(SnugTheme.subtle)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                if isSample {
                    Text("Sample")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(SnugTheme.clay)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(SnugTheme.clay.opacity(0.12), in: .capsule)
                }
            }
            .padding(.horizontal, 6)
        }
        .padding(10)
        .padding(.bottom, 6)
        .background(SnugTheme.surface, in: .rect(cornerRadius: 28))
        // The picture sits over a transparent spacer, which doesn't take taps on
        // its own; make the whole card the button's hit area.
        .contentShape(.rect(cornerRadius: 28))
        .shadow(color: .black.opacity(0.05), radius: 12, y: 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(isSample ? "\(stored.name), sample room" : stored.name)
        .accessibilityValue(subtitle)
        .task(id: stored.roomData) { loadDetails() }
    }

    private var subtitle: String {
        let date = stored.capturedAt.formatted(.dateTime.month().day())
        guard let details else { return date }
        return "\(details) · \(date)"
    }

    private func loadDetails() {
        guard let room = stored.roomModel else { return }
        let pieces = room.detectedFurniture.filter { !$0.isCleared }.count
        let area = room.floorArea.formatted(.number.precision(.fractionLength(1)))
        details = pieces == 0 ? "\(area) m²" : "\(pieces) \(pieces == 1 ? "piece" : "pieces") · \(area) m²"
        isSample = room.provenance == .sample
    }
}

/// Press feedback for a tappable card: it dips slightly under the finger and
/// springs back, so a tap feels answered immediately even while the next
/// screen is still building.
private struct PressableCardStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.92 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
            .sensoryFeedback(.impact(weight: .light), trigger: configuration.isPressed) { _, pressed in pressed }
    }
}

/// Identifiable box so a chosen capture method can drive `.fullScreenCover`.
private struct ActiveCapture: Identifiable {
    let id = UUID()
    let method: any RoomCaptureMethod
}

/// Holds a freshly captured room whose save failed, so the user can retry or
/// discard instead of losing the scan silently.
private struct FailedSave: Identifiable {
    let id = UUID()
    let room: RoomModel
}
