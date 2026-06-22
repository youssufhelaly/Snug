import SwiftUI

/// The user-facing copy + color for each of `FitService`'s four states. The
/// service stays pure (no UI); this is the single place the trust-layer wording
/// lives, so "Too close to call" never gets quietly rounded to a green check
/// (CLAUDE.md: honesty IS the brand).
extension FitResult.State {
    var headline: String {
        switch self {
        case .fitsWithRoom:   return "Fits with room to spare"
        case .fits:           return "Fits"
        case .tooCloseToCall: return "Too close to call"
        case .wontFit:        return "Won't fit"
        }
    }

    /// Secondary line. Empty for the confident states; the honest nudge for the
    /// uncertain / failing ones.
    var detail: String {
        switch self {
        case .fitsWithRoom, .fits: return ""
        case .tooCloseToCall:      return "Grab a tape measure for this wall"
        case .wontFit:             return "Too big for the space here"
        }
    }

    var symbol: String {
        switch self {
        case .fitsWithRoom:   return "checkmark.circle.fill"
        case .fits:           return "checkmark.circle"
        case .tooCloseToCall: return "ruler.fill"
        case .wontFit:        return "xmark.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .fitsWithRoom, .fits: return SnugTheme.sage
        case .tooCloseToCall:      return Color(hex: "#BA7517")   // amber
        case .wontFit:             return Color(hex: "#B85450")   // soft red
        }
    }
}

/// A compact fit-state badge shown above the selected piece's micro-pill. Reads
/// as a single glanceable chip; the honest detail line appears only when the fit
/// is uncertain or failing, so a clean "Fits" stays calm.
struct FitBadge: View {
    let state: FitResult.State

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: state.symbol)
                .font(.system(size: 15, weight: .semibold))
            VStack(alignment: .leading, spacing: 1) {
                Text(state.headline)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                if !state.detail.isEmpty {
                    Text(state.detail)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .opacity(0.85)
                }
            }
        }
        .foregroundStyle(state.tint)
        .padding(.horizontal, 14)
        .frame(minHeight: 44)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().stroke(state.tint.opacity(0.35), lineWidth: 1))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(state.detail.isEmpty ? state.headline : "\(state.headline). \(state.detail)")
    }
}
