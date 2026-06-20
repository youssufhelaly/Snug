import RealityKit
import UIKit
import simd

/// Tags a furniture entity with the `FurnitureFootprint` it represents, so taps
/// in the de-clutter scene can route back to the right model item. Custom
/// RealityKit `Component`; registered lazily by `FurnitureEntityBuilder`.
struct FurnitureTagComponent: Component {
    let footprintID: UUID
    let category: FurnitureCategory
    /// Stored so `applyPlacementState` can restore the piece's base color when
    /// returning to the `.valid` tint (the entity carries no other color source).
    let colorCategory: FurnitureColorCategory
}

/// Builds collision-ready, tap-routable RealityKit entities for detected
/// furniture in the diorama.
///
/// ## Honest scope (matches `PlayModeFurniture`)
/// These are **stylized identity boxes**, not reconstructions: one rounded box per
/// piece, in the category's perceptual PLAY color, sized to its (estimated)
/// dimensions. That is the whole product promise for existing furniture — "we
/// recognize your room", not "we rebuilt your sofa". No texture projection, no
/// per-item meshes, no baked shadows (CLAUDE.md: out of scope).
///
/// ## Coordinate convention
/// `dimensions` is `(width, depth, height)` = `(x, y, z)`. The box mesh therefore
/// uses `height: dimensions.z` (vertical) and `depth: dimensions.y` (floor depth)
/// — NOT a Z-up world. `worldPosition` is the box center (the placement service
/// already lifted it to `floorY + height/2`).
enum FurnitureEntityBuilder {

    /// Default translucency for an un-decided piece (the de-clutter "pending" look).
    static let defaultOpacity: Float = 0.7
    /// Amber "kept" outline (#BA7517), matching the de-clutter "Staying" accent.
    static let keptOutlineColor = UIColor(rgb: 0xBA7517)

    private static var didRegister = false
    private static func registerComponentsIfNeeded() {
        guard !didRegister else { return }
        didRegister = true
        FurnitureTagComponent.registerComponent()
    }

    /// Build the entity for one footprint: a translucent rounded box in the
    /// category color, with collision + input-target for tapping and a billboarded
    /// category label. Tagged with the footprint id for tap routing.
    static func entity(for footprint: FurnitureFootprint, mode: RoomRenderMode = .play) -> Entity {
        registerComponentsIfNeeded()

        let size = SIMD3<Float>(footprint.dimensions.x, footprint.dimensions.z, footprint.dimensions.y)
        let root = ModelEntity(
            mesh: .generateBox(width: size.x, height: size.y, depth: size.z, cornerRadius: 0.04),
            materials: [material(for: footprint, opacity: defaultOpacity, mode: mode)]
        )
        root.name = "furniture_\(footprint.id.uuidString)"
        root.position = footprint.worldPosition
        root.orientation = simd_quatf(angle: footprint.yRotation, axis: [0, 1, 0])

        // Collision + input target so the de-clutter scene can hit-test taps.
        root.collision = CollisionComponent(shapes: [.generateBox(size: size)])
        root.components.set(InputTargetComponent())
        root.components.set(FurnitureTagComponent(
            footprintID: footprint.id,
            category: footprint.category,
            colorCategory: footprint.appearance.colorCategory
        ))

        root.addChild(label(footprint.category, atHeight: size.y / 2 + 0.12))
        return root
    }

    /// Switch a pending box to the "kept" look: fully opaque in its real color,
    /// with an amber outline shell. Takes the footprint so the color is exact
    /// rather than read back out of the live material.
    static func applyKeptAppearance(to entity: Entity, footprint: FurnitureFootprint, mode: RoomRenderMode = .play) {
        if let model = entity as? ModelEntity, var component = model.model {
            component.materials = [material(for: footprint, opacity: 1.0, mode: mode)]
            model.model = component
        }
        // Add the amber outline shell once.
        if entity.findEntity(named: "kept_outline") == nil {
            let size = SIMD3<Float>(footprint.dimensions.x, footprint.dimensions.z, footprint.dimensions.y)
            if let shell = OutlineEntity.boxShell(size: size, color: keptOutlineColor) {
                shell.name = "kept_outline"
                entity.addChild(shell)
            }
        }
    }

    /// Name of the persistent selection border child (an inverted-hull Clay shell).
    static let selectionOutlineName = "selection_outline"
    static let selectionColor = UIColor(rgb: 0xE8714A)   // Clay

    /// Tint a furniture entity by its placement state — the red/amber/green fit
    /// feedback — plus a clear, PERSISTENT selected look layered on top.
    /// - `.valid`    → the piece's base color, translucent 0.85
    /// - `.tooClose` → base color + amber emissive (#BA7517 @ 0.3)
    /// - `.invalid`  → red base (#B85450) + red emissive (@ 0.4)
    /// When `selected`, the piece becomes fully opaque with a strong Clay emissive
    /// (@ 0.6) AND gains a Clay border (inverted-hull shell child) — so it stays
    /// obviously "the one being moved" the whole time it's selected, not just a
    /// momentary pop. The base color still signals collision (red base = invalid).
    static func applyPlacementState(_ state: PlacementState, selected: Bool = false, mode: RoomRenderMode = .play, to entity: Entity) {
        guard let model = entity as? ModelEntity, var component = model.model,
              let tag = entity.components[FurnitureTagComponent.self] else { return }

        var material = PhysicallyBasedMaterial()
        material.roughness = .init(floatLiteral: 0.85)
        material.metallic = .init(floatLiteral: 0)
        material.blending = .transparent(opacity: .init(floatLiteral: selected ? 1.0 : 0.85))

        switch state {
        case .valid:
            material.baseColor = .init(tint: tint(tag.colorCategory, mode: mode))
        case .tooClose:
            material.baseColor = .init(tint: tint(tag.colorCategory, mode: mode))
            material.emissiveColor = .init(color: keptOutlineColor)        // amber #BA7517
            material.emissiveIntensity = 0.3
        case .invalid:
            let red = UIColor(rgb: 0xB85450)
            material.baseColor = .init(tint: red)
            material.emissiveColor = .init(color: red)
            material.emissiveIntensity = 0.4
        }

        if selected {
            material.emissiveColor = .init(color: Self.selectionColor)
            material.emissiveIntensity = 0.6
        }

        component.materials = [material]
        model.model = component

        applySelectionBorder(selected, to: entity, size: component.mesh.bounds.extents)
    }

    /// Add or remove the persistent Clay selection border. Sized to the box's
    /// current mesh bounds, so it tracks resizes (the resize path removes it first
    /// so this rebuilds it at the new size). Idempotent — safe to call every frame.
    static func applySelectionBorder(_ selected: Bool, to entity: Entity, size: SIMD3<Float>) {
        if selected {
            guard entity.findEntity(named: selectionOutlineName) == nil,
                  let shell = OutlineEntity.boxShell(size: size, color: selectionColor) else { return }
            shell.name = selectionOutlineName
            entity.addChild(shell)
        } else {
            entity.findEntity(named: selectionOutlineName)?.removeFromParent()
        }
    }

    /// Animate a cleared box out: shrink + fade over 0.35 s, then detach. Runs on
    /// the main actor (RealityKit scene mutation).
    @MainActor
    static func applyClearedAnimation(to entity: Entity) async {
        var shrunk = entity.transform
        shrunk.scale = SIMD3(repeating: 0.001)
        entity.move(to: shrunk, relativeTo: entity.parent, duration: 0.35, timingFunction: .easeInOut)
        try? await Task.sleep(nanoseconds: 360_000_000)
        entity.removeFromParent()
    }

    // MARK: - Materials

    /// Material in the category's color for the given render mode. `opacity` drives
    /// transparent blending — translucent while pending, solid once kept.
    private static func material(for footprint: FurnitureFootprint, opacity: Float, mode: RoomRenderMode) -> PhysicallyBasedMaterial {
        var m = PhysicallyBasedMaterial()
        m.baseColor = .init(tint: tint(footprint.appearance.colorCategory, mode: mode))
        m.roughness = .init(floatLiteral: footprint.appearance.materialClass.roughness)
        m.metallic = .init(floatLiteral: 0)
        if opacity < 1 {
            m.blending = .transparent(opacity: .init(floatLiteral: opacity))
        }
        return m
    }

    /// The base tint for a perceptual color in a render mode.
    ///
    /// BUY is the **true** color (`representativeRGB`, neutral) — the buy-mode promise.
    /// PLAY is a **softened pastel** of that same color (lightened toward white) for
    /// the playful look. They must be derived from one source: the catalog defines
    /// `playModeColor == representativeRGB`, so using `playModeColor` for PLAY made
    /// the toggle a no-op — both modes rendered the identical color.
    static func tint(_ category: FurnitureColorCategory, mode: RoomRenderMode) -> UIColor {
        let rgb = category.representativeRGB
        let trueColor = UIColor(red: CGFloat(rgb.x), green: CGFloat(rgb.y), blue: CGFloat(rgb.z), alpha: 1)
        switch mode {
        case .buy:  return trueColor
        case .play: return Self.pastel(rgb)
        }
    }

    /// A lightened, gently desaturated version of a true color for PLAY's stylized
    /// look — 30% toward white, so a navy reads as a soft slate and a black armchair
    /// as a warm grey, clearly distinct from BUY's true color on toggle.
    private static func pastel(_ rgb: SIMD3<Float>) -> UIColor {
        let mix: Float = 0.30
        let lighten: (Float) -> CGFloat = { CGFloat($0 + (1 - $0) * mix) }
        return UIColor(red: lighten(rgb.x), green: lighten(rgb.y), blue: lighten(rgb.z), alpha: 1)
    }

    /// Re-tint a static (viewing-mode) furniture entity for a new render mode,
    /// preserving its pending translucency. Editing mode re-tints via
    /// `applyPlacementState` (which also carries the fit-state coloring).
    static func retint(_ entity: Entity, footprint: FurnitureFootprint, mode: RoomRenderMode) {
        guard let model = entity as? ModelEntity, var component = model.model else { return }
        component.materials = [material(for: footprint, opacity: defaultOpacity, mode: mode)]
        model.model = component
    }

    private static func label(_ category: FurnitureCategory, atHeight y: Float) -> Entity {
        let mesh = MeshResource.generateText(
            category.displayName,
            extrusionDepth: 0.005,
            font: .systemFont(ofSize: 0.12, weight: .semibold),
            containerFrame: .zero,
            alignment: .center,
            lineBreakMode: .byTruncatingTail
        )
        let text = ModelEntity(mesh: mesh, materials: [UnlitMaterial(color: UIColor(rgb: 0x2B2722))])
        let bounds = text.visualBounds(relativeTo: text)
        text.position = -bounds.center
        let holder = Entity()
        holder.addChild(text)
        holder.position = [0, y, 0]
        // Billboard so the label faces the orbiting camera (RealityKit iOS 18+).
        holder.components.set(BillboardComponent())
        return holder
    }
}
