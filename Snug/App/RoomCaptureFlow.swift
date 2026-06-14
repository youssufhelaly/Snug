import SwiftUI

/// Walks one capture attempt through its life — capture → (failure | room) —
/// for any `RoomCaptureMethod`. The method supplies the capture UI; the rest of
/// the flow is identical regardless of how the room was measured.
///
/// On "Done" the finished `RoomModel` is handed to `onComplete` (the home saves
/// it and opens its diorama). `onClose` dismisses the flow without saving — the
/// cancel / failure path.
struct RoomCaptureFlowView: View {
    let method: any RoomCaptureMethod
    let onComplete: (RoomModel) -> Void
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
                // "Done" finalizes the capture: hand the room up to be saved
                // and shown as a diorama.
                onDone: { onComplete(room) },
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
