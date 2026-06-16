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

/// Concrete RealityKit-ready colors and lighting for one render mode. Resolved to
/// non-dynamic `UIColor`s because RealityKit materials don't participate in
/// trait-collection resolution — the diorama picks a fixed, pleasant palette per
/// mode. This is the single source of truth the Phase-3 stylized renderer
/// (`PlayModeMaterials`, `OutlineEntity`, the lighting rig) reads from, so the
/// brand can never drift between the SwiftUI chrome and the 3D scene.
struct RoomPalette {
    // MARK: Surfaces
    let floor: UIColor
    let wall: UIColor
    let opening: UIColor
    /// The trim frame around an opening (perimeter bars + mullions/rails). Warm in
    /// PLAY; neutral in BUY so the frame never carries stylized color into the
    /// true-color measuring view (the pane is `opening`/`voidWindow`).
    let openingTrim: UIColor
    /// The soft grounding platform under the room.
    let base: UIColor
    /// Scene background behind the diorama.
    let background: UIColor

    // MARK: Diorama shell (the "floating miniature" detailing — PLAY only)
    /// Chunky warm-white rim capping each wall's top edge, so the walls read as
    /// solid model slabs rather than thin sheets (the diorama-cube look).
    let wallCap: UIColor
    /// Warm emissive strip tucked along the inner top edge of each wall — the
    /// "hidden light cove" trope of the cozy-diorama aesthetic.
    let cornice: UIColor
    /// Over-exposed near-white fill for windows / open openings, so they read as
    /// blown-out soft-boxes ("white void") instead of flat glass panels.
    let voidWindow: UIColor

    // MARK: Stylization toggles (the Play↔Buy difference, materials/lighting only)
    /// Whether dimension labels are shown (BUY only).
    let showsDimensions: Bool
    /// Whether chunky toy outlines are shown (PLAY only). Outlines are sibling
    /// entities toggled with `isEnabled`; room *vertices* never change between
    /// modes, so the identical-geometry invariant holds.
    let showsOutlines: Bool
    /// Whether the SwiftUI corner vignette is shown (PLAY only).
    let showsVignette: Bool
    /// Whether the white wall-cap rims are shown (PLAY only). Like outlines, caps
    /// are sibling entities toggled with `isEnabled` — no vertex moves on toggle.
    let showsWallCaps: Bool
    /// Whether the emissive cornice glow strips are shown (PLAY only).
    let showsCornice: Bool
    /// Whether windows / open openings render as over-exposed white voids (PLAY
    /// only). BUY keeps neutral panes so the measuring read stays honest.
    let usesVoidWindows: Bool
    /// Whether a soft drop shadow grounds the floating room cube (PLAY only).
    let showsDropShadow: Bool
    /// Outline color for the inflated-shell pass (alpha applied at material time).
    let outline: UIColor

    // MARK: Lighting (warm 3-point in PLAY, neutral in BUY)
    //
    // NOTE: RealityKit has no dedicated ambient-light entity (still true on iOS 26).
    // The soft ambient wrap is carried by image-based lighting (StudioEnvironment);
    // this back/fill directional pair supplements it and stands in before the async
    // IBL loads. Intensities are in lux (RealityKit's unit), tuned against the
    // device-validated Phase-1 values, NOT the lumen figures in the prompt, which
    // don't map to RealityKit's scale.
    let keyTint: UIColor
    let keyIntensity: Float
    /// Cooler side fill, contrasts the warm key.
    let fillTint: UIColor
    let fillIntensity: Float
    /// Warm back fill standing in for ambient bounce (no pure blacks).
    let backTint: UIColor
    let backIntensity: Float

    static func palette(for mode: RoomRenderMode) -> RoomPalette {
        switch mode {
        case .play:
            // Warm, rounded, optimistic: a soft claymation diorama. The image-based
            // lighting (StudioEnvironment) carries the warm ambient wrap; the
            // directional rig adds a bright warm key + the soft cast shadow on top,
            // tuned to make the cream furniture read luminous like the reference.
            return RoomPalette(
                floor: UIColor(rgb: 0xC17F5A),        // terracotta-brown ground
                wall: UIColor(rgb: 0xF3E9DA),         // warm cream
                opening: UIColor(rgb: 0xDCE6E1),      // soft pale glass (doors)
                openingTrim: UIColor(rgb: 0xEDE4D4),  // warm cream frame trim
                base: UIColor(rgb: 0x9A5E3C),         // darker terracotta platform
                background: UIColor(rgb: 0xE8764A),   // solid terracotta "void" backdrop
                wallCap: UIColor(rgb: 0xFBF6EE),      // chunky warm-white wall rim
                cornice: UIColor(rgb: 0xFFD9A0),      // warm hidden-cove glow
                voidWindow: UIColor(rgb: 0xFFF6E6),   // blown-out window soft-box
                showsDimensions: false,
                showsOutlines: true,
                showsVignette: true,
                showsWallCaps: true,
                showsCornice: true,
                usesVoidWindows: true,
                showsDropShadow: true,
                // Subtle warm rim, not a hard black toy outline: a translucent warm
                // brown so the silhouette reads softly under IBL (alpha drives the
                // inverted-hull shell's opacity in OutlineEntity).
                outline: UIColor(rgb: 0x6E4A33).withAlphaComponent(0.30),
                keyTint: UIColor(rgb: 0xFFEAD0),      // warm golden key
                keyIntensity: 2700,
                fillTint: UIColor(rgb: 0xDCE4EC),     // soft cool side fill
                fillIntensity: 480,
                backTint: UIColor(rgb: 0xFFE6C8),     // warm ambient stand-in
                backIntensity: 360
            )
        case .buy:
            // True-to-scale, neutral. Stylization must never alter size/color.
            return RoomPalette(
                floor: UIColor(rgb: 0xB7B3AD),
                wall: UIColor(rgb: 0xC8C4BE),
                opening: UIColor(rgb: 0xA9A39A),
                openingTrim: UIColor(rgb: 0xBFBBB4),  // neutral frame trim
                base: UIColor(rgb: 0xA29C93),
                background: UIColor(rgb: 0x1F1F1F),   // dark neutral
                wallCap: UIColor(rgb: 0xC8C4BE),      // unused (caps off in BUY)
                cornice: UIColor(rgb: 0x000000),      // unused (cornice off in BUY)
                voidWindow: UIColor(rgb: 0xA9A39A),   // unused (void off in BUY)
                showsDimensions: true,
                showsOutlines: false,
                showsVignette: false,
                showsWallCaps: false,
                showsCornice: false,
                usesVoidWindows: false,
                showsDropShadow: false,
                outline: UIColor(rgb: 0x2A1F1A),
                keyTint: .white,
                keyIntensity: 2200,
                fillTint: .white,
                fillIntensity: 1000,
                backTint: .white,
                backIntensity: 700
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

extension Color {
    /// Builds a color from a `#RRGGBB` (or bare `RRGGBB`) hex string, full
    /// opacity. Used by the Phase 2 furniture color categories so their PLAY
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
