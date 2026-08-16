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
    /// it renders instead of `colorCategory`'s representative color.
    let exactColorRGB: SIMD3<Float>?
}

/// Builds collision-ready, tap-routable RealityKit entities for detected
/// furniture in the diorama.
///
/// ## Honest scope
/// These are **identity boxes**, not reconstructions: one rounded box per
/// piece, in its true perceptual color, sized to its (estimated) dimensions.
/// That is the whole product promise for existing furniture — "we recognize
/// your room", not "we rebuilt your sofa". No texture projection, no per-item
/// meshes, no baked shadows (CLAUDE.md: out of scope).
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
    static func entity(for footprint: FurnitureFootprint) -> Entity {
        registerComponentsIfNeeded()

        let size = SIMD3<Float>(footprint.dimensions.x, footprint.dimensions.z, footprint.dimensions.y)
        let root = ModelEntity(
            mesh: .generateBox(width: size.x, height: size.y, depth: size.z, cornerRadius: 0.04),
            materials: [material(for: footprint, opacity: defaultOpacity)]
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
    static func applyKeptAppearance(to entity: Entity, footprint: FurnitureFootprint) {
        if let model = entity as? ModelEntity, var component = model.model {
            component.materials = [material(for: footprint, opacity: 1.0)]
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
    static func applyPlacementState(_ state: PlacementState, selected: Bool = false, to entity: Entity) {
        guard let model = entity as? ModelEntity, var component = model.model,
              let tag = entity.components[FurnitureTagComponent.self] else { return }

        // A piece showing a realistic model (catalog product or Sandbox clay
        // shape): the box mesh stays invisible so the model reads through,
        // EXCEPT an `.invalid` overflow flashes a translucent red so a piece
        // that won't fit is still obvious. Selection is signaled by the Clay outline +
        // scale-pop, not box opacity. (valid / tooClose lean on the 2D FitBadge — the
        // honest state is always on screen.)
        if hasRealisticModel(entity) {
            switch state {
            case .invalid:
                let red = UIColor(rgb: 0xB85450)
                var box = PhysicallyBasedMaterial()
                box.baseColor = .init(tint: red)
                box.emissiveColor = .init(color: red)
                box.emissiveIntensity = 0.4
                box.blending = .transparent(opacity: .init(floatLiteral: 0.5))
                component.materials = [box]
            case .tooClose:
                // Amber "too close to call" wash — the same honest uncertain-fit cue
                // the identity box shows, at a lighter opacity so the model's true
                // color still reads through. Without it a too-close model/clay
                // piece was visually identical to a comfortably-fitting one (the 2D
                // FitBadge alone carried the state), quietly softening the very signal
                // we promise never to round to OK.
                var box = PhysicallyBasedMaterial()
                box.baseColor = .init(tint: keptOutlineColor)         // amber #BA7517
                box.emissiveColor = .init(color: keptOutlineColor)
                box.emissiveIntensity = 0.3
                box.blending = .transparent(opacity: .init(floatLiteral: 0.28))
                component.materials = [box]
            case .valid:
                component.materials = [invisibleBoxMaterial()]
            }
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
            material.baseColor = .init(tint: tint(tag.colorCategory, exact: tag.exactColorRGB))
        case .tooClose:
            material.baseColor = .init(tint: tint(tag.colorCategory, exact: tag.exactColorRGB))
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

    // MARK: - Realistic catalog model (visual-only child)

    /// Name of the realistic product-model child attached to a catalog box.
    /// Its presence is what flips the box into "show the model" mode; absent for
    /// detected/manual pieces, where the identity box is the visual.
    static let realisticModelName = "catalog_model"
    /// Name for an APPROXIMATE product mesh child (Tripo / archetype). The fit mode
    /// must survive resize re-fits, where only the entity is in hand — encoding it
    /// in the child's name keeps `scaleRealisticModel` self-contained.
    static let approximateModelName = "catalog_model~approx"

    /// The realistic-model child of a box, whichever fit track attached it.
    static func realisticModelChild(of entity: Entity) -> Entity? {
        entity.findEntity(named: realisticModelName)
            ?? entity.findEntity(named: approximateModelName)
    }

    /// Attach a loaded product model as a VISUAL-ONLY child of the box root, fit to
    /// `dimensions`, and hide the box's own mesh so the realistic model shows. The
    /// model carries no collision / input target, so taps and drags still resolve
    /// to the box (the source of truth). Replaces any existing model child.
    ///
    /// `approximate: true` marks a photo-generated / archetype mesh: footprint
    /// locked 1:1 to `dimensions`, height 1:1 unless the mesh carries clutter on
    /// top (see `CatalogModelLoader.approximateFitTransform`).
    static func attachRealisticModel(_ model: Entity, to box: Entity, dimensions: SIMD3<Float>,
                                     tint: UIColor? = nil, approximate: Bool = false) {
        realisticModelChild(of: box)?.removeFromParent()
        model.name = approximate ? approximateModelName : realisticModelName
        scaleRealisticModel(model, to: dimensions)
        if let tint { applyModelTint(tint, to: model) }
        box.addChild(model)
        setBoxMeshHidden(true, on: box)
    }

    /// Override every descendant mesh's material with a solid PBR tint.
    ///
    /// For the untextured placeholder `.usda` models this is how true
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

    // MARK: - Per-part coloring (Sandbox clay only)

    /// A colorable part of a clay model: a stable `key` (the part's resolved name,
    /// used in `FurnitureAppearance.partColors`) and a friendly `displayName` for
    /// the chip UI. Discovered by walking the model's named `ModelEntity` descendants.
    struct ColorablePart: Equatable, Sendable {
        let key: String
        let displayName: String
    }

    /// The distinct colorable parts of an attached clay model, in a deterministic
    /// order (depth-first, first-seen). Each part is one or more meshes that share a
    /// resolved part name (e.g. a bed's `BedFrame`, `Mattress`, `Pillow`). USD import
    /// order is stable, so the same asset yields the same parts/keys across clones.
    static func colorableParts(of model: Entity) -> [ColorablePart] {
        var seen = Set<String>()
        var parts: [ColorablePart] = []
        forEachColorableMesh(in: model, root: model) { _, key in
            if seen.insert(key).inserted {
                parts.append(ColorablePart(key: key, displayName: humanizePartName(key)))
            }
        }
        return parts
    }

    /// Flatten ONE part's materials to a solid tint, leaving every other part on its
    /// original library material. In-place (no reload) — used for a live swatch/wheel
    /// change. Reverting a part to its ORIGINAL color can't be done in place (the tint
    /// overwrote the material), so the caller reloads a fresh clone for that.
    static func applyPartColor(_ color: UIColor, toPart key: String, in model: Entity) {
        forEachColorableMesh(in: model, root: model) { mesh, partKey in
            guard partKey == key else { return }
            tintMesh(mesh, to: color)
        }
    }

    /// Apply a whole per-part color map onto a (presumed fresh) clone: each keyed
    /// part is flattened to its tint; parts absent from the map keep their ORIGINAL
    /// library materials. Use right after attaching a fresh model clone.
    static func applyPartColors(_ colors: [String: SIMD3<Float>], to model: Entity) {
        forEachColorableMesh(in: model, root: model) { mesh, key in
            guard let rgb = colors[key] else { return }
            tintMesh(mesh, to: UIColor(red: CGFloat(rgb.x), green: CGFloat(rgb.y), blue: CGFloat(rgb.z), alpha: 1))
        }
    }

    /// The colorable part whose actual geometry a world-space ray hits nearest, or
    /// nil if the ray misses every part.
    ///
    /// EXACT per-triangle, not a bounding box: a bed frame's AABB (low base + tall
    /// headboard) encloses the mattress and pillows, so box/convex colliders always
    /// report the frame. Testing the real triangles lets a tap on the pillow pick the
    /// pillow even though it sits inside the frame's bounds. Clay models are low-poly,
    /// so a per-tap triangle sweep is cheap. `origin`/`direction` are in world space.
    static func partKey(forRayOrigin origin: SIMD3<Float>,
                        direction: SIMD3<Float>, in model: Entity) -> String? {
        let dir = normalize(direction)
        var bestT = Float.greatestFiniteMagnitude
        var bestKey: String?
        forEachColorableMesh(in: model, root: model) { mesh, key in
            guard let resource = mesh.model?.mesh else { return }
            let meshWorld = mesh.transformMatrix(relativeTo: nil)
            let contents = resource.contents
            for instance in contents.instances {
                guard let geometry = contents.models[instance.model] else { continue }
                let world = meshWorld * instance.transform
                for part in geometry.parts {
                    let positions = part.positions.elements
                    guard let indices = part.triangleIndices?.elements else { continue }
                    var i = 0
                    while i + 2 < indices.count {
                        let a = transformPoint(world, positions[Int(indices[i])])
                        let b = transformPoint(world, positions[Int(indices[i + 1])])
                        let c = transformPoint(world, positions[Int(indices[i + 2])])
                        if let t = rayTriangleDistance(origin: origin, direction: dir, a, b, c),
                           t < bestT {
                            bestT = t
                            bestKey = key
                        }
                        i += 3
                    }
                }
            }
        }
        return bestKey
    }

    private static func transformPoint(_ m: simd_float4x4, _ p: SIMD3<Float>) -> SIMD3<Float> {
        let v = m * SIMD4<Float>(p, 1)
        return SIMD3(v.x, v.y, v.z)
    }

    /// Möller–Trumbore ray/triangle intersection (double-sided). Returns the ray
    /// parameter `t` (distance along `direction`) of a forward hit, or nil.
    private static func rayTriangleDistance(
        origin: SIMD3<Float>, direction: SIMD3<Float>,
        _ v0: SIMD3<Float>, _ v1: SIMD3<Float>, _ v2: SIMD3<Float>
    ) -> Float? {
        let eps: Float = 1e-7
        let edge1 = v1 - v0, edge2 = v2 - v0
        let pvec = cross(direction, edge2)
        let det = dot(edge1, pvec)
        if abs(det) < eps { return nil }                 // ray parallel to triangle
        let invDet = 1 / det
        let tvec = origin - v0
        let u = dot(tvec, pvec) * invDet
        if u < 0 || u > 1 { return nil }
        let qvec = cross(tvec, edge1)
        let v = dot(direction, qvec) * invDet
        if v < 0 || u + v > 1 { return nil }
        let t = dot(edge2, qvec) * invDet
        return t > eps ? t : nil
    }

    /// Walk every `ModelEntity` with materials, handing the closure each mesh and its
    /// resolved part key (the nearest meaningful ancestor name, or its own name).
    private static func forEachColorableMesh(
        in entity: Entity, root: Entity, _ body: (ModelEntity, String) -> Void
    ) {
        if let mesh = entity as? ModelEntity, let component = mesh.model, !component.materials.isEmpty {
            body(mesh, partKey(for: entity, root: root))
        }
        for child in entity.children { forEachColorableMesh(in: child, root: root, body) }
    }

    /// Overwrite a mesh's materials with one solid clay PBR tint.
    private static func tintMesh(_ mesh: ModelEntity, to color: UIColor) {
        guard var component = mesh.model else { return }
        var m = PhysicallyBasedMaterial()
        m.baseColor = .init(tint: color)
        m.roughness = .init(floatLiteral: 0.85)
        m.metallic = .init(floatLiteral: 0)
        component.materials = component.materials.map { _ in m }
        mesh.model = component
    }

    /// The colorable-part key for a mesh: the nearest ancestor (including itself, up
    /// to but excluding `root`) with a meaningful name, so sibling meshes of one
    /// logical part (e.g. several `Mattress` submeshes) share a key. Falls back to
    /// the mesh's own name, or `"Part"`.
    private static func partKey(for entity: Entity, root: Entity) -> String {
        var node: Entity? = entity
        while let n = node, n !== root {
            if isMeaningfulPartName(n.name) { return n.name }
            node = n.parent
        }
        return entity.name.isEmpty ? "Part" : entity.name
    }

    /// Names USD import assigns to anonymous group/mesh prims, which carry no
    /// product meaning and should never become a part key on their own.
    private static func isMeaningfulPartName(_ name: String) -> Bool {
        if name.isEmpty || name == realisticModelName || name == approximateModelName { return false }
        let lower = name.lowercased()
        return !(lower == "mesh" || lower == "geom" || lower == "rootnode"
            || lower == "scene" || lower.hasPrefix("qgeom"))
    }

    /// Turn a raw part key (`"BedFrame_Cube_001"`) into a friendly label
    /// (`"Bed Frame"`): split camelCase + underscores, drop primitive/index tokens.
    static func humanizePartName(_ raw: String) -> String {
        // camelCase → spaced, underscores → spaces.
        var spaced = ""
        for (i, ch) in raw.enumerated() {
            if ch == "_" { spaced.append(" "); continue }
            if ch.isUppercase, i > 0, let last = spaced.last, !last.isUppercase, last != " " {
                spaced.append(" ")
            }
            spaced.append(ch)
        }
        let drop: Set<String> = ["cube", "mesh", "sphere", "plane", "object", "geo", "geom"]
        let tokens = spaced.split(separator: " ").map(String.init).filter { t in
            !drop.contains(t.lowercased()) && Int(t) == nil
        }
        let label = tokens.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return label.isEmpty ? raw : label.capitalized
    }

    /// Re-fit an already-attached model to new `dimensions` (called on resize). Safe
    /// to call when no model is attached. An approximate mesh (named at attach) uses
    /// the footprint-primary fit with auto ground-plane rotation; anything else uses
    /// the exact per-axis fit.
    static func scaleRealisticModel(_ model: Entity, to dimensions: SIMD3<Float>) {
        // Measure intrinsic bounds with the model's own transform reset, so the fit
        // is computed from the raw asset every time (resize re-fits from scratch).
        model.transform = .identity
        let bounds = model.visualBounds(relativeTo: model)
        if model.name == approximateModelName {
            let fit = CatalogModelLoader.approximateFitTransform(
                modelExtents: bounds.extents, modelCenter: bounds.center, targetDimensions: dimensions)
            model.orientation = simd_quatf(angle: fit.yRotation, axis: SIMD3(0, 1, 0))
            model.scale = fit.scale
            model.position = fit.position
        } else {
            let fit = CatalogModelLoader.fitTransform(
                modelExtents: bounds.extents, modelCenter: bounds.center, targetDimensions: dimensions)
            model.scale = fit.scale
            model.position = fit.position
        }
    }

    /// The model's intrinsic bounding-box extents (meters), measured with its own
    /// transform reset — i.e. the raw authored size, before any fit. Used by the
    /// Verified-track zero-scaling guard to confirm a real product USDZ is modeled at
    /// true catalog scale before it's allowed to render.
    static func nativeExtents(of model: Entity) -> SIMD3<Float> {
        model.transform = .identity
        return model.visualBounds(relativeTo: model).extents
    }

    /// Hide or show the box's own mesh by swapping its materials' opacity, WITHOUT
    /// touching its `CollisionComponent` (so hit-testing is unaffected). Used to
    /// reveal the realistic model child while the box stays the interactive proxy.
    static func setBoxMeshHidden(_ hidden: Bool, on entity: Entity) {
        guard let model = entity as? ModelEntity, var component = model.model else { return }
        if hidden {
            component.materials = component.materials.map { _ in invisibleBoxMaterial() }
        } else {
            component.materials = component.materials.map { _ in
                var clear = PhysicallyBasedMaterial()
                clear.blending = .transparent(opacity: .init(floatLiteral: 1))
                return clear
            }
        }
        model.model = component
    }

    /// A genuinely non-rendering material for a box hidden beneath a realistic model.
    /// Uses `UnlitMaterial`, NOT a transparent `PhysicallyBasedMaterial`: a PBR
    /// surface at opacity 0 still catches specular highlights and leaves a faint
    /// "glass box" ghost framing the model. Unlit ignores lighting, so opacity 0
    /// is truly invisible.
    private static func invisibleBoxMaterial() -> UnlitMaterial {
        var m = UnlitMaterial(color: .clear)
        m.blending = .transparent(opacity: .init(floatLiteral: 0))
        return m
    }

    /// Whether a box currently shows its realistic model child.
    static func hasRealisticModel(_ entity: Entity) -> Bool {
        realisticModelChild(of: entity) != nil
    }

    /// Remove the realistic model child (returning to the identity box). No-op
    /// when none is attached.
    static func removeRealisticModel(from entity: Entity) {
        realisticModelChild(of: entity)?.removeFromParent()
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

    /// Material in the piece's true color. `opacity` drives transparent
    /// blending — translucent while pending, solid once kept.
    private static func material(for footprint: FurnitureFootprint, opacity: Float) -> PhysicallyBasedMaterial {
        var m = PhysicallyBasedMaterial()
        m.baseColor = .init(tint: tint(footprint.appearance.colorCategory,
                                       exact: footprint.appearance.exactColorRGB))
        m.roughness = .init(floatLiteral: footprint.appearance.materialClass.roughness)
        m.metallic = .init(floatLiteral: 0)
        if opacity < 1 {
            m.blending = .transparent(opacity: .init(floatLiteral: opacity))
        }
        return m
    }

    /// The **true** base tint for a piece — the honesty promise. `exact` (a
    /// catalog product's known manufacturer sRGB) wins when present; otherwise
    /// the perceptual `category`'s `representativeRGB` (the best we know for a
    /// detected piece). Never lightened, warmed, or stylized.
    static func tint(_ category: FurnitureColorCategory, exact: SIMD3<Float>? = nil) -> UIColor {
        let rgb = exact ?? category.representativeRGB
        return UIColor(red: CGFloat(rgb.x), green: CGFloat(rgb.y), blue: CGFloat(rgb.z), alpha: 1)
    }

    /// Re-tint a static (viewing-mode) furniture entity, preserving its pending
    /// translucency. Editing mode re-tints via `applyPlacementState` (which
    /// also carries the fit-state coloring).
    static func retint(_ entity: Entity, footprint: FurnitureFootprint) {
        guard let model = entity as? ModelEntity, var component = model.model else { return }
        // A shown realistic model keeps the box mesh invisible (catalog product
        // or a Sandbox clay shape).
        if hasRealisticModel(entity) {
            component.materials = [invisibleBoxMaterial()]
            model.model = component
            return
        }
        component.materials = [material(for: footprint, opacity: defaultOpacity)]
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
