import SwiftUI
import ARKit
import RealityKit
import AVFoundation

/// The AR-assisted corner-tapping capture screen: a live ARKit camera view
/// with a step-by-step overlay. Drives `ManualARCaptureController` and reports
/// the finished `RoomModel` (or a failure) to its parent flow.
///
/// This view also owns the conditional drag-to-correct canvas (Part 3): when
/// the controller flags a low-confidence capture (`needsCorrectionCanvas`) it
/// presents `RoomShapeEditorView` automatically before completing; otherwise it
/// completes straight through and the result screen offers an unobtrusive
/// "Review layout" button.
struct ManualARCaptureView: View {
    let onComplete: (RoomModel) -> Void
    let onFailure: (CaptureFailure) -> Void

    @State private var controller = ManualARCaptureController()
    @State private var hasCameraAccess = false

    /// Local post-capture phase. Capture stays in `.capturing` until the room is
    /// resolved; a low-confidence capture detours through `.correcting`.
    private enum Phase: Equatable {
        case capturing
        case correcting(RoomModel)
    }
    @State private var phase: Phase = .capturing

    var body: some View {
        ZStack {
            switch phase {
            case .capturing:
                captureContent
            case .correcting(let room):
                RoomShapeEditorView(
                    room: room,
                    onConfirm: { corrected in onComplete(corrected) },
                    onRecapture: {
                        controller.reset()
                        phase = .capturing
                    },
                    ceilingConfidenceIsLow: controller.ceilingConfidence == .low
                )
            }
        }
        .task { await prepare() }
        // Teardown when the capture flow is dismissed (Cancel / back / completion):
        // releases the AR session AND cancels an in-flight furniture-detection pan,
        // so a navigate-away mid-pan can't fire onComplete on a dismissed flow.
        .onDisappear { controller.stop() }
    }

    // MARK: - Capture content

    private var captureContent: some View {
        ZStack {
            if hasCameraAccess {
                ARViewContainer(controller: controller)
                    .ignoresSafeArea()
            } else {
                Color.black.ignoresSafeArea()
            }

            // Vertical alignment guide: without it, horizontal aiming error on a
            // high-wall tap warps the floor plan. Shown only while aiming up.
            if controller.isHighWallModeActive {
                HighWallAlignmentGuide()
                    .allowsHitTesting(false)
                    .ignoresSafeArea()
            }

            VStack {
                topBar
                // During furniture detection the transparent FurnitureDetectionView
                // owns the chrome (live boxes + Done); keep only Cancel from the base
                // layer so the camera and boxes aren't hidden behind a duplicate card.
                if controller.step != .furnitureDetection {
                    trackingBanner
                    floorIndicator
                    Spacer()
                    instructionCard
                } else {
                    Spacer()
                }
            }
            .padding()

            if controller.isLookingUp {
                lookUpOverlay
            }

            if controller.cameraInterrupted {
                cameraPausedOverlay
            }

            // Phase 2 furniture-detection step: a TRANSPARENT overlay over the live
            // camera with live bounding boxes; the user pans and taps Done when
            // satisfied (continuous, not a fixed timer), then a brief success.
            if controller.step == .furnitureDetection {
                FurnitureDetectionView(
                    service: controller.furnitureService,
                    finished: controller.furnitureDetectionFinished,
                    foundCount: controller.detectedFurniture.count,
                    onDone: { controller.finishFurnitureDetection() },
                    // Skip just closes the detection step — manual furniture is now
                    // added later in the room diorama (the persistent `+` button).
                    onSkip: { controller.completeFurniture(with: []) }
                )
                .transition(.opacity)
            }
        }
    }

    // MARK: - Chrome

    /// Shown over the (now black) passthrough while camera capture is interrupted.
    /// The session restarts automatically when the interruption ends — this just
    /// explains the black screen instead of leaving the user staring at it.
    private var cameraPausedOverlay: some View {
        Label("Camera paused — resuming…", systemImage: "video.slash.fill")
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(.regularMaterial, in: Capsule())
            .transition(.opacity)
    }

    private var topBar: some View {
        HStack {
            Button("Cancel") { onFailure(.cancelled) }
                .padding(.horizontal, 16).padding(.vertical, 8)
                .background(.thinMaterial, in: Capsule())
            Spacer()
        }
    }

    @ViewBuilder
    private var trackingBanner: some View {
        if case .limited(let message) = controller.trackingQuality {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.footnote.weight(.medium))
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(.yellow.opacity(0.9), in: Capsule())
                .foregroundStyle(.black)
                .padding(.top, 8)
                .transition(.opacity)
        } else if controller.trackingQuality == .initializing {
            Label("Finding your room…", systemImage: "arkit")
                .font(.footnote.weight(.medium))
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(.thinMaterial, in: Capsule())
                .padding(.top, 8)
        }
    }

    /// Always-visible floor-baseline confidence chip.
    @ViewBuilder
    private var floorIndicator: some View {
        if controller.step == .markingCorners {
            Label(
                controller.floorLocked ? "Floor locked" : "Tap a floor corner first",
                systemImage: controller.floorLocked ? "checkmark.seal.fill" : "scope"
            )
            .font(.caption.weight(.medium))
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(.thinMaterial, in: Capsule())
            .foregroundStyle(controller.floorLocked ? .green : .secondary)
            .padding(.top, 4)
        }
    }

    // MARK: - Look-up overlay (Part 2)

    private var lookUpOverlay: some View {
        ZStack {
            Color.black.opacity(0.6).ignoresSafeArea()
            VStack(spacing: 16) {
                Image(systemName: "arrow.up.to.line")
                    .font(.system(size: 44))
                    .symbolEffect(.bounce, options: .repeating)
                Text(controller.lookUpPrompt)
                    .font(.headline)
                    .multilineTextAlignment(.center)
                ProgressView()
                    .progressViewStyle(.linear)
                    .frame(maxWidth: 200)
            }
            .padding(28)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24))
            .padding(40)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(controller.lookUpPrompt)
    }

    // MARK: - Step-specific instruction card

    private var instructionCard: some View {
        VStack(spacing: 12) {
            Text(title)
                .font(.headline)
            Text(detail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            if controller.tapNeedsBetterTracking {
                Text("Hold steady and look around slowly first — the room needs to map before taps land accurately.")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
            } else if controller.lastRaycastFailed {
                Text("Couldn't read that point — aim at the floor and tap again.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            if let warning = controller.closeWarning {
                Text(warning)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            stepControls
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
    }

    @ViewBuilder
    private var stepControls: some View {
        switch controller.step {
        case .findingFloor:
            VStack(spacing: 10) {
                ProgressView()
                Button("Start tapping") { controller.beginMarkingManually() }
                    .font(.subheadline)
                    .disabled(!controller.trackingQuality.isUsable)
            }
        case .markingCorners:
            markingControls
        case .markingOpenings:
            openingControls
        case .furnitureDetection:
            // The full-screen FurnitureDetectionView overlay owns this step's UI.
            EmptyView()
        case .review:
            ProgressView("Saving room…")
        }
    }

    /// Corner-tapping controls plus the high-wall "Corner blocked?" toggle.
    private var markingControls: some View {
        VStack(spacing: 10) {
            if !controller.edgeLengths.isEmpty {
                Text(edgeSummary)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            HStack {
                Button("Undo", systemImage: "arrow.uturn.backward") { controller.undoLastCorner() }
                    .disabled(controller.corners.isEmpty)
                Spacer()
                Button("Close room", systemImage: "checkmark") { controller.closePolygon() }
                    .fontWeight(.semibold)
                    .disabled(!controller.canClosePolygon)
            }

            // High-wall toggle: always tappable. When the floor isn't locked yet
            // we warn rather than disable (the projection still works off the
            // camera-height fallback, just less accurately).
            VStack(spacing: 4) {
                Button(
                    controller.isHighWallModeActive ? "Aiming at wall — tap above the corner" : "Corner blocked?",
                    systemImage: controller.isHighWallModeActive ? "checkmark.rectangle.portrait" : "rectangle.on.rectangle.angled"
                ) {
                    controller.toggleHighWallMode()
                }
                .font(.subheadline)
                .fontWeight(controller.isHighWallModeActive ? .semibold : .regular)
                .accessibilityHint("Use this when furniture hides a corner: tap the wall directly above it")

                if controller.isHighWallModeActive && !controller.floorLocked {
                    Text("Best results after tapping a floor corner first.")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                }
            }
        }
    }

    private var openingControls: some View {
        VStack(spacing: 10) {
            Picker("Type", selection: Binding(
                get: { controller.openingKind },
                set: { controller.openingKind = $0 }
            )) {
                Text("Door").tag(RoomOpening.Kind.door)
                Text("Window").tag(RoomOpening.Kind.window)
                Text("Opening").tag(RoomOpening.Kind.opening)
            }
            .pickerStyle(.segmented)

            Text(controller.openings.isEmpty
                 ? "Optional: tap the two sides of a door or window — on the wall or along the floor."
                 : "\(controller.openings.count) opening(s) marked.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Button("Undo", systemImage: "arrow.uturn.backward") { controller.removeLastOpening() }
                    .disabled(controller.openings.isEmpty && controller.pendingOpeningStart == nil)
                Spacer()
                Button("Done", systemImage: "checkmark.circle.fill") { controller.finish() }
                    .fontWeight(.semibold)
            }
        }
    }

    // MARK: - Copy

    private var title: String {
        switch controller.step {
        case .findingFloor: "Point at the floor"
        case .markingCorners: controller.isHighWallModeActive ? "Tap the wall above the corner" : "Tap each floor corner"
        case .markingOpenings: "Mark doors & windows"
        case .furnitureDetection: "Finding your furniture"
        case .review: "All set"
        }
    }

    private var detail: String {
        switch controller.step {
        case .findingFloor:
            "Slowly move your phone so it can find the floor."
        case .markingCorners:
            controller.isHighWallModeActive
                ? "Aim at the wall straight above the hidden corner and tap — we drop it down to the floor for you."
                : "Tap a clear floor corner first. If a corner is blocked by furniture, tap the wall above it instead."
        case .markingOpenings:
            "Tap each side of a door or window — point at the wall or its base. Skip with Done if you'd rather not."
        case .furnitureDetection:
            "Pan slowly so we can spot your existing furniture."
        case .review:
            "Building your room…"
        }
    }

    private var edgeSummary: String {
        let lengths = controller.edgeLengths.map { SnugFormat.meters($0) }
        return "Walls: " + lengths.joined(separator: ", ")
    }

    // MARK: - Permission gate

    private func prepare() async {
        guard ARWorldTrackingConfiguration.isSupported else {
            onFailure(.deviceUnsupported)
            return
        }
        // Route completion through the conditional-canvas decision rather than
        // straight out: a low-confidence capture detours to the editor first.
        // Capture `controller` weakly — the closure is stored ON the controller
        // (controller.onComplete), so a strong capture would be a retain cycle
        // that leaks the controller and all its AR state.
        controller.onComplete = { [weak controller] room in
            guard let controller else { return }
            if controller.needsCorrectionCanvas {
                phase = .correcting(room)
            } else {
                onComplete(room)
            }
        }
        // Route hard session/camera failures to the same failure UI as the
        // permission/unsupported gates, rather than leaving a frozen black view.
        controller.onFailure = { failure in onFailure(failure) }

        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            hasCameraAccess = true
        case .notDetermined:
            hasCameraAccess = await AVCaptureDevice.requestAccess(for: .video)
            if !hasCameraAccess { onFailure(.cameraPermissionDenied) }
        default:
            onFailure(.cameraPermissionDenied)
        }
    }
}

/// A dotted vertical guide from the screen-centre crosshair down to the bottom,
/// drawn as a plain 2D overlay. Helps the user keep the phone level when tapping
/// a wall above a blocked corner so the projected X/Z lands true.
private struct HighWallAlignmentGuide: View {
    var body: some View {
        GeometryReader { geo in
            let centerX = geo.size.width / 2
            let centerY = geo.size.height / 2
            ZStack {
                // Crosshair at centre.
                Path { p in
                    p.move(to: CGPoint(x: centerX - 12, y: centerY))
                    p.addLine(to: CGPoint(x: centerX + 12, y: centerY))
                    p.move(to: CGPoint(x: centerX, y: centerY - 12))
                    p.addLine(to: CGPoint(x: centerX, y: centerY + 12))
                }
                .stroke(.white.opacity(0.9), lineWidth: 2)

                // Dotted plumb line down to the bottom edge.
                Path { p in
                    p.move(to: CGPoint(x: centerX, y: centerY))
                    p.addLine(to: CGPoint(x: centerX, y: geo.size.height))
                }
                .stroke(.white.opacity(0.8), style: StrokeStyle(lineWidth: 2, dash: [4, 6]))
            }
        }
    }
}

/// Hosts the RealityKit `ARView` and hands it to the controller once it's in
/// the hierarchy.
private struct ARViewContainer: UIViewRepresentable {
    let controller: ManualARCaptureController

    func makeUIView(context: Context) -> ARView {
        // Reuse the single app-lifetime capture ARView (see
        // `ManualARCaptureController.sharedARView`) rather than creating a fresh one
        // — a new ARView renderer gets poisoned black by the diorama's RealityView
        // on iOS 26. Detach it from any prior superview before re-hosting.
        let arView = ManualARCaptureController.sharedARView
        arView.removeFromSuperview()
        controller.attach(to: arView)
        return arView
    }

    func updateUIView(_ uiView: ARView, context: Context) {}

    /// SwiftUI is tearing down the AR view (Cancel, completion, or the detour into
    /// the correction canvas). Pause the session so the camera is released
    /// immediately — without this the session lingers and the NEXT capture opens a
    /// second session that can't acquire the held camera, producing the black
    /// passthrough that only a full app restart clears.
    static func dismantleUIView(_ uiView: ARView, coordinator: ()) {
        // The ARView is shared and reused, so pause + detach from the hierarchy —
        // never destroy it (that would re-introduce the fresh-renderer black camera).
        uiView.session.pause()
        uiView.removeFromSuperview()
    }
}
