import RealityKit
import UIKit

/// Factory for the diorama's surface materials, both PLAY (warm, stylized) and
/// BUY (neutral, true-to-scale). Colors come from `RoomPalette` in
/// `Theme.swift` — the single source of truth — so the renderer never hardcodes
/// a hex value.
///
/// We use `PhysicallyBasedMaterial` at high roughness rather than `SimpleMaterial`
/// or a custom surface shader: a matte PBM under the warm 3-point rig reads as a
/// cozy toy surface at casual viewing distance, and avoids the Metal shader-library
/// authoring a custom material would require. Toon stepping is therefore
/// *approximated by warm lighting on matte surfaces*. A true lighting-quantized
/// toon shader is now feasible on iOS 26 via `ShaderGraphMaterial` (authored in
/// Reality Composer Pro), but it needs an asset pipeline we don't have yet, so the
/// matte-PBM approximation stays for now (see `ToonRampGenerator`).
enum PlayModeMaterials {

    /// Walls: large flat surfaces. Plain matte PBM — no outline-prone detail.
    static func wall(_ palette: RoomPalette) -> PhysicallyBasedMaterial {
        matte(palette.wall, roughness: 0.85)
    }

    /// Floor: slightly rougher and darker than walls so it reads as the ground.
    static func floor(_ palette: RoomPalette) -> PhysicallyBasedMaterial {
        matte(palette.floor, roughness: 0.9)
    }

    /// Door / window / opening panels.
    static func opening(_ palette: RoomPalette) -> PhysicallyBasedMaterial {
        matte(palette.opening, roughness: 0.85)
    }

    /// The soft grounding platform beneath the room.
    static func base(_ palette: RoomPalette) -> PhysicallyBasedMaterial {
        matte(palette.base, roughness: 0.95)
    }

    /// The chunky warm-white rim capping each wall's top edge. A touch smoother
    /// than the wall body so the cap catches a clean highlight and reads as a
    /// solid molded edge.
    static func wallCap(_ palette: RoomPalette) -> PhysicallyBasedMaterial {
        matte(palette.wallCap, roughness: 0.8)
    }

    /// The warm "hidden-cove" cornice strip: a self-illuminated accent, not a true
    /// light source — RealityKit emissives glow but don't cast global illumination,
    /// so this reads as the light's *source*, while the IBL carries the room wash.
    static func cornice(_ palette: RoomPalette) -> PhysicallyBasedMaterial {
        emissive(color: palette.cornice, intensity: 3.0)
    }

    /// The over-exposed "white void" surface for windows / open openings: a bright
    /// emissive near-white that blows out like a photographic soft-box rather than
    /// reading as glass.
    static func voidWindow(_ palette: RoomPalette) -> PhysicallyBasedMaterial {
        emissive(color: palette.voidWindow, intensity: 2.0)
    }

    /// A self-illuminated matte material. `intensity` scales the emissive
    /// contribution (1.0 ≈ the tint at full brightness; >1 drives it toward a
    /// blown-out white under the diorama's IBL).
    static func emissive(color: UIColor, intensity: Float) -> PhysicallyBasedMaterial {
        var material = PhysicallyBasedMaterial()
        material.baseColor = .init(tint: color)
        material.emissiveColor = .init(color: color)
        material.emissiveIntensity = intensity
        material.roughness = .init(floatLiteral: 1.0)
        material.metallic = .init(floatLiteral: 0.0)
        return material
    }

    /// A PLAY-mode furniture surface: soft foam/clay, not flat matte. A moderate
    /// roughness plus a gentle specular gives the puffy "marshmallow" highlight you
    /// see in the reference render once it sits under the warm image-based light —
    /// without ever going metallic. `roughness` is left tunable for callers that
    /// want a flatter or glossier piece.
    static func furniture(color: UIColor, roughness: Float = 0.6) -> PhysicallyBasedMaterial {
        var material = PhysicallyBasedMaterial()
        material.baseColor = .init(tint: color)
        material.roughness = .init(floatLiteral: roughness)
        material.metallic = .init(floatLiteral: 0.0)
        // A soft, even highlight — enough to catch the IBL and read as foam, not
        // so much that it looks wet or plastic.
        material.specular = .init(floatLiteral: 0.5)
        return material
    }

    // MARK: - Core builder

    /// A matte, non-metallic physically-based material. Shared by every surface so
    /// callers can reuse one instance across same-color components (Step 9: don't
    /// allocate a material per entity).
    private static func matte(_ color: UIColor, roughness: Float) -> PhysicallyBasedMaterial {
        var material = PhysicallyBasedMaterial()
        material.baseColor = .init(tint: color)
        material.roughness = .init(floatLiteral: roughness)
        material.metallic = .init(floatLiteral: 0.0)
        return material
    }
}
