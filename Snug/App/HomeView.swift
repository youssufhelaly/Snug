import SwiftUI
import RoomPlan

/// Phase-0 home screen: a capability gate, one big "Scan my room" button,
/// and a link to the running accuracy log. Deliberately plain — Phase 0 is
/// about proving the scan, not styling it.
struct HomeView: View {
    @State private var isScanFlowPresented = false

    /// `RoomCaptureSession.isSupported` is false on non-LiDAR devices and in
    /// the simulator. Checked once here so the unsupported path is a friendly
    /// screen, not a crash mid-capture.
    private var isRoomPlanSupported: Bool {
        RoomCaptureSession.isSupported
    }

    var body: some View {
        NavigationStack {
            if isRoomPlanSupported {
                supportedHome
            } else {
                UnsupportedDeviceView()
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

            Text("Scan your room with a slow 10-second sweep.\nWe'll measure it for real.")
                .font(.body)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            Button {
                isScanFlowPresented = true
            } label: {
                Text("Scan my room")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
            }
            .buttonStyle(.borderedProminent)
            .padding(.horizontal, 32)
            .accessibilityHint("Starts a LiDAR room scan")

            Spacer()

            NavigationLink {
                AccuracySummaryView()
            } label: {
                Label("Accuracy log", systemImage: "ruler")
            }
            .padding(.bottom, 16)
            .accessibilityHint("Shows scanned versus tape-measured accuracy so far")
        }
        .padding()
        .navigationTitle("")
        .toolbar(.hidden, for: .navigationBar)
        .fullScreenCover(isPresented: $isScanFlowPresented) {
            ScanFlowView(onClose: { isScanFlowPresented = false })
        }
    }
}

/// Friendly dead-end for devices without LiDAR (and the simulator).
/// Per CLAUDE.md: graceful, honest, no technical jargon, no fake fallback.
struct UnsupportedDeviceView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "iphone.slash")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            Text("Snug needs a Pro iPhone")
                .font(.title2.bold())

            Text("Room scanning uses the LiDAR sensor on iPhone 12 Pro and newer Pro models. This device doesn't have one, so Snug can't measure rooms here — and we'd rather not guess.")
                .font(.body)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
        }
        .padding()
    }
}

/// Container that walks one scan attempt through its whole life:
/// capture → (failure | result). Lives inside a single full-screen cover so
/// the transitions between states can't fight the presentation system.
struct ScanFlowView: View {
    enum FlowState {
        case capturing
        case failed(CaptureFailure)
        case completed(ScanRecord)
    }

    let onClose: () -> Void
    @State private var state: FlowState = .capturing

    var body: some View {
        switch state {
        case .capturing:
            CaptureScreen(
                onComplete: { record in state = .completed(record) },
                onFailure: { failure in state = .failed(failure) }
            )
        case .failed(let failure):
            CaptureFailureView(
                failure: failure,
                onRetry: { state = .capturing },
                onClose: onClose
            )
        case .completed(let record):
            ScanResultScreen(
                record: record,
                onDone: onClose,
                onRescan: { state = .capturing }
            )
        }
    }
}

#Preview {
    HomeView()
        .environment(AccuracyStore())
}
