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

    /// Once a scan attempt reaches any terminal outcome (success, failure, or
    /// cancel) this is set, and every later callback is ignored. RoomPlan can
    /// deliver `shouldPresent` and `didPresent`, and a cancel can race
    /// processing — without this, the parent could receive both an
    /// `onComplete` and an `onFailure` for one attempt.
    private var hasFinished = false
    private var hasStarted = false

    /// Backstop so the "Measuring your room…" overlay can never hang forever:
    /// if RoomPlan never calls back after the sweep stops, surface a friendly
    /// failure instead of a frozen screen.
    private static let processingTimeout: TimeInterval = 30
    private var timeoutTask: Task<Void, Never>?

    func startSessionIfNeeded() {
        guard !hasStarted else { return }
        hasStarted = true
        captureView.captureSession.run(configuration: RoomCaptureSession.Configuration())
    }

    /// Ends the sweep; RoomPlan then processes the data and calls back via
    /// the delegate methods below.
    func finish() {
        captureView.captureSession.stop()
        startProcessingTimeout()
    }

    /// Abandons the scan: stops the session and reports `.cancelled`.
    func cancel() {
        captureView.captureSession.stop(pauseARSession: true)
        deliverFailure(.cancelled)
    }

    // MARK: - Terminal delivery (fires at most once per attempt)

    private func deliverSuccess(_ room: CapturedRoom) {
        guard !hasFinished else { return }
        // A scan with no walls and no floor isn't a room we can stand behind;
        // per CLAUDE.md we'd rather tell the user and rescan than show an
        // empty diorama or feed garbage geometry to FitService.
        guard !room.walls.isEmpty || !room.floors.isEmpty else {
            deliverFailure(.processingFailed("The scan didn't capture any walls or floor."))
            return
        }
        hasFinished = true
        timeoutTask?.cancel()
        onComplete?(room)
    }

    private func deliverFailure(_ failure: CaptureFailure) {
        guard !hasFinished else { return }
        hasFinished = true
        timeoutTask?.cancel()
        onFailure?(failure)
    }

    private func startProcessingTimeout() {
        timeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.processingTimeout * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.deliverFailure(.processingFailed("Processing took too long. Try a slower, steadier sweep."))
        }
    }

    // MARK: - RoomCaptureViewDelegate

    func captureView(shouldPresent roomDataForProcessing: CapturedRoomData, error: Error?) -> Bool {
        guard !hasFinished else { return false }
        if let error {
            deliverFailure(.processingFailed(error.localizedDescription))
            return false
        }
        return true
    }

    func captureView(didPresent processedResult: CapturedRoom, error: Error?) {
        if let error {
            deliverFailure(.processingFailed(error.localizedDescription))
        } else {
            deliverSuccess(processedResult)
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
