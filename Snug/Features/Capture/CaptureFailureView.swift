import SwiftUI
import UIKit

/// One friendly screen per way a scan can end without a room. Per CLAUDE.md
/// hard rules: failures are told to the user honestly, never papered over,
/// and the copy stays warm and non-technical (the raw error hides behind a
/// disclosure for debugging).
struct CaptureFailureView: View {
    let failure: CaptureFailure
    let onRetry: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: iconName)
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            Text(title)
                .font(.title2.bold())
                .multilineTextAlignment(.center)

            Text(message)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            if case .processingFailed(let detail) = failure {
                DisclosureGroup("Technical detail") {
                    Text(detail)
                        .font(.footnote.monospaced())
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 32)
            }

            Spacer()

            actions
                .padding(.horizontal, 32)
                .padding(.bottom, 16)
        }
        .padding()
    }

    @ViewBuilder
    private var actions: some View {
        switch failure {
        case .deviceUnsupported:
            closeButton
        case .cameraPermissionDenied:
            Button {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            } label: {
                Text("Open Settings")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityHint("Opens the Settings app so you can allow camera access")
            closeButton
        case .cancelled, .processingFailed:
            Button {
                onRetry()
            } label: {
                Text(failure == .cancelled ? "Scan again" : "Try again")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
            .buttonStyle(.borderedProminent)
            closeButton
        }
    }

    private var closeButton: some View {
        Button("Close", action: onClose)
            .padding(.vertical, 8)
    }

    private var iconName: String {
        switch failure {
        case .deviceUnsupported: "iphone.slash"
        case .cameraPermissionDenied: "camera.fill"
        case .cancelled: "hand.raised"
        case .processingFailed: "arrow.triangle.2.circlepath"
        }
    }

    private var title: String {
        switch failure {
        case .deviceUnsupported: "Snug needs a Pro iPhone"
        case .cameraPermissionDenied: "Snug needs the camera"
        case .cancelled: "Scan stopped"
        case .processingFailed: "That scan didn't come together"
        }
    }

    private var message: String {
        switch failure {
        case .deviceUnsupported:
            "Room scanning uses the LiDAR sensor on iPhone 12 Pro and newer Pro models. This device doesn't have one, so Snug can't measure rooms here — and we'd rather not guess."
        case .cameraPermissionDenied:
            "Scanning works by looking at your room through the camera. Allow camera access in Settings and we're good to go."
        case .cancelled:
            "No worries — scans work best as one slow, steady sweep. Ready whenever you are."
        case .processingFailed:
            "We couldn't turn that sweep into a reliable room, and we'd rather rescan than guess. Try moving a little slower and keeping more of the room in view."
        }
    }
}

#Preview("Cancelled") {
    CaptureFailureView(failure: .cancelled, onRetry: {}, onClose: {})
}

#Preview("Processing failed") {
    CaptureFailureView(
        failure: .processingFailed("RoomCaptureSession.CaptureError.exceedsScanLimit"),
        onRetry: {},
        onClose: {}
    )
}
