import SwiftUI
import UIKit

/// The single source of truth for Snug's "playful but trustworthy" palette and
/// the two render modes' material colors (CLAUDE.md: define colors in
/// `Core/DesignSystem/Theme.swift`). Everything visual — SwiftUI chrome and the
/// RealityKit diorama alike — pulls its colors from here so the brand can never
/// drift between the UI and the 3D scene.
enum SnugTheme {

    // MARK: - Brand palette (SwiftUI)

    /// Warm off-white app background (#FAF7F2 light / #1C1A17 dark).
    static let background = Color(UIColor(light: 0xFAF7F2, dark: 0x1C1A17))
    /// Primary accent "Clay" (#E8714A).
    static let clay = Color(UIColor(light: 0xE8714A, dark: 0xF08A66))
    /// Secondary "Sage" (#7FA886).
    static let sage = Color(UIColor(light: 0x7FA886, dark: 0x95BE9C))
    /// Text "ink" (#2B2722 light / #F0EDE8 dark).
    static let ink = Color(UIColor(light: 0x2B2722, dark: 0xF0EDE8))
    /// Muted secondary text (#8A847C).
    static let subtle = Color(UIColor(light: 0x8A847C, dark: 0x9A948C))

    /// Card / surface fill that sits a touch above the background.
    static let surface = Color(UIColor(light: 0xFFFFFF, dark: 0x272320))

    // MARK: - Motion

    /// The one spring used on every state change (CLAUDE.md: response 0.4,
    /// damping 0.8). Imported everywhere so motion feels consistent.
    static let spring = Animation.spring(response: 0.4, dampingFraction: 0.8)
}

/// How the diorama is rendered. The geometry is byte-for-byte identical between
/// modes (a hard product requirement); only `RoomPalette` and lighting change.
enum RoomRenderMode: String, CaseIterable, Identifiable {
    /// Stylized: soft warm pastels, exaggerated-but-cozy ambient light.
    case play
    /// True-to-scale, neutral materials + visible dimension labels. True
    /// catalog colors arrive in Phase 3; here BUY is the honest "measuring"
    /// look.
    case buy

    var id: String { rawValue }

    var title: String {
        switch self {
        case .play: "Play"
        case .buy: "Buy"
        }
    }

    var symbol: String {
        switch self {
        case .play: "paintpalette.fill"
        case .buy: "ruler.fill"
        }
    }
}

/// Concrete RealityKit-ready colors for one render mode. Resolved to non-dynamic
/// `UIColor`s because RealityKit materials don't participate in trait-collection
/// resolution — the diorama picks a fixed, pleasant palette per mode.
struct RoomPalette {
    let floor: UIColor
    let wall: UIColor
    let opening: UIColor
    /// Scene background behind the diorama.
    let background: UIColor
    /// Whether dimension labels are shown (BUY mode only).
    let showsDimensions: Bool
    /// Warm vs. neutral key light, expressed as the light's tint.
    let keyLightTint: UIColor
    let keyLightIntensity: Float
    let fillLightIntensity: Float

    static func palette(for mode: RoomRenderMode) -> RoomPalette {
        switch mode {
        case .play:
            // Warm, rounded, optimistic: a cozy pastel diorama.
            return RoomPalette(
                floor: UIColor(rgb: 0xE9D8C2),       // warm sand
                wall: UIColor(rgb: 0xF5E9DC),        // soft cream
                opening: UIColor(rgb: 0x7FA886),     // sage (doors/windows)
                background: UIColor(rgb: 0xFAF7F2),  // brand off-white
                showsDimensions: false,
                keyLightTint: UIColor(rgb: 0xFFF3E6), // warm sun
                keyLightIntensity: 2600,
                fillLightIntensity: 900
            )
        case .buy:
            // True-to-scale, neutral. Stylization must never alter size/color.
            return RoomPalette(
                floor: UIColor(rgb: 0xCFCAC3),
                wall: UIColor(rgb: 0xE6E2DC),
                opening: UIColor(rgb: 0xAFA89F),
                background: UIColor(rgb: 0xF1EEE9),
                showsDimensions: true,
                keyLightTint: .white,
                keyLightIntensity: 2200,
                fillLightIntensity: 1100
            )
        }
    }
}

// MARK: - Color helpers

extension UIColor {
    /// Hex initializer (0xRRGGBB), full opacity.
    convenience init(rgb: UInt32) {
        self.init(
            red: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: 1
        )
    }

    /// A dynamic color that resolves to `light` in light mode and `dark` in
    /// dark mode. Used for SwiftUI chrome (not RealityKit, which can't resolve
    /// dynamic colors).
    convenience init(light: UInt32, dark: UInt32) {
        self.init { traits in
            traits.userInterfaceStyle == .dark ? UIColor(rgb: dark) : UIColor(rgb: light)
        }
    }
}
