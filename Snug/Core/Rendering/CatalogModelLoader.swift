import RealityKit
import simd

/// Loads and caches bundled catalog USDZ product models for BUY-mode rendering,
/// and computes how to fit a loaded model into a footprint's real dimensions.
///
/// ## Why an actor, and why the model is visual-only
/// Loading is async (`Entity(named:in:)`, iOS 18+) so it never blocks the main
/// thread / hitches the diorama. The loaded model is added as a VISUAL-ONLY child
/// of the furniture box root — it carries no `CollisionComponent` /
/// `InputTargetComponent`, so taps, drags, pinch-resize, and the fit math all stay
/// driven by the box (the source of truth). Detected/manual furniture and PLAY
/// mode never touch this; only a placed catalog product in BUY shows a model.
actor CatalogModelLoader {
    static let shared = CatalogModelLoader()

    /// Template entities, loaded once per asset name. Callers get a clone so each
    /// placed instance is independent (an entity can't be parented twice).
    private var cache: [String: Entity] = [:]
    /// Asset names that failed to load (missing from the bundle / unreadable), so
    /// we don't retry every BUY swap — the caller keeps the stylized box.
    private var failed: Set<String> = []

    /// A fresh clone of the named bundled USDZ model, or nil when the asset isn't
    /// bundled or fails to load (→ caller falls back to the box). Cached so each
    /// product loads from disk only once.
    func model(named name: String) async -> Entity? {
        if let template = cache[name] { return template.clone(recursive: true) }
        if failed.contains(name) { return nil }
        do {
            // iOS 18+ async, non-blocking load from the main bundle.
            let entity = try await Entity(named: name, in: .main)
            cache[name] = entity
            return entity.clone(recursive: true)
        } catch {
            failed.insert(name)
            return nil
        }
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
