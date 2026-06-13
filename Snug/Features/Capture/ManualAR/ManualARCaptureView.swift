import SwiftUI
import ARKit
import RealityKit
import AVFoundation

/// The AR-assisted corner-tapping capture screen: a live ARKit camera view
/// with a step-by-step overlay. Drives `ManualARCaptureController` and reports
/// the finished `RoomModel` (or a failure) to its parent flow.
struct ManualARCaptureView: View {
    let onComplete: (RoomModel) -> Void
    let onFailure: (CaptureFailure) -> Void

    @StateObject private var controller = ManualARCaptureController()
    @State private var hasCameraAccess = false
    @State private var manualHeightText = ""

    var body: some View {
        ZStack {
            if hasCameraAccess {
                ARViewContainer(controller: controller)
                    .ignoresSafeArea()
            } else {
                Color.black.ignoresSafeArea()
            }

            VStack {
                topBar
                trackingBanner
                Spacer()
                instructionCard
            }
            .padding()
        }
        .task { await prepare() }
    }

    // MARK: - Chrome

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

    // MARK: - Step-specific instruction card

    private var instructionCard: some View {
        VStack(spacing: 12) {
            Text(title)
                .font(.headline)
            Text(detail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            if controller.lastRaycastFailed {
                Text(raycastFailureMessage)
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
        case .measuringHeight:
            heightControls
        case .markingOpenings:
            openingControls
        case .review:
            ProgressView("Saving room…")
        }
    }

    private var heightControls: some View {
        VStack(spacing: 10) {
            if let height = controller.ceilingHeight {
                Text("Ceiling height: \(SnugFormat.meters(height))")
                    .font(.subheadline.weight(.semibold))
            }
            HStack {
                TextField("Height (cm)", text: $manualHeightText)
                    .keyboardType(.decimalPad)
                    .textFieldStyle(.roundedBorder)
                Button("Use") {
                    if let meters = SnugFormat.meters(parsingCentimeters: manualHeightText) {
                        controller.setManualCeilingHeight(meters: Float(meters))
                        manualHeightText = ""
                    }
                }
            }
            Button("Continue", systemImage: "arrow.right") { controller.confirmHeightAndContinue() }
                .fontWeight(.semibold)
                .disabled(controller.ceilingHeight == nil)
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
                 ? "Optional: tap the two base corners of a door or window."
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
        case .markingCorners: "Tap each floor corner"
        case .measuringHeight: "Measure the ceiling"
        case .markingOpenings: "Mark doors & windows"
        case .review: "All set"
        }
    }

    private var detail: String {
        switch controller.step {
        case .findingFloor:
            "Slowly move your phone so it can find the floor."
        case .markingCorners:
            "Walk the room and tap where each wall meets the floor. Tap corners in order; close the loop when you're back to the start."
        case .measuringHeight:
            "Aim where a wall meets the ceiling and tap — or type the height if it won't catch."
        case .markingOpenings:
            "Tap the two bottom corners of each door or window. Skip with Done if you'd rather not."
        case .review:
            "Building your room…"
        }
    }

    private var edgeSummary: String {
        let lengths = controller.edgeLengths.map { SnugFormat.meters($0) }
        return "Walls: " + lengths.joined(separator: ", ")
    }

    private var raycastFailureMessage: String {
        switch controller.step {
        case .measuringHeight:
            "That didn't look like the ceiling — aim where the wall meets the ceiling, or type the height below."
        default:
            "Couldn't read that point — aim at the floor and tap again."
        }
    }

    // MARK: - Permission gate

    private func prepare() async {
        guard ARWorldTrackingConfiguration.isSupported else {
            onFailure(.deviceUnsupported)
            return
        }
        controller.onComplete = onComplete

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

/// Hosts the RealityKit `ARView` and hands it to the controller once it's in
/// the hierarchy.
private struct ARViewContainer: UIViewRepresentable {
    let controller: ManualARCaptureController

    func makeUIView(context: Context) -> ARView {
        let arView = ARView(frame: .zero)
        controller.attach(to: arView)
        return arView
    }

    func updateUIView(_ uiView: ARView, context: Context) {}
}
