import Testing
import Foundation
import simd
@testable import Snug

/// The perceptual color mapping. Each named category's representative color must
/// classify back to itself (Lab distance 0 wins), and obvious colors must land
/// in the intuitively right bucket.
struct FurnitureColorClassifierTests {

    @Test func everyNamedCategoryMapsToItself() {
        for category in FurnitureColorCategory.allCases where category != .other {
            let mapped = FurnitureColorClassifier.category(forRGB: category.representativeRGB)
            #expect(mapped == category, "\(category) should map to itself, got \(mapped)")
        }
    }

    @Test func pureBlackAndWhiteClassifyAsExpected() {
        #expect(FurnitureColorClassifier.category(forRGB: SIMD3(0, 0, 0)) == .black)
        #expect(FurnitureColorClassifier.category(forRGB: SIMD3(1, 1, 1)) == .white)
    }

    @Test func deepBlueIsNavy() {
        #expect(FurnitureColorClassifier.category(forRGB: SIMD3(0.10, 0.16, 0.40)) == .navy)
    }

    @Test func meanRGBAveragesSamples() {
        let mean = FurnitureColorClassifier.meanRGB(of: [SIMD3(0, 0, 0), SIMD3(1, 1, 1)])
        #expect(mean == SIMD3(0.5, 0.5, 0.5))
        #expect(FurnitureColorClassifier.meanRGB(of: []) == nil)
    }

    @Test func materialHeuristicMatchesCategory() {
        #expect(FurnitureMaterialClass.inferred(for: .sofa) == .fabric)
        #expect(FurnitureMaterialClass.inferred(for: .bookshelf) == .wood)
        #expect(FurnitureMaterialClass.inferred(for: .unknown) == .other)
    }
}
