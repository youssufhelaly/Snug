import SwiftUI
import UIKit

/// The single source of truth for Snug's "playful but trustworthy" palette and
/// the diorama's material colors (CLAUDE.md: define colors in
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

/// Concrete RealityKit-ready colors and lighting for the room diorama. There is
/// ONE look: true-to-color room surfaces under neutral lighting — nothing inside
/// the room is ever stylized, because seeing your real colors together is the
/// product. The playfulness lives in the FRAME around the room (the warm
/// backdrop, the platform base, the wall-cap rims), which never touches a color
/// the user owns. Resolved to non-dynamic `UIColor`s because RealityKit
/// materials don't participate in trait-collection resolution.
struct RoomPalette {
    // MARK: Room surfaces (true colors — never stylized)
    // `floor`/`wall`/`base` are `var` so `palette(style:)` can overlay the
    // room's chosen surface colors; everything else is fixed.
    var floor: UIColor
    var wall: UIColor
    let opening: UIColor
    /// The trim frame around an opening (perimeter bars + mullions/rails).
    /// Neutral, so the frame never carries invented color into the room.
    let openingTrim: UIColor

    // MARK: Frame (the diorama shell around the room — brand warmth lives here)
    /// The soft grounding platform under the room.
    var base: UIColor
    /// Scene background behind the diorama. Part of the frame, not the room, so
    /// it defaults to the warm brand terracotta without altering any in-room
    /// color — and, being frame, it's the one surface the user may restyle
    /// playfully (`var` so `palette(style:)` can overlay a chosen backdrop).
    var background: UIColor
    /// Chunky warm-white rim capping each wall's top edge, so the walls read as
    /// solid model slabs rather than thin sheets (the diorama-cube look). Sits
    /// ON TOP of the walls — it never recolors a surface the user owns.
    let wallCap: UIColor

    // MARK: Lighting (neutral — lighting must never alter perceived color)
    //
    // NOTE: RealityKit has no dedicated ambient-light entity (still true on
    // iOS 26); this directional trio carries the whole rig. Intensities are in
    // lux (RealityKit's unit), tuned on device. All tints are white on purpose:
    // a warm key would shift every perceived color in the room, which breaks
    // the true-color promise just as surely as a material override would.
    let keyTint: UIColor
    let keyIntensity: Float
    let fillTint: UIColor
    let fillIntensity: Float
    let backTint: UIColor
    let backIntensity: Float

    /// The single truthful look. Room surfaces default to neutral greige — we
    /// never claim a color the user hasn't told us (that would be false
    /// precision); the warmth is confined to the frame.
    static let standard = RoomPalette(
        floor: UIColor(rgb: 0xB7B3AD),
        wall: UIColor(rgb: 0xC8C4BE),
        opening: UIColor(rgb: 0xA9A39A),
        openingTrim: UIColor(rgb: 0xBFBBB4),
        base: UIColor(rgb: 0xA29C93),
        background: UIColor(rgb: 0xE8764A),   // warm terracotta "void" backdrop (frame)
        wallCap: UIColor(rgb: 0xFBF6EE),      // warm-white wall rim (frame)
        keyTint: .white,
        keyIntensity: 2200,
        fillTint: .white,
        fillIntensity: 1000,
        backTint: .white,
        backIntensity: 700
    )

    /// The palette with the room's chosen surface colors applied. An unset
    /// choice keeps the neutral default; a set choice shows the honest value,
    /// with the platform base derived by darkening the chosen floor so the
    /// diorama shell always matches.
    static func palette(style: RoomSurfaceStyle) -> RoomPalette {
        var palette = standard
        if let wall = style.wall {
            palette.wall = wall.color
        }
        if let floor = style.floor {
            palette.floor = floor.color
            palette.base = floor.color.darkened(by: 0.10)
        }
        if let backdrop = style.backdrop {
            palette.background = backdrop.color
        }
        return palette
    }
}

// MARK: - Room surface choices (values live here so Theme stays the single
// source of truth for colors; the choice identities live in RoomSurfaceStyle)

extension WallColorChoice {
    /// The honest value — what the wall actually looks like. Never stylized.
    var color: UIColor {
        switch self {
        case .white: UIColor(rgb: 0xF2F1EE)
        case .cream: UIColor(rgb: 0xEDE6D9)
        case .greige: UIColor(rgb: 0xCCC7BE)
        case .sage: UIColor(rgb: 0xB9C4B2)
        case .dustyBlue: UIColor(rgb: 0xAEBFC9)
        case .blush: UIColor(rgb: 0xDDBBAE)
        }
    }
}

extension BackdropColorChoice {
    /// The backdrop is frame, not room, so these are brand-warm accent tones —
    /// muted enough that the true-color room always reads brighter than its
    /// surround, never competing with a color the user owns.
    var color: UIColor {
        switch self {
        case .sage: UIColor(rgb: 0x8CA98F)
        case .dustyBlue: UIColor(rgb: 0x8FA9B8)
        case .sand: UIColor(rgb: 0xD9BF98)
        case .lavender: UIColor(rgb: 0xA79BC0)
        case .blush: UIColor(rgb: 0xDBA290)
        case .charcoal: UIColor(rgb: 0x3A362F)
        }
    }
}

extension FloorMaterialChoice {
    /// The honest value — what the floor actually looks like. Never stylized.
    var color: UIColor {
        switch self {
        case .lightOak: UIColor(rgb: 0xC9A876)
        case .warmOak: UIColor(rgb: 0xA97C55)
        case .walnut: UIColor(rgb: 0x6E4B33)
        case .greyLaminate: UIColor(rgb: 0xA5A09A)
        case .beigeCarpet: UIColor(rgb: 0xCEC2AE)
        case .concrete: UIColor(rgb: 0x9C9A97)
        }
    }
}

// MARK: - Color helpers

extension UIColor {
    /// This color with its brightness scaled down by `fraction` (0–1). Used to
    /// derive the diorama's platform base from a chosen floor color so the shell
    /// always matches the floor.
    func darkened(by fraction: CGFloat) -> UIColor {
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard getHue(&h, saturation: &s, brightness: &b, alpha: &a) else { return self }
        return UIColor(hue: h, saturation: s, brightness: b * (1 - fraction), alpha: a)
    }

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

extension Color {
    /// Builds a color from a `#RRGGBB` (or bare `RRGGBB`) hex string, full
    /// opacity. Used by the Phase 2 furniture color categories so their
    /// tints can be authored as hex literals. An unparseable string falls back
    /// to the subtle grey rather than crashing — colors must never take the app
    /// down (CLAUDE.md: fail gracefully, never blank/technical).
    init(hex: String) {
        let cleaned = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard cleaned.count == 6, let value = UInt32(cleaned, radix: 16) else {
            self = Color(UIColor(rgb: 0x8A847C))
            return
        }
        self = Color(UIColor(rgb: value))
    }
}
