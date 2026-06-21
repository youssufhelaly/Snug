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
    /// Exact catalog-product color (nil for detected/manual pieces). When set,
    /// BUY mode renders it instead of `colorCategory`'s representative color.
    let exactColorRGB: SIMD3<Float>?
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
            colorCategory: footprint.appearance.colorCategory,
            exactColorRGB: footprint.appearance.exactColorRGB
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

        // BUY mode showing a realistic product model: the box mesh stays invisible
        // so the true model reads through, EXCEPT an `.invalid` overflow flashes a
        // translucent red so a piece that won't fit is still obvious. Selection is
        // signaled by the Clay outline + scale-pop, not box opacity. (valid /
        // tooClose lean on the 2D FitBadge — the honest state is always on screen.)
        if mode == .buy, hasRealisticModel(entity) {
            var box = PhysicallyBasedMaterial()
            if state == .invalid {
                let red = UIColor(rgb: 0xB85450)
                box.baseColor = .init(tint: red)
                box.emissiveColor = .init(color: red)
                box.emissiveIntensity = 0.4
                box.blending = .transparent(opacity: .init(floatLiteral: 0.5))
            } else {
                box.blending = .transparent(opacity: .init(floatLiteral: 0))
            }
            component.materials = [box]
            model.model = component
            applySelectionBorder(selected, to: entity, size: component.mesh.bounds.extents)
            return
        }

        var material = PhysicallyBasedMaterial()
        material.roughness = .init(floatLiteral: 0.85)
        material.metallic = .init(floatLiteral: 0)
        material.blending = .transparent(opacity: .init(floatLiteral: selected ? 1.0 : 0.85))

        switch state {
        case .valid:
            material.baseColor = .init(tint: tint(tag.colorCategory, exact: tag.exactColorRGB, mode: mode))
        case .tooClose:
            material.baseColor = .init(tint: tint(tag.colorCategory, exact: tag.exactColorRGB, mode: mode))
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

    // MARK: - Realistic catalog model (BUY-only, visual-only child)

    /// Name of the realistic product-model child attached to a catalog box in BUY.
    /// Its presence is what flips the box into "show the model" mode; absent for
    /// detected/manual pieces and in PLAY, where the stylized box is the visual.
    static let realisticModelName = "catalog_model"

    /// Attach a loaded product model as a VISUAL-ONLY child of the box root, fit to
    /// `dimensions`, and hide the box's own mesh so the realistic model shows. The
    /// model carries no collision / input target, so taps and drags still resolve
    /// to the box (the source of truth). Replaces any existing model child.
    static func attachRealisticModel(_ model: Entity, to box: Entity, dimensions: SIMD3<Float>, tint: UIColor? = nil) {
        box.findEntity(named: realisticModelName)?.removeFromParent()
        model.name = realisticModelName
        scaleRealisticModel(model, to: dimensions)
        if let tint { applyModelTint(tint, to: model) }
        box.addChild(model)
        setBoxMeshHidden(true, on: box)
    }

    /// Override every descendant mesh's material with a solid PBR tint.
    ///
    /// For the untextured placeholder `.usda` models this is how BUY-mode true
    /// color is delivered: RealityKit ignores USD `displayColor` without a bound
    /// material network, so it would otherwise render the shapes default white.
    /// Tinting to the product's `trueColorRGB` also lets ONE shared model serve
    /// many products at their real colors (the sofa shape reads charcoal for one
    /// SKU, navy for another). Real product USDZ ship their own correct materials —
    /// for those, pass `tint: nil` so we keep them untouched.
    static func applyModelTint(_ color: UIColor, to entity: Entity) {
        if let model = entity as? ModelEntity, var component = model.model {
            var m = PhysicallyBasedMaterial()
            m.baseColor = .init(tint: color)
            m.roughness = .init(floatLiteral: 0.85)
            m.metallic = .init(floatLiteral: 0)
            component.materials = component.materials.map { _ in m }
            model.model = component
        }
        for child in entity.children { applyModelTint(color, to: child) }
    }

    /// Re-fit an already-attached model to new `dimensions` (called on resize). Safe
    /// to call when no model is attached.
    static func scaleRealisticModel(_ model: Entity, to dimensions: SIMD3<Float>) {
        // Measure intrinsic bounds with the model's own transform reset, so the fit
        // is computed from the raw asset every time (resize re-fits from scratch).
        model.transform = .identity
        let bounds = model.visualBounds(relativeTo: model)
        let fit = CatalogModelLoader.fitTransform(
            modelExtents: bounds.extents, modelCenter: bounds.center, targetDimensions: dimensions)
        model.scale = fit.scale
        model.position = fit.position
    }

    /// Hide or show the box's own mesh by swapping its materials' opacity, WITHOUT
    /// touching its `CollisionComponent` (so hit-testing is unaffected). Used to
    /// reveal the realistic model child while the box stays the interactive proxy.
    static func setBoxMeshHidden(_ hidden: Bool, on entity: Entity) {
        guard let model = entity as? ModelEntity, var component = model.model else { return }
        component.materials = component.materials.map { _ in
            var clear = PhysicallyBasedMaterial()
            clear.blending = .transparent(opacity: .init(floatLiteral: hidden ? 0 : 1))
            return clear
        }
        model.model = component
    }

    /// Whether a box currently shows its realistic model child (BUY + catalog).
    static func hasRealisticModel(_ entity: Entity) -> Bool {
        entity.findEntity(named: realisticModelName) != nil
    }

    /// Remove the realistic model child (returning to the stylized box, e.g. on a
    /// swap back to PLAY). No-op when none is attached.
    static func removeRealisticModel(from entity: Entity) {
        entity.findEntity(named: realisticModelName)?.removeFromParent()
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
        m.baseColor = .init(tint: tint(footprint.appearance.colorCategory,
                                       exact: footprint.appearance.exactColorRGB, mode: mode))
        m.roughness = .init(floatLiteral: footprint.appearance.materialClass.roughness)
        m.metallic = .init(floatLiteral: 0)
        if opacity < 1 {
            m.blending = .transparent(opacity: .init(floatLiteral: opacity))
        }
        return m
    }

    /// The base tint for a color in a render mode.
    ///
    /// BUY is the **true** color — the buy-mode promise. `exact` (a catalog
    /// product's known manufacturer sRGB) wins when present; otherwise the
    /// perceptual `category`'s `representativeRGB` (the best we know for a detected
    /// piece). PLAY is a **softened pastel** of that same source color (lightened
    /// toward white) for the playful look — derived from one source so the toggle
    /// is never a no-op.
    static func tint(_ category: FurnitureColorCategory, exact: SIMD3<Float>? = nil, mode: RoomRenderMode) -> UIColor {
        let rgb = exact ?? category.representativeRGB
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
        // A shown realistic model keeps the box mesh invisible (BUY catalog piece).
        if mode == .buy, hasRealisticModel(entity) {
            var clear = PhysicallyBasedMaterial()
            clear.blending = .transparent(opacity: .init(floatLiteral: 0))
            component.materials = [clear]
            model.model = component
            return
        }
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
