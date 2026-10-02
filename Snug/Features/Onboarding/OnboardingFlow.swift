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
    @State private var selection = Self.initialSlide
    /// Toggled on each forward step purely to drive a light tap haptic.
    @State private var stepped = false

    private let slides = OnboardingSlide.all

    /// The first slide shown; the screenshot harness can start further in.
    private static var initialSlide: Int {
        #if DEBUG
        return UserDefaults.standard.integer(forKey: "snugSlide")
        #else
        return 0
        #endif
    }

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

/// One value slide: a visual that shows the idea, a rounded headline, and
/// warm body copy.
private struct OnboardingSlideView: View {
    let slide: OnboardingSlide
    let isActive: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 28) {
            Spacer(minLength: 12)

            visual
                .frame(maxWidth: .infinity)
                .frame(height: 320)
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

            Spacer(minLength: 12)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(slide.title). \(slide.body)")
    }

    @ViewBuilder private var visual: some View {
        switch slide.visual {
        case .scan:
            ScanVisual(isActive: isActive && !reduceMotion)
        case .room:
            Image("SampleRoomHero")
                .resizable()
                .scaledToFit()
                .clipShape(.rect(cornerRadius: 32))
                .shadow(color: SnugTheme.clay.opacity(0.25), radius: 24, y: 12)
                .padding(.horizontal, 8)
        case .verdicts:
            VerdictsVisual(isActive: isActive, reduceMotion: reduceMotion)
        }
    }
}

/// A camera mark inside soft, breathing rings: "point your phone at the room".
private struct ScanVisual: View {
    let isActive: Bool

    var body: some View {
        ZStack {
            ForEach(0..<3, id: \.self) { ring in
                Circle()
                    .stroke(SnugTheme.clay.opacity(0.18 - Double(ring) * 0.05), lineWidth: 2)
                    .frame(width: 170 + CGFloat(ring) * 60, height: 170 + CGFloat(ring) * 60)
            }
            Circle()
                .fill(SnugTheme.clay.opacity(0.12))
                .frame(width: 170, height: 170)
            Image(systemName: "camera.viewfinder")
                .font(.system(size: 76, weight: .medium))
                .foregroundStyle(SnugTheme.clay)
                .symbolEffect(.breathe, isActive: isActive)
        }
    }
}

/// The four honest fit verdicts, exactly as the app shows them, so the promise
/// on this slide is the real product, not a marketing claim.
private struct VerdictsVisual: View {
    let isActive: Bool
    let reduceMotion: Bool

    private let states: [FitResult.State] = [.fitsWithRoom, .fits, .tooCloseToCall, .wontFit]

    var body: some View {
        VStack(spacing: 12) {
            ForEach(states, id: \.headline) { state in
                let index = states.firstIndex(of: state) ?? 0
                HStack(spacing: 12) {
                    Image(systemName: state.symbol)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(state.tint)
                        .frame(width: 40, height: 40)
                        .background(state.tint.opacity(0.14), in: .circle)
                    Text(state.headline)
                        .font(.system(.headline, design: .rounded))
                        .foregroundStyle(SnugTheme.ink)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(SnugTheme.surface, in: .rect(cornerRadius: 18))
                .shadow(color: .black.opacity(0.05), radius: 10, y: 4)
                .opacity(isActive || reduceMotion ? 1 : 0)
                .offset(y: isActive || reduceMotion ? 0 : 16)
                .animation(SnugTheme.spring.delay(Double(index) * 0.08), value: isActive)
            }
        }
        .padding(.horizontal, 8)
    }
}

/// Static copy for the value slides. Kept as data so the slide view stays dumb.
private struct OnboardingSlide: Identifiable {
    enum Visual {
        case scan
        case room
        case verdicts
    }

    let id = UUID()
    let visual: Visual
    let title: String
    let body: String

    static let all: [OnboardingSlide] = [
        OnboardingSlide(
            visual: .scan,
            title: "Scan your room",
            body: "Tap the corners of your room with your iPhone's camera. No LiDAR, no tape measure."
        ),
        OnboardingSlide(
            visual: .room,
            title: "Try real furniture",
            body: "Drop in real products at their true size and arrange them until it feels like home."
        ),
        OnboardingSlide(
            visual: .verdicts,
            title: "Know before you buy",
            body: "Every piece gets an honest fit check. When it's too close to call, we'll tell you to measure."
        )
    ]
}

#Preview("Onboarding") {
    OnboardingFlow(onFinished: {})
}
