import SwiftUI
import RoomPlan
import AVFoundation
import UIKit

/// Live RoomPlan capture: the system scanning UI plus minimal Cancel/Done
/// chrome. One CaptureScreen is one scan attempt — the parent flow recreates
/// it for retries, so every attempt gets a fresh RoomCaptureView and session.
struct CaptureScreen: View {
    let onComplete: (ScanRecord) -> Void
    let onFailure: (CaptureFailure) -> Void

    @State private var coordinator = RoomCaptureCoordinator()
    @State private var hasCameraAccess = false
    @State private var isProcessing = false

    var body: some View {
        ZStack {
            if hasCameraAccess {
                RoomCaptureViewContainer(coordinator: coordinator)
                    .ignoresSafeArea()
            } else {
                Color.black.ignoresSafeArea()
            }

            VStack {
                HStack {
                    Button("Cancel") {
                        coordinator.cancel()
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(.thinMaterial, in: Capsule())
                    .accessibilityHint("Stops the scan without saving")

                    Spacer()

                    Button("Done") {
                        isProcessing = true
                        coordinator.finish()
                    }
                    .fontWeight(.semibold)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(.thinMaterial, in: Capsule())
                    .disabled(!hasCameraAccess)
                    .accessibilityHint("Finishes the sweep and builds your room")
                }
                .padding()

                Spacer()
            }
            .opacity(isProcessing ? 0 : 1)
            .allowsHitTesting(!isProcessing)

            if isProcessing {
                processingOverlay
            }
        }
        .task { await prepare() }
    }

    private var processingOverlay: some View {
        ZStack {
            Color.black.opacity(0.4).ignoresSafeArea()
            ProgressView("Measuring your room…")
                .padding(24)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        }
        .accessibilityLabel("Measuring your room")
    }

    /// Capability and camera-permission gate, run before the session starts.
    /// Every refusal path maps to a CaptureFailure so the parent flow can
    /// show the right friendly screen instead of a black void.
    private func prepare() async {
        guard RoomCaptureSession.isSupported else {
            onFailure(.deviceUnsupported)
            return
        }

        coordinator.onComplete = { room in
            // Scan complete is a meaningful action — haptic per CLAUDE.md.
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            onComplete(ScanRecord(room: room))
        }
        coordinator.onFailure = onFailure

        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            hasCameraAccess = true
        case .notDetermined:
            if await AVCaptureDevice.requestAccess(for: .video) {
                hasCameraAccess = true
            } else {
                onFailure(.cameraPermissionDenied)
            }
        default:
            onFailure(.cameraPermissionDenied)
        }
    }
}

/// Hosts RoomPlan's RoomCaptureView and starts the session once the view is
/// actually in the hierarchy (starting earlier races view creation).
private struct RoomCaptureViewContainer: UIViewRepresentable {
    let coordinator: RoomCaptureCoordinator

    func makeUIView(context: Context) -> RoomCaptureView {
        let view = coordinator.captureView
        coordinator.startSessionIfNeeded()
        return view
    }

    func updateUIView(_ uiView: RoomCaptureView, context: Context) {}
}

/// Owns the RoomCaptureView, its session lifecycle, and the delegate
/// callbacks. Lives outside the SwiftUI view so the capture view survives
/// body re-evaluations.
///
/// Note: RoomCaptureViewDelegate requires NSCoding; the stub conformance at
/// the bottom is required by the protocol but never exercised — we never
/// archive the delegate.
final class RoomCaptureCoordinator: NSObject, RoomCaptureViewDelegate {
    var onComplete: ((CapturedRoom) -> Void)?
    var onFailure: ((CaptureFailure) -> Void)?

    private(set) lazy var captureView: RoomCaptureView = {
        let view = RoomCaptureView(frame: .zero)
        view.delegate = self
        return view
    }()

    private var isCancelled = false
    private var hasStarted = false

    func startSessionIfNeeded() {
        guard !hasStarted else { return }
        hasStarted = true
        captureView.captureSession.run(configuration: RoomCaptureSession.Configuration())
    }

    /// Ends the sweep; RoomPlan then processes the data and calls back via
    /// the delegate methods below.
    func finish() {
        captureView.captureSession.stop()
    }

    /// Abandons the scan: stops the session and reports `.cancelled`. The
    /// `isCancelled` flag makes any late delegate callbacks no-ops.
    func cancel() {
        isCancelled = true
        captureView.captureSession.stop(pauseARSession: true)
        onFailure?(.cancelled)
    }

    // MARK: - RoomCaptureViewDelegate

    func captureView(shouldPresent roomDataForProcessing: CapturedRoomData, error: Error?) -> Bool {
        guard !isCancelled else { return false }
        if let error {
            onFailure?(.processingFailed(error.localizedDescription))
            return false
        }
        return true
    }

    func captureView(didPresent processedResult: CapturedRoom, error: Error?) {
        guard !isCancelled else { return }
        if let error {
            onFailure?(.processingFailed(error.localizedDescription))
        } else {
            onComplete?(processedResult)
        }
    }

    // MARK: - NSCoding (protocol requirement, never used)

    override init() {
        super.init()
    }

    func encode(with coder: NSCoder) {}

    required init?(coder: NSCoder) {
        nil
    }
}
