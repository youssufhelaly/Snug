import SwiftUI

/// Home screen: pick a capture method and start. The AR-assisted "tap the
/// corners" method is the default (it runs on any modern iPhone); LiDAR is
/// offered as a higher-fidelity option only when the device supports it.
struct HomeView: View {
    @State private var activeCapture: ActiveCapture?

    private var methods: [any RoomCaptureMethod] { CaptureMethodRegistry.supported }

    var body: some View {
        NavigationStack {
            if methods.isEmpty {
                UnsupportedDeviceView()
            } else {
                supportedHome
            }
        }
    }

    private var supportedHome: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "camera.metering.matrix")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            Text("Snug")
                .font(.largeTitle.bold())

            Text("Measure your room, then see what really fits.")
                .font(.body)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            VStack(spacing: 12) {
                ForEach(methods, id: \.id) { method in
                    methodButton(method, isPrimary: method.id == methods.first?.id)
                }
            }
            .padding(.horizontal, 32)

            Spacer()

            NavigationLink {
                AccuracySummaryView()
            } label: {
                Label("Accuracy log", systemImage: "ruler")
            }
            .padding(.bottom, 16)
            .accessibilityHint("Shows captured versus tape-measured accuracy so far")
        }
        .padding()
        .toolbar(.hidden, for: .navigationBar)
        .fullScreenCover(item: $activeCapture) { active in
            RoomCaptureFlowView(method: active.method, onClose: { activeCapture = nil })
        }
    }

    @ViewBuilder
    private func methodButton(_ method: any RoomCaptureMethod, isPrimary: Bool) -> some View {
        Button {
            activeCapture = ActiveCapture(method: method)
        } label: {
            VStack(spacing: 2) {
                Text(isPrimary ? "Scan my room" : method.displayName)
                    .font(.headline)
                Text(method.summary)
                    .font(.caption)
                    .opacity(0.8)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
        }
        .buttonStyle(.borderedProminent)
        .tint(isPrimary ? .accentColor : .secondary)
        .accessibilityHint(isPrimary ? "Starts capturing your room" : "Capture using \(method.displayName)")
    }
}

/// Identifiable box so a chosen capture method can drive `.fullScreenCover`.
private struct ActiveCapture: Identifiable {
    let id = UUID()
    let method: any RoomCaptureMethod
}

/// Friendly dead-end for devices that support neither AR world tracking nor
/// LiDAR (very old hardware). Per CLAUDE.md: graceful and honest.
struct UnsupportedDeviceView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "iphone.slash")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            Text("This iPhone can't run Snug")
                .font(.title2.bold())

            Text("Snug measures rooms using AR, which needs a newer iPhone. This device doesn't support it — and we'd rather not guess at your room's size.")
                .font(.body)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
        }
        .padding()
    }
}

/// Walks one capture attempt through its life — capture → (failure | room) —
/// for any `RoomCaptureMethod`. The method supplies the capture UI; the rest
/// of the flow is identical regardless of how the room was measured.
struct RoomCaptureFlowView: View {
    let method: any RoomCaptureMethod
    let onClose: () -> Void

    enum FlowState {
        case capturing
        case failed(CaptureFailure)
        /// Drag-to-correct shape editing. Reached via the "Review layout" button
        /// on the result screen (the forced, conditional canvas is presented
        /// inside the manual-AR capture view itself).
        case correcting(RoomModel)
        case completed(RoomModel)
    }

    @State private var state: FlowState = .capturing

    var body: some View {
        switch state {
        case .capturing:
            method.makeCaptureView(
                onComplete: { room in state = afterCapture(room) },
                onFailure: { failure in state = .failed(failure) }
            )
        case .failed(let failure):
            CaptureFailureView(
                failure: failure,
                onRetry: { state = .capturing },
                onClose: onClose
            )
        case .correcting(let room):
            RoomShapeEditorView(
                room: room,
                onConfirm: { corrected in state = .completed(corrected) },
                onRecapture: { state = .capturing }
            )
        case .completed(let room):
            RoomModelReviewScreen(
                room: room,
                onDone: onClose,
                onRecapture: { state = .capturing },
                // Manual-AR rooms can always hop back into the drag editor;
                // confirming the shape is never a one-way door.
                onEditShape: room.provenance == .manualAR
                    ? { state = .correcting(room) }
                    : nil
            )
        }
    }

    /// Every capture now lands on the review screen. The manual-AR path decides
    /// *inside* its own capture view whether the drag-to-correct canvas is needed
    /// (high-wall projection used, floor never locked, or low-confidence ceiling)
    /// and presents it before completing, so the geometry arriving here is final.
    /// The `.correcting` state below is reused only for the "Review layout"
    /// re-open from the result screen.
    private func afterCapture(_ room: RoomModel) -> FlowState {
        .completed(room)
    }
}

#Preview {
    HomeView()
        .environment(AccuracyStore())
}
