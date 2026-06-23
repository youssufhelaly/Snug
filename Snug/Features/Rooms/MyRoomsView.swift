import SwiftUI
import SwiftData
import UIKit

/// The app home: the renter's saved rooms, newest first, with a prominent
/// "Scan my room" action. Tapping a room opens its 3D diorama; finishing a scan
/// saves the room and drops you straight into it.
struct MyRoomsView: View {
    @Environment(RoomStore.self) private var store
    @Query(sort: \StoredRoom.capturedAt, order: .reverse) private var rooms: [StoredRoom]

    /// Flipping this back to `false` re-shows the onboarding flow (value slides +
    /// camera primer). The gate itself lives in `SnugApp`.
    @AppStorage("hasOnboarded") private var hasOnboarded = false

    @State private var activeCapture: ActiveCapture?
    @State private var openRoom: StoredRoom?
    @State private var showMethodDialog = false
    @State private var roomPendingDelete: StoredRoom?
    @State private var roomPendingRename: StoredRoom?
    @State private var renameDraft = ""
    @State private var failedSave: FailedSave?
    @State private var deleteErrorMessage: String?
    /// Toggled on each scan-button tap purely to drive its tap haptic.
    @State private var scanTapped = false

    private var methods: [any RoomCaptureMethod] { CaptureMethodRegistry.supported }

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 16)]

    var body: some View {
        NavigationStack {
            Group {
                if methods.isEmpty {
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
            .navigationDestination(item: $openRoom) { stored in
                RoomDioramaScreen(stored: stored)
            }
            .safeAreaInset(edge: .bottom) {
                if !methods.isEmpty && !rooms.isEmpty {
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
                if let room = roomPendingRename { store.rename(room, to: renameDraft) }
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
    }

    // MARK: - Pieces

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
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
                Button {
                    hasOnboarded = false
                } label: {
                    Label("Show intro again", systemImage: "sparkles")
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
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button {
                            renameDraft = stored.name
                            roomPendingRename = stored
                        } label: {
                            Label("Rename", systemImage: "pencil")
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
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "house.and.flag")
                .font(.system(size: 56))
                .foregroundStyle(SnugTheme.sage)
                .accessibilityHidden(true)
            Text("No rooms yet")
                .font(.title2.weight(.bold))
                .foregroundStyle(SnugTheme.ink)
            Text("Scan your first room and watch it come to life as a cozy little world you can furnish.")
                .font(.body)
                .multilineTextAlignment(.center)
                .foregroundStyle(SnugTheme.subtle)
                .padding(.horizontal, 40)
            Spacer()
            scanButton.padding(.horizontal)
        }
        .padding(.bottom, 24)
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

/// One room tile: thumbnail, name, and a friendly size/date subtitle.
private struct RoomCard: View {
    let stored: StoredRoom

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            RoomThumbnail(stored: stored)
                .aspectRatio(4.0 / 3.0, contentMode: .fit)

            Text(stored.name)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(SnugTheme.ink)
                .lineLimit(1)

            Text(stored.capturedAt, format: .dateTime.month().day())
                .font(.caption)
                .foregroundStyle(SnugTheme.subtle)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(stored.name)
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
