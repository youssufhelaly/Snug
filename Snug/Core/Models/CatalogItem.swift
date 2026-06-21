import Foundation
import simd

/// A purchasable furniture product in the Snug catalog.
///
/// This is the BUY-mode counterpart to `FurnitureFootprint`: where a footprint
/// is a *placed* piece in a room (detected existing furniture or a dropped
/// product), a `CatalogItem` is the *product definition* — real manufacturer
/// dimensions, a true color, a price, and the retailer link we out-link to.
///
/// Per CLAUDE.md it is a plain `Codable`/`Equatable`/`Sendable` value type, never
/// a SwiftData `@Model`. V1 ships a bundled `catalog.json`; the `CatalogSource`
/// protocol lets a remote catalog replace the bundle later without touching this
/// type or any consumer.
///
/// ## Coordinate / unit conventions (match the rest of the app)
/// - `dimensions` packs `(width, depth, height)` as `(x, y, z)` in **meters** —
///   the same convention as `FurnitureCategory.defaultDimensions` and
///   `FurnitureFootprint.dimensions`. Unlike detected furniture (sized from
///   priors and back-projection), these are the product's *real* spec, so a
///   placed catalog item is trusted at the standard fit margin.
/// - `trueColorRGB` is the product's real sRGB color (0–1 components) for the
///   true-color promise of BUY mode. `colorCategory` is the perceptual bucket
///   used for the PLAY-mode tint and for color filtering — keeping both means
///   browse/filter and rendering never disagree.
struct CatalogItem: Codable, Equatable, Sendable, Identifiable {
    /// Stable catalog SKU. A `String` (not `UUID`) so the bundled JSON and a
    /// future remote catalog can use human-meaningful, retailer-aligned ids.
    let id: String
    let name: String
    let brand: String
    let category: FurnitureCategory

    /// Real manufacturer `(width, depth, height)` in meters, `(x, y, z)`.
    let dimensions: SIMD3<Float>
    /// True product color for BUY mode (sRGB, 0–1 components).
    let trueColorRGB: SIMD3<Float>
    /// Perceptual color bucket for PLAY tint + browse filtering.
    let colorCategory: FurnitureColorCategory
    let material: FurnitureMaterialClass

    /// Price in the minor unit (cents) to avoid float rounding on money.
    let priceCents: Int
    /// ISO 4217 currency code, e.g. `"USD"`. Formatting lives in the view layer.
    let currencyCode: String

    let retailerName: String
    /// The product page we out-link to (with disclosure — CLAUDE.md hard rule:
    /// affiliate relationships are disclosed in UI copy).
    let productURL: URL
    /// Affiliate tag appended at out-link time, or nil for a plain link.
    let affiliateTag: String?

    /// Bundled asset names. `nil` falls back to the stylized primitive box the
    /// diorama already builds for detected furniture, so the catalog works before
    /// every SKU has art.
    let thumbnailAssetName: String?
    let modelAssetName: String?

    let inStock: Bool
    /// Renter-safe gate (CLAUDE.md ICP): no-drill, no-paint, removable,
    /// deposit-safe. V1 only surfaces items where this is true.
    let isRemovable: Bool

    init(
        id: String,
        name: String,
        brand: String,
        category: FurnitureCategory,
        dimensions: SIMD3<Float>,
        trueColorRGB: SIMD3<Float>,
        colorCategory: FurnitureColorCategory,
        material: FurnitureMaterialClass,
        priceCents: Int,
        currencyCode: String = "USD",
        retailerName: String,
        productURL: URL,
        affiliateTag: String? = nil,
        thumbnailAssetName: String? = nil,
        modelAssetName: String? = nil,
        inStock: Bool = true,
        isRemovable: Bool = true
    ) {
        self.id = id
        self.name = name
        self.brand = brand
        self.category = category
        self.dimensions = dimensions
        self.trueColorRGB = trueColorRGB
        self.colorCategory = colorCategory
        self.material = material
        self.priceCents = priceCents
        self.currencyCode = currencyCode
        self.retailerName = retailerName
        self.productURL = productURL
        self.affiliateTag = affiliateTag
        self.thumbnailAssetName = thumbnailAssetName
        self.modelAssetName = modelAssetName
        self.inStock = inStock
        self.isRemovable = isRemovable
    }

    /// The retailer link to actually open, with the affiliate tag appended when
    /// present. Falls back to the bare `productURL` if the URL can't be rebuilt.
    var outboundURL: URL {
        guard let affiliateTag,
              var components = URLComponents(url: productURL, resolvingAgainstBaseURL: false)
        else { return productURL }
        var query = components.queryItems ?? []
        query.append(URLQueryItem(name: "tag", value: affiliateTag))
        components.queryItems = query
        return components.url ?? productURL
    }
}
