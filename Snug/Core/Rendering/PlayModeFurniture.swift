import RealityKit
import UIKit
import simd

/// Soft, puffy "cloud" placeholder furniture for the PLAY diorama — the
/// claymation/marshmallow aesthetic of the reference render (overlapping rounded
/// blobs, big corner radii, pastel accents), not the earlier chunky board-game
/// look.
///
/// ## Status: standalone, not yet wired
/// There is no catalog / placement system in the app yet (that arrives with the
/// Editor/`DesignStore` in a later phase). These factories are built and ready so
/// they can be dropped into a scene the moment placement exists; nothing here is
/// rendered in the live `RoomScene` diorama today. Each factory returns a parent
/// `Entity` wrapping its component `ModelEntity`s, with PLAY materials, chunky
/// box outlines, and a contact shadow already attached.
///
/// ## One honest deviation from the prompt's spec
/// **Only box components are outlined.** The inverted-hull outline
/// (`OutlineEntity.boxShell`) covers boxes; rounded parts — cylinders (legs,
/// poles, stems, pots) and spheres (armchair body, lamp shade, plant leaves) —
/// are left unoutlined here rather than shipping an untested reversed-winding
/// cylinder/sphere hull. Finalize their outlines on device when the furniture is
/// wired into a live scene.
enum PlayModeFurniture {

    enum Kind: String, CaseIterable, Identifiable {
        case sofa, armchair, coffeeTable, floorLamp, plantTall, rug
        var id: String { rawValue }
    }

    static func make(_ kind: Kind) -> Entity {
        switch kind {
        case .sofa:        return sofa()
        case .armchair:    return armchair()
        case .coffeeTable: return coffeeTable()
        case .floorLamp:   return floorLamp()
        case .plantTall:   return plantTall()
        case .rug:         return rug()
        }
    }

    // MARK: - Pieces

    // Shared soft palette. Cream upholstery + a warm clay accent pillow, matching
    // the reference's white marshmallow sofa with a single warm throw cushion.
    private static let upholstery: UInt32 = 0xF8F1E5
    private static let upholsteryWarm: UInt32 = 0xF2EADB
    private static let accentPillow: UInt32 = 0xD98A5E

    /// A cloud sofa: a rounded structural loaf hidden under overlapping puffs —
    /// two seat cushions, a three-lump back "cloud", and puffy arms — plus one
    /// warm accent pillow. Puffs are unoutlined spheres (see the type doc); only
    /// the loaf carries the subtle rim.
    private static func sofa() -> Entity {
        let root = Entity()
        root.name = "sofa"
        // Structural loaf — slightly taller/firmer so it carries the "sofa" read
        // with less reliance on big puffs.
        box(root, [1.9, 0.44, 0.92], corner: 0.16, color: upholsteryWarm, at: [0, 0.22, 0])
        // Seat cushions — flatter, tighter (less balloon).
        puff(root, radius: 0.34, scale: [1.10, 0.62, 1.00], color: upholstery, at: [-0.46, 0.46, 0.04])
        puff(root, radius: 0.34, scale: [1.10, 0.62, 1.00], color: upholstery, at: [0.46, 0.46, 0.04])
        // Back cushions — smaller, tucked behind the seat.
        puff(root, radius: 0.32, scale: [1.0, 0.85, 0.60], color: upholstery, at: [-0.55, 0.60, -0.30])
        puff(root, radius: 0.35, scale: [1.05, 0.92, 0.60], color: upholstery, at: [0.03, 0.62, -0.31])
        puff(root, radius: 0.32, scale: [1.0, 0.85, 0.60], color: upholstery, at: [0.60, 0.60, -0.30])
        // Arms — slimmer, hugging the loaf instead of ballooning out.
        puff(root, radius: 0.26, scale: [0.78, 0.95, 1.10], color: upholstery, at: [-0.90, 0.42, 0.02])
        puff(root, radius: 0.26, scale: [0.78, 0.95, 1.10], color: upholstery, at: [0.90, 0.42, 0.02])
        // Warm accent pillow, leaned into the seat.
        box(root, [0.32, 0.32, 0.15], corner: 0.13, color: accentPillow, at: [0.28, 0.60, 0.12],
            orientation: simd_quatf(angle: .pi / 9, axis: [1, 0, 0]))
        addShadow(root, footprint: [2.05, 1.0])
        return root
    }

    /// A single cloud armchair: the same recipe as the sofa, scaled to one seat.
    private static func armchair() -> Entity {
        let root = Entity()
        root.name = "armchair"
        box(root, [0.86, 0.44, 0.92], corner: 0.16, color: upholsteryWarm, at: [0, 0.22, 0])
        puff(root, radius: 0.36, scale: [1.15, 0.62, 1.00], color: upholstery, at: [0, 0.46, 0.04])      // seat
        puff(root, radius: 0.34, scale: [1.05, 0.92, 0.60], color: upholstery, at: [0, 0.60, -0.30])     // back
        puff(root, radius: 0.24, scale: [0.78, 0.95, 1.10], color: upholstery, at: [-0.44, 0.42, 0.02])  // L arm
        puff(root, radius: 0.24, scale: [0.78, 0.95, 1.10], color: upholstery, at: [0.44, 0.42, 0.02])   // R arm
        box(root, [0.28, 0.28, 0.13], corner: 0.12, color: accentPillow, at: [0, 0.58, 0.10],
            orientation: simd_quatf(angle: .pi / 10, axis: [1, 0, 0]))
        addShadow(root, footprint: [0.95, 0.95])
        return root
    }

    /// A soft coffee table: a thick, very-rounded top on four stubby rounded legs.
    private static func coffeeTable() -> Entity {
        let root = Entity()
        root.name = "coffee_table"
        let top: UInt32 = 0xF2ECE1, leg: UInt32 = 0xCDB79B
        box(root, [1.0, 0.10, 0.58], corner: 0.18, color: top, at: [0, 0.40, 0])
        for x: Float in [-0.40, 0.40] {
            for z: Float in [-0.20, 0.20] {
                post(root, radius: 0.04, height: 0.34, color: leg, at: [x, 0.17, z])
            }
        }
        addShadow(root, footprint: [1.0, 0.58])
        return root
    }

    /// A warm floor lamp: stubby rounded base, slim pole, soft glowing dome shade.
    private static func floorLamp() -> Entity {
        let root = Entity()
        root.name = "floor_lamp"
        post(root, radius: 0.15, height: 0.05, color: 0xB98A55, at: [0, 0.025, 0])              // base
        post(root, radius: 0.028, height: 1.5, color: 0xC9A063, at: [0, 0.78, 0])               // pole
        sphere(root, radius: 0.22, scale: [1.0, 0.85, 1.0], color: 0xFBE3AC, at: [0, 1.52, 0])  // soft dome shade
        addShadow(root, footprint: [0.34, 0.34])
        return root
    }

    /// A puffy potted plant: a pastel pot with a soft rounded-foliage "bush"
    /// cluster instead of spiky blades — reads as bubbly, on theme.
    private static func plantTall() -> Entity {
        let root = Entity()
        root.name = "plant_tall"
        let leaf: UInt32 = 0x6FA77E, leafDeep: UInt32 = 0x5C9069
        post(root, radius: 0.15, height: 0.34, color: 0xC9BCE8, at: [0, 0.17, 0])               // lavender pot
        puff(root, radius: 0.24, scale: [1.0, 1.05, 1.0], color: leafDeep, at: [0, 0.60, 0])    // base foliage
        puff(root, radius: 0.19, scale: [1.0, 1.15, 1.0], color: leaf, at: [-0.13, 0.80, 0.05])
        puff(root, radius: 0.19, scale: [1.0, 1.15, 1.0], color: leaf, at: [0.13, 0.82, -0.05])
        puff(root, radius: 0.16, scale: [1.0, 1.20, 1.0], color: leaf, at: [0, 0.98, 0])        // crown
        addShadow(root, footprint: [0.4, 0.4])
        return root
    }

    private static func rug() -> Entity {
        let root = Entity()
        root.name = "rug"
        // Single flat entity, NO outline — it reads fine flat and IS the
        // footprint's shadow-plane equivalent.
        let mesh = MeshResource.generateBox(size: [1.8, 0.012, 1.8], cornerRadius: 0.06)
        let entity = ModelEntity(mesh: mesh, materials: [PlayModeMaterials.furniture(color: UIColor(rgb: 0x8B5E3C))])
        entity.position = [0, 0.006, 0]
        root.addChild(entity)
        return root
    }

    // MARK: - Component helpers

    /// The subtle warm translucent rim, pulled from the PLAY palette (single
    /// source of truth) so furniture and room shell outline identically.
    private static let outlineColor = RoomPalette.palette(for: .play).outline
    private static let noRotation = simd_quatf(angle: 0, axis: [0, 1, 0])

    /// A matte box component plus its inverted-hull outline sibling (both parented
    /// to `parent`, so the outline never inherits a doubled inflation).
    @discardableResult
    private static func box(_ parent: Entity, _ size: SIMD3<Float>, corner: Float,
                            color: UInt32, at position: SIMD3<Float>,
                            orientation: simd_quatf = noRotation) -> ModelEntity {
        let mesh = MeshResource.generateBox(size: size, cornerRadius: corner)
        let entity = ModelEntity(mesh: mesh, materials: [PlayModeMaterials.furniture(color: UIColor(rgb: color))])
        entity.position = position
        entity.orientation = orientation
        parent.addChild(entity)
        if let shell = OutlineEntity.boxShell(size: size, color: outlineColor) {
            shell.position = position
            shell.orientation = orientation
            parent.addChild(shell)
        }
        return entity
    }

    /// A vertical cylinder (legs, poles, stems, pots). `generateCylinder` builds
    /// it along the Y axis, centered at the origin — exactly what every post here
    /// needs. No outline (see the type doc).
    @discardableResult
    private static func post(_ parent: Entity, radius: Float, height: Float,
                             color: UInt32, at position: SIMD3<Float>) -> ModelEntity {
        let entity = ModelEntity(mesh: .generateCylinder(height: height, radius: radius),
                                 materials: [PlayModeMaterials.furniture(color: UIColor(rgb: color))])
        entity.position = position
        parent.addChild(entity)
        return entity
    }

    @discardableResult
    private static func sphere(_ parent: Entity, radius: Float, scale: SIMD3<Float>,
                               color: UInt32, at position: SIMD3<Float>,
                               orientation: simd_quatf = noRotation) -> ModelEntity {
        let entity = ModelEntity(mesh: .generateSphere(radius: radius),
                                 materials: [PlayModeMaterials.furniture(color: UIColor(rgb: color))])
        entity.scale = scale
        entity.position = position
        entity.orientation = orientation
        parent.addChild(entity)
        return entity
    }

    /// A "puff": an unoutlined, scaled sphere used as a soft upholstery lump. A
    /// readable alias for `sphere` so the cloud-furniture recipes read clearly.
    @discardableResult
    private static func puff(_ parent: Entity, radius: Float, scale: SIMD3<Float>,
                             color: UInt32, at position: SIMD3<Float>) -> ModelEntity {
        sphere(parent, radius: radius, scale: scale, color: color, at: position)
    }

    private static func addShadow(_ root: Entity, footprint: SIMD2<Float>) {
        guard let shadow = ContactShadow.plane(footprint: footprint) else { return }
        shadow.position = [0, 0.002, 0]
        root.addChild(shadow)
    }
}
