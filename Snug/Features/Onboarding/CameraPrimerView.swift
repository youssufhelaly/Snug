import SwiftUI
import AVFoundation
import UIKit

/// The permission primer: explains *why* Snug needs the camera, then triggers the
/// real `AVCaptureDevice.requestAccess` so the system dialog appears right after
/// this friendly screen — never cold. Camera is the only permission Snug needs;
/// `ARWorldTrackingConfiguration` does not require a motion permission, so we
/// don't claim one.
///
/// Once granted, both capture paths' own permission gates
/// (`CaptureScreen.prepare` / `ManualARCaptureView`) simply see `.authorized`
/// and proceed — this screen changes nothing inside capture. If the user denies
/// or defers, onboarding still completes: the capture flow surfaces the existing
/// friendly `cameraPermissionDenied` screen when they actually try to scan.
struct CameraPrimerView: View {
    /// Called when the user is done here — granted, denied-but-continuing, or
    /// deferred. Onboarding never blocks on the camera answer.
    let onContinue: () -> Void

    private enum Phase {
        /// Explaining why we need the camera, before any system prompt.
        case explain
        /// The user denied access (now or previously) — offer Settings.
        case denied
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase: Phase = .explain
    @State private var isRequesting = false
    /// Toggled when access is granted, purely to drive a success haptic.
    @State private var granted = false

    var body: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: phase == .explain ? "camera.viewfinder" : "camera.fill")
                .font(.system(size: 72))
                .foregroundStyle(SnugTheme.clay)
                .symbolRenderingMode(.hierarchical)
                .accessibilityHidden(true)

            Text(title)
                .font(.system(.title, design: .rounded).weight(.bold))
                .foregroundStyle(SnugTheme.ink)
                .multilineTextAlignment(.center)

            Text(message)
                .font(.body)
                .foregroundStyle(SnugTheme.subtle)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal)

            Spacer()

            actions
                .padding(.horizontal, 32)
                .padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(reduceMotion ? nil : SnugTheme.spring, value: phase)
        .sensoryFeedback(.success, trigger: granted)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var actions: some View {
        switch phase {
        case .explain:
            primaryButton(title: isRequesting ? "Asking…" : "Allow camera access") {
                Task { await requestCamera() }
            }
            .disabled(isRequesting)

            secondaryButton(title: "Maybe later", action: onContinue)
                .accessibilityHint("Continues without camera access; you can allow it later when you scan")

        case .denied:
            primaryButton(title: "Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .accessibilityHint("Opens the Settings app so you can allow camera access")

            secondaryButton(title: "Continue anyway", action: onContinue)
        }
    }

    private func primaryButton(title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(.headline, design: .rounded).weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
        }
        .buttonStyle(.borderedProminent)
        .tint(SnugTheme.clay)
        .clipShape(Capsule())
    }

    private func secondaryButton(title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(SnugTheme.subtle)
            .padding(.vertical, 8)
    }

    /// Drives the real system prompt with context already on screen. Granting
    /// finishes onboarding; denying flips to the Settings-deep-link state.
    private func requestCamera() async {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            granted.toggle()
            onContinue()
        case .notDetermined:
            isRequesting = true
            let allowed = await AVCaptureDevice.requestAccess(for: .video)
            isRequesting = false
            if allowed {
                granted.toggle()
                onContinue()
            } else {
                phase = .denied
            }
        default:
            // Previously denied or restricted — no system prompt will appear, so
            // route straight to the Settings path.
            phase = .denied
        }
    }

    private var title: String {
        switch phase {
        case .explain: "Let's see your room"
        case .denied: "Camera's switched off"
        }
    }

    private var message: String {
        switch phase {
        case .explain:
            "Snug measures your room by looking through the camera — that's how the fit check stays honest. We only use it while you're scanning, and nothing leaves your phone."
        case .denied:
            "No problem — Snug just can't scan until the camera's allowed. Turn it on in Settings whenever you're ready, and we'll pick up right where we left off."
        }
    }
}

#Preview("Camera primer") {
    CameraPrimerView(onContinue: {})
}
