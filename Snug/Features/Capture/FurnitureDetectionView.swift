import SwiftUI

/// The post-scan "pan your room" step: a friendly progress screen while the
/// detector samples frames, then a brief "Found X" success before the capture
/// flow auto-advances. A Skip button drops straight to the manual picker.
///
/// Presented as a full-bleed overlay by `ManualARCaptureView` while the
/// controller is on `.furnitureDetection`. Reads progress from the
/// `@Observable` `FurnitureDetectionService`.
struct FurnitureDetectionView: View {
    let service: FurnitureDetectionService
    /// True once the sweep finished and footprints were resolved.
    let finished: Bool
    let foundCount: Int
    /// Skip the automatic sweep and add furniture by hand instead.
    let onSkip: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var didCelebrate = false

    var body: some View {
        ZStack {
            SnugTheme.background.ignoresSafeArea()

            VStack(spacing: 24) {
                Spacer()

                Image(systemName: finished ? "checkmark.circle.fill" : "camera.viewfinder")
                    .font(.system(size: 56))
                    .foregroundStyle(finished ? SnugTheme.sage : SnugTheme.clay)
                    .symbolEffect(.bounce, value: didCelebrate)

                Text(finished ? foundHeadline : "Pan slowly around your room")
                    .font(.system(.title2, design: .rounded).weight(.bold))
                    .foregroundStyle(SnugTheme.ink)
                    .multilineTextAlignment(.center)

                Text(finished
                     ? "We’ll set these up so you can clear or keep them next."
                     : "Hold your phone up and sweep across your furniture. This takes a few seconds.")
                    .font(.system(size: 16))
                    .foregroundStyle(SnugTheme.subtle)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)

                if !finished {
                    ProgressView(value: service.progress)
                        .progressViewStyle(.linear)
                        .tint(SnugTheme.clay)
                        .frame(maxWidth: 240)
                        .animation(reduceMotion ? nil : SnugTheme.spring, value: service.progress)
                }

                Spacer()

                if !finished {
                    Button(action: onSkip) {
                        Text("Skip — add furniture myself")
                            .font(.system(size: 16, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(SnugTheme.surface, in: Capsule())
                            .foregroundStyle(SnugTheme.ink)
                    }
                    .padding(.horizontal, 32)
                    .padding(.bottom, 32)
                }
            }
        }
        .onChange(of: finished) { _, isFinished in
            guard isFinished else { return }
            didCelebrate.toggle()
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(finished ? foundHeadline : "Detecting furniture, please pan your room")
    }

    private var foundHeadline: String {
        switch foundCount {
        case 0:  "No furniture found"
        case 1:  "Found 1 item"
        default: "Found \(foundCount) items"
        }
    }
}
