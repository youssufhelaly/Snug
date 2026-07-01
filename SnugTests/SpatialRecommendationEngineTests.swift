import Foundation
import Testing
import simd
@testable import Snug

/// The local, offline half of the Sandbox→Verified bridge: given the size a user
/// sculpted a sandbox piece to, find Verified products of a similar footprint.
///
/// The contract these tests pin:
/// - category is a HARD gate, not a weighted score;
/// - the match window is SYMMETRIC and per-axis (default = `FitService`'s margin);
/// - an over-size-but-in-window product is STILL returned (honest fit is
///   `FitService`'s downstream call, never silently filtered here);
/// - ranking is by Euclidean dimension distance, deterministic on ties.
struct SpatialRecommendationEngineTests {

    // MARK: - Fixtures

    /// Build a Verified product with only the fields the matcher reads; the rest
    /// are plausible defaults so the fixture stays terse.
    private func item(
        _ id: String,
        _ category: FurnitureCategory,
        _ dimensions: SIMD3<Float>
    ) -> CatalogItem {
        CatalogItem(
            id: id,
            name: id,
            brand: "Test",
            category: category,
            dimensions: dimensions,
            trueColorRGB: SIMD3(0.4, 0.4, 0.4),
            colorCategory: .darkGrey,
            material: .fabric,
            priceCents: 9999,
            retailerName: "Test",
            productURL: URL(string: "https://example.com/p/\(id)")!
        )
    }

    /// A 2.10 × 0.90 × 0.85 m sofa — the size a user might sculpt to fit an alcove.
    private let target = SIMD3<Float>(2.10, 0.90, 0.85)

    // MARK: - Category hard gate

    @Test func categoryIsAHardGateNotAScore() {
        // A coffee table with the IDENTICAL footprint must never surface for a
        // sofa query — even at zero dimension distance.
        let items = [
            item("sofa-exact", .sofa, target),
            item("table-exact", .coffeeTable, target)
        ]
        let matches = SpatialRecommendationEngine.matches(
            forTarget: target, category: .sofa, in: items
        )
        #expect(matches.map(\.id) == ["sofa-exact"])
    }

    // MARK: - Symmetric window

    @Test func includesProductsWithinToleranceOnEveryAxis() {
        // 4 cm under on width, 3 cm under on depth, exact height — inside the 5 cm
        // default window on all three axes.
        let near = item("near", .sofa, SIMD3(2.06, 0.87, 0.85))
        let matches = SpatialRecommendationEngine.matches(
            forTarget: target, category: .sofa, in: [near]
        )
        #expect(matches.map(\.id) == ["near"])
    }

    @Test func excludesProductsOutsideToleranceOnAnyAxis() {
        // Width and depth are spot-on, but height is 8 cm off — past the 5 cm
        // window on a single axis, so it is not "similar".
        let tooTall = item("too-tall", .sofa, SIMD3(2.10, 0.90, 0.93))
        let matches = SpatialRecommendationEngine.matches(
            forTarget: target, category: .sofa, in: [tooTall]
        )
        #expect(matches.isEmpty)
    }

    @Test func windowIsSymmetricOverAndUnderMatchEqually() {
        // +4 cm width and −4 cm width are the same distance from the target and
        // must both be inside the window — the matcher is about closeness, not fit.
        let over = item("over", .sofa, SIMD3(2.14, 0.90, 0.85))
        let under = item("under", .sofa, SIMD3(2.06, 0.90, 0.85))
        let matches = SpatialRecommendationEngine.matches(
            forTarget: target, category: .sofa, in: [over, under]
        )
        #expect(Set(matches.map(\.id)) == ["over", "under"])
    }

    // MARK: - Over-size honesty (the key contract)

    @Test func overSizeProductWithinWindowIsReturnedAndFlagged() {
        // 3 cm WIDER than the alcove the user sized to. A naive "designing for
        // clearance" matcher would hide this; we return it, flagged, and let
        // FitService deliver the honest "too tight / won't fit" in the real room.
        let over = item("over", .sofa, SIMD3(2.13, 0.90, 0.85))
        let matches = SpatialRecommendationEngine.matches(
            forTarget: target, category: .sofa, in: [over]
        )
        #expect(matches.count == 1)
        #expect(matches[0].exceedsTargetOnAnyAxis)
    }

    @Test func exactSizeProductIsNotFlaggedOverSize() {
        let exact = item("exact", .sofa, target)
        let matches = SpatialRecommendationEngine.matches(
            forTarget: target, category: .sofa, in: [exact]
        )
        #expect(matches.count == 1)
        #expect(!matches[0].exceedsTargetOnAnyAxis)
        #expect(abs(matches[0].dimensionDistance) < 1e-5)
    }

    // MARK: - Ranking

    @Test func ranksByAscendingDimensionDistance() {
        let close = item("close", .sofa, SIMD3(2.11, 0.90, 0.85))   // 1 cm off
        let mid = item("mid", .sofa, SIMD3(2.10, 0.93, 0.85))       // 3 cm off
        let far = item("far", .sofa, SIMD3(2.10, 0.90, 0.89))       // 4 cm off
        let matches = SpatialRecommendationEngine.matches(
            forTarget: target, category: .sofa, in: [far, mid, close]
        )
        #expect(matches.map(\.id) == ["close", "mid", "far"])
    }

    @Test func tiesAreBrokenByIDForDeterminism() {
        // Same per-axis delta magnitude ⇒ identical distance; order must be stable.
        let a = item("a", .sofa, SIMD3(2.12, 0.90, 0.85))
        let b = item("b", .sofa, SIMD3(2.08, 0.90, 0.85))
        let matches = SpatialRecommendationEngine.matches(
            forTarget: target, category: .sofa, in: [b, a]
        )
        #expect(matches.map(\.id) == ["a", "b"])
    }

    // MARK: - Tolerance override

    @Test func tighterToleranceShrinksTheMatchSet() {
        let near = item("near", .sofa, SIMD3(2.06, 0.90, 0.85))   // 4 cm off width
        // Default 5 cm window includes it; a 2 cm window excludes it.
        #expect(
            SpatialRecommendationEngine.matches(
                forTarget: target, category: .sofa, in: [near]
            ).count == 1
        )
        #expect(
            SpatialRecommendationEngine.matches(
                forTarget: target, category: .sofa, in: [near], tolerance: 0.02
            ).isEmpty
        )
    }

    @Test func emptyCatalogYieldsNoMatches() {
        #expect(
            SpatialRecommendationEngine.matches(
                forTarget: target, category: .sofa, in: []
            ).isEmpty
        )
    }
}
