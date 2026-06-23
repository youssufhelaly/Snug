import SwiftUI

/// First-run welcome: three brand-voice value slides, then a camera-permission
/// primer *before* the real system prompt ever fires (see `CameraPrimerView`).
///
/// Why this exists: a cold "Snug would like to access the camera" dialog with no
/// context is where AR apps lose first-time users. We explain the why first, then
/// trigger the request — never cold-prompt.
///
/// The flow is gated by `@AppStorage("hasOnboarded")` in `SnugApp`; `onFinished`
/// flips that flag so the home appears and onboarding never shows again (it's
/// re-triggerable from the home's More menu). Capture/fit internals are untouched
/// — once camera is granted here, the capture flow's own permission gate simply
/// sees `.authorized` and proceeds.
struct OnboardingFlow: View {
    /// Called once the user finishes (or skips through) onboarding.
    let onFinished: () -> Void

    private enum Phase {
        case slides
        case primer
    }

    @State private var phase: Phase = .slides

    /// The capture methods this device can actually run. Reuses the single
    /// source of truth (`CaptureMethodRegistry`) rather than re-detecting
    /// capability — per CLAUDE.md the unsupported screen shows only when neither
    /// method works.
    private var hasSupportedMethod: Bool {
        !CaptureMethodRegistry.supported.isEmpty
    }

    var body: some View {
        ZStack {
            SnugTheme.background.ignoresSafeArea()

            switch phase {
            case .slides:
                OnboardingSlidesView(onGetStarted: advanceFromSlides)
                    .transition(.opacity)
            case .primer:
                CameraPrimerView(onContinue: onFinished)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
    }

    private func advanceFromSlides() {
        // On an unsupported device there's no camera to prime, so skip the primer
        // and finish onboarding now. The home shell shows the honest
        // `UnsupportedDeviceView` itself, so the user lands on the same dead-end —
        // and crucially `hasOnboarded` flips, so we never re-loop into onboarding.
        guard hasSupportedMethod else {
            onFinished()
            return
        }
        withAnimation(SnugTheme.spring) { phase = .primer }
    }
}

// MARK: - Value slides

/// The three "here's what Snug does" slides, in the product's core-loop order:
/// scan → redesign → buy what honestly fits.
private struct OnboardingSlidesView: View {
    let onGetStarted: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selection = 0
    /// Toggled on each forward step purely to drive a light tap haptic.
    @State private var stepped = false

    private let slides = OnboardingSlide.all

    var body: some View {
        VStack(spacing: 0) {
            skipBar

            TabView(selection: $selection) {
                ForEach(Array(slides.enumerated()), id: \.element.id) { index, slide in
                    OnboardingSlideView(slide: slide, isActive: index == selection)
                        .tag(index)
                        .padding(.horizontal, 32)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .indexViewStyle(.page(backgroundDisplayMode: .interactive))

            primaryButton
                .padding(.horizontal, 32)
                .padding(.bottom, 24)
        }
        .sensoryFeedback(.selection, trigger: selection)
    }

    private var isLastSlide: Bool { selection == slides.count - 1 }

    private var skipBar: some View {
        HStack {
            Spacer()
            Button("Skip", action: onGetStarted)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(SnugTheme.subtle)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .accessibilityHint("Skips the intro and continues to setting up Snug")
        }
        .opacity(isLastSlide ? 0 : 1)
        .allowsHitTesting(!isLastSlide)
    }

    private var primaryButton: some View {
        Button {
            stepped.toggle()
            if isLastSlide {
                onGetStarted()
            } else {
                withAnimation(reduceMotion ? nil : SnugTheme.spring) {
                    selection += 1
                }
            }
        } label: {
            Text(isLastSlide ? "Get started" : "Next")
                .font(.system(.headline, design: .rounded).weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
        }
        .buttonStyle(.borderedProminent)
        .tint(SnugTheme.clay)
        .clipShape(Capsule())
        .sensoryFeedback(.impact(weight: .medium), trigger: stepped)
        .accessibilityHint(isLastSlide ? "Continues to camera setup" : "Shows the next slide")
    }
}

/// One value slide: a friendly symbol, a rounded headline, and warm body copy.
private struct OnboardingSlideView: View {
    let slide: OnboardingSlide
    let isActive: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: slide.symbol)
                .font(.system(size: 88))
                .foregroundStyle(slide.tint)
                .symbolRenderingMode(.hierarchical)
                .symbolEffect(.bounce, value: isActive && !reduceMotion)
                .accessibilityHidden(true)

            VStack(spacing: 12) {
                Text(slide.title)
                    .font(.system(.largeTitle, design: .rounded).weight(.bold))
                    .foregroundStyle(SnugTheme.ink)
                    .multilineTextAlignment(.center)

                Text(slide.body)
                    .font(.body)
                    .foregroundStyle(SnugTheme.subtle)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(slide.title). \(slide.body)")
    }
}

/// Static copy for the value slides. Kept as data so the slide view stays dumb.
private struct OnboardingSlide: Identifiable {
    let id = UUID()
    let symbol: String
    let tint: Color
    let title: String
    let body: String

    static let all: [OnboardingSlide] = [
        OnboardingSlide(
            symbol: "camera.viewfinder",
            tint: SnugTheme.clay,
            title: "Scan your room",
            body: "A quick sweep with your camera turns your space into a cozy little 3D world — no tape measure, no guesswork."
        ),
        OnboardingSlide(
            symbol: "wand.and.stars",
            tint: SnugTheme.sage,
            title: "Play house, for real",
            body: "Drag in furniture and rearrange to your heart's content in a playful 3D view that's all yours."
        ),
        OnboardingSlide(
            symbol: "checkmark.seal.fill",
            tint: SnugTheme.clay,
            title: "Buy what truly fits",
            body: "Flip to true-to-scale, true-color mode and we'll tell you honestly whether it fits — tape-measure honest, never a fake green check."
        )
    ]
}

#Preview("Onboarding") {
    OnboardingFlow(onFinished: {})
}
