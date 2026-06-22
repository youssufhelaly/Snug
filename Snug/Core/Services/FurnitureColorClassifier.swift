import Foundation
import simd

/// Maps a sampled sRGB color to the nearest of the 15 named
/// `FurnitureColorCategory` values, in CIE Lab space.
///
/// ## Why Lab, and why this is split out
/// Lab Euclidean distance approximates perceived color difference far better
/// than raw RGB, so a sofa that photographs slightly warm or dim still lands in
/// the right named bucket — the robustness CLAUDE.md's Phase 2 notes call for.
/// The pixel sampling itself (intersecting the 5×5 grid with the instance
/// mask, picking the ~1000-lux frame) lives in `FurnitureDetectionService`,
/// which needs `CVPixelBuffer`/Vision; the perceptual *mapping* is pulled out
/// here so it is pure and unit-testable with plain colors.
enum FurnitureColorClassifier {

    /// The nearest named color category to a sampled sRGB color (components in
    /// 0–1). Compares in Lab against each category's representative color.
    static func category(forRGB rgb: SIMD3<Float>) -> FurnitureColorCategory {
        let target = labFromSRGB(rgb)
        var best: FurnitureColorCategory = .other
        var bestDistance = Float.greatestFiniteMagnitude
        for category in FurnitureColorCategory.allCases {
            // `.other` is the catch-all fallback, never an attractor — skip it as
            // a candidate so a sample only lands there when nothing else is near.
            if category == .other { continue }
            let anchor = labFromSRGB(category.representativeRGB)
            let d = simd_distance(target, anchor)
            if d < bestDistance { bestDistance = d; best = category }
        }
        // If even the closest named color is implausibly far, the sample is
        // ambiguous (mixed/patterned) — call it `.other` rather than overclaim.
        return bestDistance <= maxPlausibleLabDistance ? best : .other
    }

    /// The mean sRGB color (0–1) of a set of samples, the input the classifier
    /// expects after the detection layer has masked out background pixels.
    static func meanRGB(of samples: [SIMD3<Float>]) -> SIMD3<Float>? {
        guard !samples.isEmpty else { return nil }
        let sum = samples.reduce(SIMD3<Float>.zero, +)
        return sum / Float(samples.count)
    }

    /// Lab distance beyond which we decline to name a color. Generous (categories
    /// are coarse) but finite, so a truly off-gamut sample becomes `.other`.
    private static let maxPlausibleLabDistance: Float = 60

    // MARK: - sRGB → CIE Lab (D65)

    /// Convert an sRGB color (0–1) to CIE Lab. Standard pipeline: sRGB gamma
    /// expansion → linear RGB → XYZ (D65) → Lab.
    static func labFromSRGB(_ rgb: SIMD3<Float>) -> SIMD3<Float> {
        let r = linearize(rgb.x)
        let g = linearize(rgb.y)
        let b = linearize(rgb.z)

        // Linear sRGB → XYZ (D65).
        let x = r * 0.4124 + g * 0.3576 + b * 0.1805
        let y = r * 0.2126 + g * 0.7152 + b * 0.0722
        let z = r * 0.0193 + g * 0.1192 + b * 0.9505

        // Normalize by the D65 reference white.
        let fx = labF(x / 0.95047)
        let fy = labF(y / 1.00000)
        let fz = labF(z / 1.08883)

        let l = 116 * fy - 16
        let a = 500 * (fx - fy)
        let bb = 200 * (fy - fz)
        return SIMD3(l, a, bb)
    }

    private static func linearize(_ c: Float) -> Float {
        c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }

    private static func labF(_ t: Float) -> Float {
        let epsilon: Float = 216.0 / 24389.0
        let kappa: Float = 24389.0 / 27.0
        return t > epsilon ? pow(t, 1.0 / 3.0) : (kappa * t + 16) / 116
    }
}

/// Material inference. V2 is a per-category heuristic (the most common material
/// for each piece); a learned classifier is explicitly a V3 idea, out of scope.
extension FurnitureMaterialClass {
    /// The most likely material for a furniture category.
    static func inferred(for category: FurnitureCategory) -> FurnitureMaterialClass {
        switch category {
        case .sofa, .chair, .bed:           return .fabric
        case .diningChair:                  return .wood
        case .desk, .diningTable, .dresser, .bookshelf, .tvStand, .coffeeTable,
             .sideTable, .wardrobe, .nightstand:
            return .wood
        case .unknown:                      return .other
        }
    }
}
