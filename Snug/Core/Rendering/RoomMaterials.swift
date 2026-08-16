import RealityKit
import UIKit

/// Factory for the diorama's surface materials. Colors come from `RoomPalette`
/// in `Theme.swift` — the single source of truth — so the renderer never
/// hardcodes a hex value.
///
/// We use `PhysicallyBasedMaterial` at high roughness rather than
/// `SimpleMaterial`: a matte PBM under the neutral rig reads as a clean model
/// surface at casual viewing distance, and — critically — a neutral matte
/// material shows the palette's colors as they are. The room's surfaces must
/// stay true-to-color (the honesty promise), so nothing here tints, warms, or
/// stylizes; the only latitude taken is roughness, which affects highlight
/// shape, not hue.
enum RoomMaterials {

    /// Walls: large flat surfaces. Plain matte PBM.
    static func wall(_ palette: RoomPalette) -> PhysicallyBasedMaterial {
        matte(palette.wall, roughness: 0.85)
    }

    /// Floor: slightly rougher than walls so it reads as the ground.
    static func floor(_ palette: RoomPalette) -> PhysicallyBasedMaterial {
        matte(palette.floor, roughness: 0.9)
    }

    /// Door / window / opening panels.
    static func opening(_ palette: RoomPalette) -> PhysicallyBasedMaterial {
        matte(palette.opening, roughness: 0.85)
    }

    /// The trim frame (perimeter bars + mullions/rails) around an opening.
    static func openingTrim(_ palette: RoomPalette) -> PhysicallyBasedMaterial {
        matte(palette.openingTrim, roughness: 0.7)
    }

    /// The soft grounding platform beneath the room (frame, not room).
    static func base(_ palette: RoomPalette) -> PhysicallyBasedMaterial {
        matte(palette.base, roughness: 0.95)
    }

    /// The chunky warm-white rim capping each wall's top edge (frame detailing).
    /// A touch smoother than the wall body so the cap catches a clean highlight
    /// and reads as a solid molded edge.
    static func wallCap(_ palette: RoomPalette) -> PhysicallyBasedMaterial {
        matte(palette.wallCap, roughness: 0.8)
    }

    // MARK: - Core builder

    /// A matte, non-metallic physically-based material. Shared by every surface
    /// so callers can reuse one instance across same-color components (don't
    /// allocate a material per entity).
    private static func matte(_ color: UIColor, roughness: Float) -> PhysicallyBasedMaterial {
        var material = PhysicallyBasedMaterial()
        material.baseColor = .init(tint: color)
        material.roughness = .init(floatLiteral: roughness)
        material.metallic = .init(floatLiteral: 0.0)
        return material
    }
}
