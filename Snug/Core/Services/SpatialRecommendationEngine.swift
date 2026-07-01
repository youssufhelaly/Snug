import Foundation
import simd

/// Reverse lookup from a resized **Ideation-Sandbox** piece to real **Verified**
/// catalog products of a similar footprint — the local, offline half of the
/// "design with digital clay → find real furniture that fits" bridge (IDEAS.md).
///
/// ## Deliberately pure and room-free
/// Like `FitService`, this is a pure, deterministic function with no UI and no
/// RealityKit types, so it unit-tests without fixtures or a running scene. It
/// answers exactly one question: *which Verified products are dimensionally
/// similar to the size the user sculpted?* It does **not** decide whether any of
/// them actually fits the room — that is `FitService`'s asymmetric, room-aware
/// job, run per candidate on the product's TRUE specs and shown via the
/// four-state fit badge. Keeping fitness out of here means the four fit states
/// stay defined in exactly one place; a matcher that also pre-judged fit would be
/// a second, divergent source of truth.
///
/// ## Input is LOCAL, unrotated extents
/// `targetDimensions` must be the piece's intrinsic `(width, depth, height)` in
/// meters — the same `(x, y, z)` convention as `CatalogItem.dimensions` and
/// `FurnitureCategory.defaultDimensions` — NOT a world-aligned bounding box. A
/// rotated sandbox sofa's world AABB swaps width/depth; feeding that in would
/// hunt for a deep narrow bench instead of a sofa. The caller is responsible for
/// passing the entity's unrotated local extents.
enum SpatialRecommendationEngine {

    /// One Verified product that matches a queried footprint, with the data the UI
    /// needs to rank and to stay honest about size.
    struct Match: Equatable, Sendable, Identifiable {
        let item: CatalogItem
        /// Euclidean distance (meters) between the product's real dimensions and
        /// the queried target, under the shared `(width, depth, height)` axes.
        /// Smaller is more similar; this is the ranking key.
        let dimensionDistance: Float
        /// True when the product is larger than the target on ANY axis (beyond a
        /// hair). Surfaced for honest UI labelling, **never** used to drop or
        /// down-rank the match — whether an over-size product jams against a real
        /// wall depends on the room, which only `FitService` knows.
        let exceedsTargetOnAnyAxis: Bool

        var id: String { item.id }
    }

    /// Verified products whose footprint is "similar" to a resized Sandbox piece.
    ///
    /// - Parameters:
    ///   - targetDimensions: the sandbox piece's local, unrotated
    ///     `(width, depth, height)` in meters (see the type doc — not a world AABB).
    ///   - category: hard gate. A product must share this category to be
    ///     considered — a coffee table never surfaces for a sofa query, however
    ///     close the numbers. This is a filter, never a weighted score.
    ///   - items: the Verified catalog to search (e.g. `CatalogService.items`).
    ///   - tolerance: the symmetric per-axis window, in meters. A product matches
    ///     only if it is within `tolerance` on EVERY axis. Defaults to the fit
    ///     system's global error margin so "similar enough to suggest" is the same
    ///     scale as "close enough that the geometry is uncertain" (IDEAS.md).
    /// - Returns: matches sorted by ascending `dimensionDistance`, ties broken by
    ///   `id` for deterministic output. Over-size matches inside the window are
    ///   included (flagged via `exceedsTargetOnAnyAxis`), not hidden.
    static func matches(
        forTarget targetDimensions: SIMD3<Float>,
        category: FurnitureCategory,
        in items: [CatalogItem],
        tolerance: Float = FitConfiguration.errorMargin
    ) -> [Match] {
        items
            .filter { $0.category == category }
            .compactMap { item -> Match? in
                let delta = item.dimensions - targetDimensions
                let perAxis = max(abs(delta.x), max(abs(delta.y), abs(delta.z)))
                guard perAxis <= tolerance else { return nil }
                // ~0.1 mm slack so an exact-size product isn't flagged over-size.
                let exceeds = delta.x > 1e-4 || delta.y > 1e-4 || delta.z > 1e-4
                return Match(
                    item: item,
                    dimensionDistance: simd_length(delta),
                    exceedsTargetOnAnyAxis: exceeds
                )
            }
            .sorted { lhs, rhs in
                lhs.dimensionDistance == rhs.dimensionDistance
                    ? lhs.item.id < rhs.item.id
                    : lhs.dimensionDistance < rhs.dimensionDistance
            }
    }
}
