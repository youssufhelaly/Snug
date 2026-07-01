import Foundation
import simd

/// A generic, unbranded **Ideation-Sandbox** shape — the "digital clay" half of
/// the dual-catalog design (IDEAS.md). Deliberately the *opposite* of a
/// `CatalogItem`: it carries a style and a starting size but **no price, retailer,
/// affiliate link, or true color**, because it makes no purchase claim. The user
/// drops one in and reshapes it freely to fit their space; the
/// `SpatialRecommendationEngine` later bridges the chosen size back to real
/// Verified products.
///
/// Kept in its own type + its own `sandbox_assets.json` so the Verified track
/// (`CatalogItem` / `catalog.json`) stays a strict, price-bearing, 1:1 zone with
/// zero risk of an elastic generic shape leaking into it.
///
/// `baseDimensions` packs `(width, depth, height)` in meters — the same
/// `(x, y, z)` convention as `CatalogItem.dimensions` and
/// `FurnitureFootprint.dimensions`.
struct SandboxAsset: Codable, Equatable, Sendable, Identifiable {
    let id: String
    let name: String
    let category: FurnitureCategory
    let style: SandboxStyle
    /// The starting clay block `(width, depth, height)` in meters. The user
    /// reshapes from here; nothing about this size is a claim — it's just a sketch.
    let baseDimensions: SIMD3<Float>
    /// Stylized tint bucket for the diorama box. There is intentionally NO
    /// `trueColorRGB`: an ideation piece never renders BUY true-color, because it
    /// isn't a real product.
    let colorCategory: FurnitureColorCategory
    let material: FurnitureMaterialClass
    /// Bundled USDZ basename (no extension) — a generic CC0 shape from the
    /// `tools/catalog/` pipeline. The diorama renders it as elastic "digital clay":
    /// per-axis stretched to the user's chosen size (distortion is a *feature* here,
    /// so it skips the Verified track's 1:1 zero-scaling guard) and tinted a uniform
    /// clay tone so it never reads as a real product. `nil` → falls back to the box.
    let modelAssetName: String?
}

/// Coarse visual-style tag on a sandbox shape — used as a browse filter and, later,
/// as one input to the (remote, V2/V3) style/visual ranking. The local dimensional
/// reverse-search ignores it; only `category` + size drive that.
enum SandboxStyle: String, Codable, CaseIterable, Sendable {
    case midCentury = "mid_century"
    case minimalist
    case scandinavian
    case industrial
    case traditional
    case bohemian

    var displayName: String {
        switch self {
        case .midCentury:   return "Mid-Century"
        case .minimalist:   return "Minimalist"
        case .scandinavian: return "Scandinavian"
        case .industrial:   return "Industrial"
        case .traditional:  return "Traditional"
        case .bohemian:     return "Bohemian"
        }
    }
}

extension SandboxAsset {
    /// A placed footprint for this sandbox shape at a floor position, reusing the
    /// exact furniture rails the rest of the app runs on.
    ///
    /// Tagged with `sandboxAssetID` (and a `nil` `catalogItemID`), so the diorama
    /// renders it as the elastic stylized box — never the verified realistic model
    /// path — and the selection UI shows the *ideation* affordances (no price, a
    /// "find real matches" bridge) instead of a retailer link.
    ///
    /// Confidence is `.manual`: the size is whatever the user sculpted, so when
    /// this piece acts as an obstacle for *other* placements `FitService` widens
    /// its band 1.5× (honest about a user-chosen, unmeasured size). `isKept` is
    /// true — clay you've dropped still occupies floor.
    func makeFootprint(at floorXZ: SIMD2<Float>, yRotation: Float = 0) -> FurnitureFootprint {
        FurnitureFootprint(
            category: category,
            worldPosition: SIMD3(floorXZ.x, baseDimensions.z / 2, floorXZ.y),
            dimensions: baseDimensions,
            yRotation: yRotation,
            appearance: FurnitureAppearance(
                colorCategory: colorCategory,
                materialClass: material
            ),
            detectionConfidence: .manual,
            isCleared: false,
            isKept: true,
            sandboxAssetID: id
        )
    }
}
