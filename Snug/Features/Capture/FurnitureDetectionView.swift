import SwiftUI

/// The post-scan "pan your room" step, presented as a TRANSPARENT overlay on top
/// of the live AR camera so the user can see exactly what's being scanned. Live
/// bounding boxes track furniture as it's recognized; the user pans freely and taps
/// **Done** when satisfied — there's no fixed timer. A brief "Found N" success then
/// confirms before the flow advances.
///
/// Reads live state from the `@Observable` `FurnitureDetectionService`
/// (`liveRegions`, `liveConfirmedCount`, `orientedImageSize`). Empty regions of
/// this overlay are non-interactive, so the underlying Cancel button still works.
struct FurnitureDetectionView: View {
    let service: FurnitureDetectionService
    /// True once the user finished and footprints were resolved.
    let finished: Bool
    /// Resolved count, shown in the success state.
    let foundCount: Int
    /// User is satisfied — stop scanning and resolve what was seen.
    let onDone: () -> Void
    /// Skip detection and add furniture by hand instead.
    let onSkip: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if finished {
                successOverlay
            } else {
                boundingBoxLayer
                scanningChrome
            }
        }
        .animation(reduceMotion ? nil : SnugTheme.spring, value: finished)
        // Success haptic on the false→true transition (declarative, iOS 17+).
        .sensoryFeedback(.success, trigger: finished) { _, isFinished in isFinished }
    }

    // MARK: - Live bounding boxes

    private var boundingBoxLayer: some View {
        GeometryReader { geo in
            let projection = CameraAspectFillProjection(
                imageSize: service.orientedImageSize ?? geo.size,
                viewport: geo.size
            )
            ForEach(service.liveRegions) { region in
                let rect = projection.rect(region.uiKitBoundingBox)
                DetectionBox(region: region, rect: rect)
            }
        }
        .allowsHitTesting(false)
        .ignoresSafeArea()
    }

    // MARK: - Scanning chrome (instruction + found count + controls)

    private var scanningChrome: some View {
        VStack(spacing: 0) {
            // Top: live tally + gentle prompt, on a legibility scrim.
            VStack(spacing: 8) {
                foundPill
                Text("Pan slowly across your furniture")
                    .font(.system(.headline, design: .rounded).weight(.semibold))
                    .foregroundStyle(.white)
                Text("We’ll spot it as you go. Tap Done when you’ve covered the room.")
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(0.85))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
            .padding(.top, 8)
            .padding(.bottom, 20)
            .frame(maxWidth: .infinity)
            .background(scrim(.top).ignoresSafeArea(edges: .top))

            Spacer()

            // Bottom: primary Done + secondary manual fallback.
            VStack(spacing: 12) {
                Button(action: onDone) {
                    Text(doneTitle)
                        .font(.system(size: 17, weight: .bold, design: .rounded))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(SnugTheme.clay, in: Capsule())
                        .foregroundStyle(.white)
                }
                .accessibilityLabel(doneTitle)

                Button(action: onSkip) {
                    Text("Add furniture myself")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.9))
                }
                .accessibilityLabel("Skip detection and add furniture manually")
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 28)
            .padding(.top, 28)
            .frame(maxWidth: .infinity)
            .background(scrim(.bottom).ignoresSafeArea(edges: .bottom))
        }
    }

    private var foundPill: some View {
        let count = service.liveConfirmedCount
        return Label(
            count == 0 ? "Looking for furniture…" : "Found \(count) \(count == 1 ? "item" : "items")",
            systemImage: count == 0 ? "viewfinder" : "checkmark.circle.fill"
        )
        .font(.system(size: 14, weight: .semibold, design: .rounded))
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
        .foregroundStyle(count == 0 ? SnugTheme.clay : SnugTheme.sage)
        .symbolEffect(.pulse, isActive: count == 0 && !reduceMotion)
        .accessibilityLabel(count == 0 ? "Looking for furniture" : "Found \(count) items so far")
    }

    private var doneTitle: String {
        let count = service.liveConfirmedCount
        return count == 0 ? "Done" : "Done — keep \(count)"
    }

    // MARK: - Success

    private var successOverlay: some View {
        ZStack {
            SnugTheme.background.ignoresSafeArea()
            VStack(spacing: 16) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(SnugTheme.sage)
                    .symbolEffect(.bounce, value: finished)
                Text(foundHeadline)
                    .font(.system(.title2, design: .rounded).weight(.bold))
                    .foregroundStyle(SnugTheme.ink)
                Text("We’ll set these up so you can clear or keep them next.")
                    .font(.system(size: 16))
                    .foregroundStyle(SnugTheme.subtle)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(foundHeadline)
    }

    private var foundHeadline: String {
        switch foundCount {
        case 0:  "No furniture found"
        case 1:  "Found 1 item"
        default: "Found \(foundCount) items"
        }
    }

    // MARK: - Helpers

    /// A soft top/bottom gradient so white chrome stays legible over any camera
    /// scene. Non-interactive, so taps in the clear middle still pass through.
    private func scrim(_ edge: VerticalEdge) -> some View {
        let stops: [Gradient.Stop] = edge == .top
            ? [.init(color: .black.opacity(0.45), location: 0), .init(color: .clear, location: 1)]
            : [.init(color: .clear, location: 0), .init(color: .black.opacity(0.55), location: 1)]
        return LinearGradient(stops: stops, startPoint: .top, endPoint: .bottom)
            .allowsHitTesting(false)
    }
}

/// One live detection: a rounded stroke with a category/confidence chip.
private struct DetectionBox: View {
    let region: DetectedFurnitureRegion
    let rect: CGRect

    var body: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(SnugTheme.sage, lineWidth: 2.5)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(SnugTheme.sage.opacity(0.12))
            )
            .overlay(alignment: .topLeading) {
                Text("\(region.category.displayName) · \(Int(region.confidence * 100))%")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(SnugTheme.sage, in: Capsule())
                    .foregroundStyle(.white)
                    .fixedSize()
                    .padding(4)
            }
            .frame(width: rect.width, height: rect.height)
            .position(x: rect.midX, y: rect.midY)
    }
}
