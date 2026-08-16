import RealityKit
import simd

/// Loads and caches bundled catalog USDZ product models for the diorama, and
/// computes how to fit a loaded model into a footprint's real dimensions.
///
/// ## Why an actor, and why the model is visual-only
/// Loading is async (`Entity(named:in:)`, iOS 18+) so it never blocks the main
/// thread / hitches the diorama. The loaded model is added as a VISUAL-ONLY child
/// of the furniture box root — it carries no `CollisionComponent` /
/// `InputTargetComponent`, so taps, drags, pinch-resize, and the fit math all stay
/// driven by the box (the source of truth). Detected/manual furniture never touches
/// this; only a placed catalog product (or a Sandbox clay shape) shows a model.
actor CatalogModelLoader {
    static let shared = CatalogModelLoader()

    /// Template entities, loaded once per asset name. Callers get a clone so each
    /// placed instance is independent (an entity can't be parented twice).
    private var cache: [String: Entity] = [:]
    /// Asset names that failed to load (missing from the bundle / unreadable), so
    /// we don't retry every placement — the caller keeps the identity box.
    private var failed: Set<String> = []
    /// In-flight loads keyed by asset name so concurrent first-requests for the
    /// same model share ONE disk read instead of each starting its own (actor
    /// reentrancy across the load `await`). Cleared into `cache`/`failed` when the
    /// load settles.
    private var inFlight: [String: Task<Entity?, Never>] = [:]

    /// A fresh clone of the named bundled USDZ model, or nil when the asset isn't
    /// bundled or fails to load (→ caller falls back to the box). Cached so each
    /// product loads from disk only once, even under concurrent first-loads.
    func model(named name: String) async -> Entity? {
        // Entity.clone is MainActor-isolated (scene-graph mutation) — hop for the
        // clone only; the cache stays actor-protected.
        if let template = cache[name] {
            return await MainActor.run { template.clone(recursive: true) }
        }
        if failed.contains(name) { return nil }

        // Coalesce concurrent first-loads of the same asset into one disk read:
        // without this, actor reentrancy across the load `await` lets several
        // callers all miss the cache above and each load the USDZ separately.
        let task: Task<Entity?, Never>
        if let existing = inFlight[name] {
            task = existing
        } else {
            // iOS 18+ async, non-blocking load from the main bundle.
            task = Task { try? await Entity(named: name, in: .main) }
            inFlight[name] = task
        }
        let loaded = await task.value

        // The first caller to resume records the terminal state and frees the
        // in-flight slot — both in one actor step (no `await` between them), so a
        // late caller can't slip in and kick off a second load. Later awaiters of
        // the same task fall through and just clone the shared template.
        if inFlight[name] != nil {
            inFlight[name] = nil
            if let loaded { cache[name] = loaded } else { failed.insert(name) }
        }

        guard let loaded else { return nil }
        return await MainActor.run { loaded.clone(recursive: true) }
    }

    // MARK: - Pure fit math (unit-tested, no RealityKit types)

    /// The single place the two coordinate conventions meet — re-express a
    /// `FurnitureFootprint`'s `dimensions` (packed `(x: width, y: depth, z: height)`)
    /// in RealityKit's Y-up model-axis order (`(x: width, y: height, z: depth)`).
    /// Both `fitTransform` and `nativeSizeDeviation` MUST route through here so the
    /// mapping can never silently drift between them (change it once — e.g. for a
    /// future Z-up asset pipeline — and the Verified zero-scaling guard stays honest).
    nonisolated static func targetInModelAxes(_ dimensions: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3(dimensions.x, dimensions.z, dimensions.y)   // width, height (fp Z), depth (fp Y)
    }

    /// The per-axis scale and local position that fit a model — given its intrinsic
    /// (untransformed) bounding-box `extents` and `center` — into a box of
    /// `targetDimensions`, centered on the box origin. The axis remap lives in
    /// `targetInModelAxes`; the position re-centers the (possibly off-origin) model
    /// onto the box center, matching the box mesh centered on `worldPosition`.
    nonisolated static func fitTransform(
        modelExtents: SIMD3<Float>,
        modelCenter: SIMD3<Float>,
        targetDimensions: SIMD3<Float>
    ) -> (scale: SIMD3<Float>, position: SIMD3<Float>) {
        let safe: (Float) -> Float = { abs($0) < 1e-5 ? 1 : $0 }
        let target = targetInModelAxes(targetDimensions)
        let scale = SIMD3<Float>(
            target.x / safe(modelExtents.x),
            target.y / safe(modelExtents.y),
            target.z / safe(modelExtents.z)
        )
        // Re-center: cancel the model's bounds offset, in the now-scaled space.
        let position = -modelCenter * scale
        return (scale, position)
    }

    // MARK: - Approximate-track fit (pure, unit-tested)

    /// Asset-name prefixes of APPROXIMATE product meshes: photo-generated Tripo
    /// meshes (`tripo_<ASIN>`) and Quaternius category archetypes. These are not
    /// authored at true scale (Tripo outputs normalized, often 90°-rotated
    /// geometry), so they use `approximateFitTransform` instead of the Verified
    /// 1:1-or-refuse guard. The fit/collision box ALWAYS keeps the catalog's real
    /// dimensions — only the visual mesh is approximate.
    nonisolated static func isApproximateAsset(_ name: String) -> Bool {
        name.hasPrefix("tripo_") || name.hasPrefix("quaternius_")
    }

    /// How much taller than the real product a mesh may be (proportionally) and
    /// still be treated as CLEAN and snapped to the exact catalog height. Beyond
    /// this the extra height is taken as photo clutter modeled on top of the piece
    /// (a monitor on a desk); the mesh then keeps its proportional height so the
    /// furniture body stays true-size and the clutter pokes above — taller is
    /// honest, squashing the piece to hide the clutter is not.
    static let clutterHeightTolerance: Float = 1.10

    /// Fit an approximate product mesh into the catalog's real dimensions:
    ///
    /// - FOOTPRINT (width × depth) is always exactly 1:1 to the catalog dims —
    ///   that's the fit-critical promise. The ground-plane orientation (0° or 90°
    ///   yaw) is chosen automatically: Tripo does not preserve our width/depth
    ///   convention, so we keep whichever rotation distorts the footprint least.
    /// - HEIGHT is exactly 1:1 too, UNLESS the mesh is proportionally taller than
    ///   the real product by more than `clutterHeightTolerance` — then it keeps
    ///   its (taller) proportional height. Never shorter than real.
    ///
    /// Returns the yaw to apply plus the LOCAL-axis scale and the local position
    /// that re-centers the (possibly off-origin) mesh onto the box origin under
    /// that yaw. Transform order is RealityKit's T·R·S, so `position` must cancel
    /// the ROTATED scaled-center offset.
    nonisolated static func approximateFitTransform(
        modelExtents: SIMD3<Float>,
        modelCenter: SIMD3<Float>,
        targetDimensions: SIMD3<Float>
    ) -> (yRotation: Float, scale: SIMD3<Float>, position: SIMD3<Float>) {
        let safe: (Float) -> Float = { abs($0) < 1e-5 ? 1 : $0 }
        let target = targetInModelAxes(targetDimensions)   // (x: w, y: h, z: d)
        let ex = safe(modelExtents.x), ey = safe(modelExtents.y), ez = safe(modelExtents.z)

        // Footprint factors for both ground-plane orientations. At 90° yaw the
        // mesh's local X spans world depth and local Z spans world width.
        let straight = (w: target.x / ex, d: target.z / ez)
        let rotated  = (w: target.x / ez, d: target.z / ex)
        let spread: ((w: Float, d: Float)) -> Float = { max($0.w, $0.d) / min($0.w, $0.d) }
        let useRotation = spread(rotated) < spread(straight)
        let foot = useRotation ? rotated : straight
        let yRotation: Float = useRotation ? .pi / 2 : 0

        // Height: proportional to the footprint (geometric mean keeps it unbiased
        // when width and depth stretch differently); snap to the exact catalog
        // height unless the mesh is clutter-tall.
        let footUniform = (foot.w * foot.d).squareRoot()
        let proportionalHeight = ey * footUniform
        let heightScale = proportionalHeight <= target.y * clutterHeightTolerance
            ? target.y / ey          // clean mesh → true 1:1 height
            : footUniform            // clutter on top → taller, never squashed

        // LOCAL-axis scale: under 90° yaw, local X must carry world depth and
        // local Z world width.
        let scale = useRotation
            ? SIMD3<Float>(foot.d, heightScale, foot.w)
            : SIMD3<Float>(foot.w, heightScale, foot.d)

        // Re-center: cancel the mesh's bounds offset in scaled-then-rotated space.
        let rotation = simd_quatf(angle: yRotation, axis: SIMD3(0, 1, 0))
        var position = -rotation.act(modelCenter * scale)
        // A clutter-tall mesh is taller than the box it's centered in, so pure
        // centering would sink half the overflow below the floor. Lift it so the
        // mesh bottom stays on the box bottom (the floor) and the clutter pokes
        // above — the furniture body keeps its true height. Yaw is about Y, so
        // adjusting Y after the rotation is safe.
        position.y += max(0, (ey * heightScale - target.y) / 2)
        return (yRotation, scale, position)
    }

    // MARK: - Verified-track zero-scaling guard (pure, unit-tested)

    /// Max tolerated deviation (meters) between a Verified product model's native
    /// size and its catalog dimensions. A real manufacturer asset is placed 1:1, so
    /// anything past this is a mis-authored / mis-categorized asset, not something to
    /// silently stretch. See `Resources/Models/README.md`.
    static let verifiedModelTolerance: Float = 0.01   // 1 cm

    /// The largest per-axis gap (meters) between a model's intrinsic bounding-box
    /// `modelExtents` and the catalog's real `targetDimensions`, under the SAME axis
    /// mapping `fitTransform` uses (via `targetInModelAxes`, so the two can't drift).
    /// `> verifiedModelTolerance` ⇒ the model is NOT authored at true scale and must
    /// be refused (the caller falls back to the honest box), never warped to fit.
    nonisolated static func nativeSizeDeviation(
        modelExtents: SIMD3<Float>,
        targetDimensions: SIMD3<Float>
    ) -> Float {
        let target = targetInModelAxes(targetDimensions)
        return max(abs(modelExtents.x - target.x),
                   max(abs(modelExtents.y - target.y),
                       abs(modelExtents.z - target.z)))
    }
}
