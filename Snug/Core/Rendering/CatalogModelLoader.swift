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

    /// The per-axis scale and local position that fit a model — given its intrinsic
    /// (untransformed) bounding-box `extents` and `center` — into a box of
    /// `targetDimensions`, centered on the box origin.
    ///
    /// Axis mapping (the one place the two conventions meet): RealityKit is Y-up
    /// (`extents` = X width, Y height, Z depth); a `FurnitureFootprint`'s
    /// `dimensions` packs `(x: width, y: depth, z: height)`. So the model's Y maps
    /// to the footprint's Z (height) and the model's Z to the footprint's Y (depth).
    /// The position re-centers the (possibly off-origin) model onto the box center,
    /// matching the box mesh, which is centered on `worldPosition`.
    nonisolated static func fitTransform(
        modelExtents: SIMD3<Float>,
        modelCenter: SIMD3<Float>,
        targetDimensions: SIMD3<Float>
    ) -> (scale: SIMD3<Float>, position: SIMD3<Float>) {
        let safe: (Float) -> Float = { abs($0) < 1e-5 ? 1 : $0 }
        let scale = SIMD3<Float>(
            targetDimensions.x / safe(modelExtents.x),   // width  → model X
            targetDimensions.z / safe(modelExtents.y),   // height → model Y (up)
            targetDimensions.y / safe(modelExtents.z)    // depth  → model Z
        )
        // Re-center: cancel the model's bounds offset, in the now-scaled space.
        let position = -modelCenter * scale
        return (scale, position)
    }
}
