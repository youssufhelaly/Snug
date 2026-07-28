import Foundation
import SwiftUI
import simd

/// Phase 2 furniture-identity value types.
///
/// These are the app's canonical, capture-method-agnostic representation of
/// existing furniture detected in a room. Per CLAUDE.md's data-model rules they
/// are plain `Codable`/`Equatable`/`Sendable` value types — NOT SwiftData
/// `@Model`s — so they can be embedded inside `RoomModel` and ride its existing
/// JSON-blob persistence (see `SnugSchema`). Nothing here imports ARKit or
/// Vision: detection produces these from frame data at the edges and everything
/// downstream (placement, the diorama, `FitService`) consumes them.
///
/// ## Coordinate convention (read before touching spatial code)
/// ARKit and `RoomModel` are both **Y-up**: Y is altitude. To keep a single
/// stable convention for a furniture box, `dimensions` packs the footprint and
/// height as `(x: width, y: depth, z: height)` — i.e. `dimensions.x`/`.y` are
/// the two *floor-plane* extents and `dimensions.z` is the *vertical* extent.
/// `worldPosition.y` is therefore altitude (the floor-snapped base). This is the
/// same convention `FurniturePlacementService` and `FurnitureEntityBuilder` use;
/// do not assume Z-up.

// MARK: - Observation

/// The raw output of Vision detection for a single furniture piece in one frame.
struct FurnitureObservation: Codable, Equatable, Sendable {
    let id: UUID
    let category: FurnitureCategory
    /// Vision model confidence, 0.0–1.0.
    let confidence: Float
    /// Normalized Vision bounding box (0–1 coordinates, origin bottom-left per
    /// Vision's convention).
    let boundingBox: CGRect
    let frameTimestamp: TimeInterval
    /// Perceptual color sampled for this detection at the detection edge. `.other`
    /// when the frame couldn't be read (or before device sampling lands). Consensus
    /// aggregates these across a track into the footprint's persisted color.
    let colorCategory: FurnitureColorCategory

    init(
        id: UUID = UUID(),
        category: FurnitureCategory,
        confidence: Float,
        boundingBox: CGRect,
        frameTimestamp: TimeInterval,
        colorCategory: FurnitureColorCategory = .other
    ) {
        self.id = id
        self.category = category
        self.confidence = confidence
        self.boundingBox = boundingBox
        self.frameTimestamp = frameTimestamp
        self.colorCategory = colorCategory
    }

    /// A copy with a different sampled color (the rest of the observation is the
    /// real frame's). Used by consensus to stamp the track-aggregated color onto
    /// the representative observation it returns.
    func withColorCategory(_ colorCategory: FurnitureColorCategory) -> FurnitureObservation {
        FurnitureObservation(
            id: id,
            category: category,
            confidence: confidence,
            boundingBox: boundingBox,
            frameTimestamp: frameTimestamp,
            colorCategory: colorCategory
        )
    }
}

// MARK: - Category

/// Furniture categories we detect. Raw values map directly to the bundled
/// CoreML model's class labels.
enum FurnitureCategory: String, Codable, CaseIterable, Sendable {
    case sofa
    case chair
    case diningChair = "dining_chair"
    case bed
    case desk
    case diningTable = "dining_table"
    case coffeeTable = "coffee_table"
    case sideTable = "side_table"
    case dresser
    case wardrobe
    case nightstand
    case bookshelf
    case tvStand = "tv_stand"
    case unknown

    /// Category-based dimension priors `(width, depth, height)` in meters,
    /// packed in the `(x, y, z)` convention above. These are the primary sizing
    /// mechanism on non-LiDAR devices — honest estimates, not measurements, so
    /// `FitService` treats furniture sized from them as `.estimated` confidence.
    var defaultDimensions: SIMD3<Float> {
        switch self {
        case .sofa:         return SIMD3(2.20, 0.90, 0.80)
        case .chair:        return SIMD3(0.70, 0.70, 0.90)
        case .diningChair:  return SIMD3(0.50, 0.50, 0.90)
        case .bed:          return SIMD3(1.60, 2.00, 0.60)
        case .desk:         return SIMD3(1.20, 0.60, 0.75)
        case .diningTable:  return SIMD3(1.20, 0.80, 0.75)
        case .coffeeTable:  return SIMD3(1.10, 0.55, 0.45)
        case .sideTable:    return SIMD3(0.45, 0.45, 0.55)
        case .dresser:      return SIMD3(0.90, 0.45, 1.20)
        case .wardrobe:     return SIMD3(1.00, 0.60, 2.00)
        case .nightstand:   return SIMD3(0.45, 0.40, 0.55)
        case .bookshelf:    return SIMD3(0.80, 0.30, 1.80)
        case .tvStand:      return SIMD3(1.40, 0.40, 0.50)
        case .unknown:      return SIMD3(0.80, 0.80, 0.80)
        }
    }

    var displayName: String {
        switch self {
        case .sofa:         return "Sofa"
        case .chair:        return "Armchair"
        case .diningChair:  return "Dining Chair"
        case .bed:          return "Bed"
        case .desk:         return "Desk"
        case .diningTable:  return "Dining Table"
        case .coffeeTable:  return "Coffee Table"
        case .sideTable:    return "Side Table"
        case .dresser:      return "Dresser"
        case .wardrobe:     return "Wardrobe"
        case .nightstand:   return "Nightstand"
        case .bookshelf:    return "Bookshelf"
        case .tvStand:      return "TV Stand"
        case .unknown:      return "Furniture"
        }
    }

    /// SF Symbol used by the manual fallback picker and de-clutter labels.
    var symbolName: String {
        switch self {
        case .sofa:         return "sofa.fill"
        case .chair:        return "chair.lounge.fill"
        case .diningChair:  return "chair.fill"
        case .bed:          return "bed.double.fill"
        case .desk:         return "table.furniture.fill"
        case .diningTable:  return "table.furniture.fill"
        case .coffeeTable:  return "table.furniture"
        case .sideTable:    return "table.furniture"
        case .dresser:      return "cabinet.fill"
        case .wardrobe:     return "cabinet.fill"
        case .nightstand:   return "cabinet"
        case .bookshelf:    return "books.vertical.fill"
        case .tvStand:      return "tv.fill"
        case .unknown:      return "shippingbox.fill"
        }
    }
}

// MARK: - Footprint

/// The floor-placed, dimensioned furniture item written into `RoomModel`. This
/// is the persisted unit of a detected piece of furniture.
struct FurnitureFootprint: Codable, Equatable, Sendable, Identifiable {
    let id: UUID
    let category: FurnitureCategory
    /// Floor-snapped center, in `RoomModel` world coordinates (Y is altitude).
    var worldPosition: SIMD3<Float>
    /// `(width, depth, height)` in meters — see the coordinate convention above.
    var dimensions: SIMD3<Float>
    /// Yaw about the vertical (Y) axis, radians.
    var yRotation: Float
    var appearance: FurnitureAppearance
    var detectionConfidence: DetectionConfidence
    /// Cleared in the de-clutter step (hidden but not deleted, so it can be
    /// restored).
    var isCleared: Bool
    /// User explicitly kept it — feeds `FitService` as an obstacle.
    var isKept: Bool
    /// Set when this footprint is a placed *catalog product* rather than detected
    /// existing furniture; links back to `CatalogItem.id` for true-color
    /// rendering and the retailer out-link. `nil` for detected/manual pieces.
    ///
    /// Optional, so Swift's synthesized decoder reads it as `decodeIfPresent` —
    /// pre-catalog room blobs decode unchanged with no schema bump. A catalog
    /// item carries `.detected` confidence (real manufacturer dimensions ⇒ the
    /// standard fit margin); it is distinguished from a Vision detection by this
    /// id being non-nil, not by a separate confidence case.
    var catalogItemID: String?

    /// Set when this footprint is a placed *Ideation-Sandbox* shape (digital clay)
    /// rather than a detected piece or a Verified product; links back to
    /// `SandboxAsset.id`. Mutually exclusive with `catalogItemID` in practice — a
    /// sandbox piece is elastic and makes NO purchase claim, so the diorama renders
    /// it as the stylized box (never the verified realistic-model path) and the
    /// selection UI shows the "find real matches" bridge instead of a retailer link.
    /// `nil` for detected/manual pieces and Verified products.
    ///
    /// Optional, so Swift's synthesized decoder reads it as `decodeIfPresent` —
    /// pre-sandbox room blobs decode unchanged with no schema bump.
    var sandboxAssetID: String?

    /// How the footprint's geometry was arrived at. Drives how much `FitService`
    /// widens its uncertainty band for this obstacle.
    enum DetectionConfidence: String, Codable, Sendable {
        /// Vision consensus across the rolling IoU tracker passed.
        case detected
        /// Low confidence or fell back to category priors — widen the margin.
        case estimated
        /// User added it manually via the fallback picker — widen the margin.
        case manual
    }

    init(
        id: UUID = UUID(),
        category: FurnitureCategory,
        worldPosition: SIMD3<Float>,
        dimensions: SIMD3<Float>,
        yRotation: Float = 0,
        appearance: FurnitureAppearance,
        detectionConfidence: DetectionConfidence,
        isCleared: Bool = false,
        isKept: Bool = false,
        catalogItemID: String? = nil,
        sandboxAssetID: String? = nil
    ) {
        self.id = id
        self.category = category
        self.worldPosition = worldPosition
        self.dimensions = dimensions
        self.yRotation = yRotation
        self.appearance = appearance
        self.detectionConfidence = detectionConfidence
        self.isCleared = isCleared
        self.isKept = isKept
        self.catalogItemID = catalogItemID
        self.sandboxAssetID = sandboxAssetID
    }
}

// MARK: - Appearance

/// Perceptual appearance — for DETECTED furniture, never hex codes or raw K-Means
/// output, so it stays robust to lighting variation and honest about what we
/// actually know.
struct FurnitureAppearance: Codable, Equatable, Sendable {
    var colorCategory: FurnitureColorCategory
    var materialClass: FurnitureMaterialClass
    /// Exact sRGB color (0–1), set ONLY for catalog products whose color is a
    /// known manufacturer spec — not a lighting-inferred detection. The room
    /// renders this true color directly (the honesty promise); when nil (every
    /// detected/manual piece) the renderer falls back to `colorCategory`'s
    /// representative color. Optional, so old room blobs decode it as nil.
    var exactColorRGB: SIMD3<Float>?

    /// Per-part sRGB overrides for an Ideation-Sandbox clay model, keyed by the
    /// model's part name (a named `ModelEntity` descendant, e.g. `"Mattress"`).
    /// A clay model ships multiple materials (frame / mattress / pillow); this lets
    /// the user repaint each part independently. A part absent from the map keeps
    /// its ORIGINAL library material; an empty/nil map means the whole piece is
    /// original. Sandbox-only — Verified products keep their single `exactColorRGB`
    /// true color and never per-part. Optional, so pre-sandbox blobs decode as nil.
    var partColors: [String: SIMD3<Float>]?

    init(
        colorCategory: FurnitureColorCategory,
        materialClass: FurnitureMaterialClass,
        exactColorRGB: SIMD3<Float>? = nil,
        partColors: [String: SIMD3<Float>]? = nil
    ) {
        self.colorCategory = colorCategory
        self.materialClass = materialClass
        self.exactColorRGB = exactColorRGB
        self.partColors = partColors
    }
}

/// 15 named perceptual color categories. Detection maps sampled pixels to the
/// nearest of these in Lab space (see `FurnitureColorClassifier`) rather than
/// surfacing a raw color, so lighting wobble can't produce false precision.
enum FurnitureColorCategory: String, Codable, CaseIterable, Sendable {
    case white, cream, lightGrey, darkGrey, black
    case warmBrown, coolBrown, tan, navy, teal
    case warmRed, warmGreen, warmYellow, warmOrange, other

    /// User-facing label. Spelled out explicitly (not `rawValue.capitalized`,
    /// which would render the camelCase cases as single mashed words like
    /// "Lightgrey") so the picker and de-clutter labels read naturally.
    var displayName: String {
        switch self {
        case .white:       return "White"
        case .cream:       return "Cream"
        case .lightGrey:   return "Light Grey"
        case .darkGrey:    return "Dark Grey"
        case .black:       return "Black"
        case .warmBrown:   return "Warm Brown"
        case .coolBrown:   return "Cool Brown"
        case .tan:         return "Tan"
        case .navy:        return "Navy"
        case .teal:        return "Teal"
        case .warmRed:     return "Warm Red"
        case .warmGreen:   return "Warm Green"
        case .warmYellow:  return "Warm Yellow"
        case .warmOrange:  return "Warm Orange"
        case .other:       return "Other"
        }
    }

    /// The display tint for this color category, pulled into the same
    /// warm Snug palette so detected furniture reads on-brand in the diorama.
    var playModeColor: Color {
        switch self {
        case .white:       return Color(hex: "#F5F0E8")
        case .cream:       return Color(hex: "#EDE0C4")
        case .lightGrey:   return Color(hex: "#C8C4BC")
        case .darkGrey:    return Color(hex: "#6B6560")
        case .black:       return Color(hex: "#2B2722")
        case .warmBrown:   return Color(hex: "#8B5E3C")
        case .coolBrown:   return Color(hex: "#6B5744")
        case .tan:         return Color(hex: "#C4A882")
        case .navy:        return Color(hex: "#2C3E6B")
        case .teal:        return Color(hex: "#2D6B6B")
        case .warmRed:     return Color(hex: "#B85450")
        case .warmGreen:   return Color(hex: "#4A7C59")
        case .warmYellow:  return Color(hex: "#C4A832")
        case .warmOrange:  return Color(hex: "#E8714A")
        case .other:       return Color(hex: "#8A847C")
        }
    }

    /// The representative sRGB color (0–1 components) used both as the display tint
    /// source of truth and as the anchor each category is matched against in
    /// `FurnitureColorClassifier`. Keeping one definition prevents the display
    /// color and the classification anchor from drifting apart.
    var representativeRGB: SIMD3<Float> {
        switch self {
        case .white:       return SIMD3(0.961, 0.941, 0.910)
        case .cream:       return SIMD3(0.929, 0.878, 0.769)
        case .lightGrey:   return SIMD3(0.784, 0.769, 0.737)
        case .darkGrey:    return SIMD3(0.420, 0.396, 0.376)
        case .black:       return SIMD3(0.169, 0.153, 0.133)
        case .warmBrown:   return SIMD3(0.545, 0.369, 0.235)
        case .coolBrown:   return SIMD3(0.420, 0.341, 0.267)
        case .tan:         return SIMD3(0.769, 0.659, 0.510)
        case .navy:        return SIMD3(0.173, 0.243, 0.420)
        case .teal:        return SIMD3(0.176, 0.420, 0.420)
        case .warmRed:     return SIMD3(0.722, 0.329, 0.314)
        case .warmGreen:   return SIMD3(0.290, 0.486, 0.349)
        case .warmYellow:  return SIMD3(0.769, 0.659, 0.196)
        case .warmOrange:  return SIMD3(0.910, 0.443, 0.290)
        case .other:       return SIMD3(0.541, 0.518, 0.486)
        }
    }
}

/// Coarse material classes. V2 derives this from a per-category heuristic; a
/// trained classifier is a V3 idea (kept out of V1/V2 scope).
enum FurnitureMaterialClass: String, Codable, CaseIterable, Sendable {
    case fabric, leather, wood, metal, glass, plastic, other

    /// PBR roughness used by the stylized material in `FurnitureEntityBuilder`.
    var roughness: Float {
        switch self {
        case .fabric:   return 0.95
        case .leather:  return 0.70
        case .wood:     return 0.80
        case .metal:    return 0.30
        case .glass:    return 0.05
        case .plastic:  return 0.60
        case .other:    return 0.85
        }
    }
}
