import Testing
import Foundation
import simd
@testable import Snug

/// Phase 2 trust-layer change: an obstacle sized from category priors
/// (`.estimated`/`.manual`) widens `FitService`'s uncertainty band 1.5×, so the
/// same gap that "fits" against a measured obstacle becomes "too close to call".
/// Crucially this never *blocks* a placement — it only refuses to claim a
/// confident yes (CLAUDE.md: honesty over a false green check).
struct FitConfidenceMarginTests {

    let service = FitService()
    /// A deliberately wide margin so a single 0.25 m gap lands cleanly in the
    /// band that the 1.5× multiplier shifts states across.
    let margin: Float = 0.20

    private func box(_ x: Float, _ z: Float, _ w: Float, _ d: Float) -> OrientedFootprint {
        OrientedFootprint(center: SIMD2(x, z), size: SIMD2(w, d))
    }

    /// Item right edge at x=0.5, obstacle left edge at x=0.75 → a 0.25 m gap.
    /// The room is huge, so the obstacle is the binding constraint.
    private func geometry(obstacleConfidence: FitObstacle.Confidence) -> FitGeometry {
        let obstacle = FitObstacle(
            footprint: box(1.25, 0, 1.0, 1.0),
            kind: .keptObject,
            confidence: obstacleConfidence
        )
        return FitGeometry(room: RoomFootprint.rectangle(width: 6, depth: 6), obstacles: [obstacle])
    }

    @Test func measuredObstacleAtThisGapFits() {
        let result = service.evaluate(item: box(0, 0, 1, 1), in: geometry(obstacleConfidence: .measured), errorMargin: margin)
        // 0.25 > 0.20 (margin) but not > 0.40 (2× margin) → fits.
        #expect(result.state == .fits)
        #expect(abs(result.clearance - 0.25) < 0.001)
    }

    @Test func estimatedObstacleAtSameGapIsTooCloseToCall() {
        let result = service.evaluate(item: box(0, 0, 1, 1), in: geometry(obstacleConfidence: .estimated), errorMargin: margin)
        // Band widens 1.5× → the same 0.25 m gap is now inside the uncertainty
        // band: "too close to call", not a confident "fits".
        #expect(result.state == .tooCloseToCall)
        // Reported clearance is still the honest raw gap, not a scaled number.
        #expect(abs(result.clearance - 0.25) < 0.001)
        // Still reported as an obstacle limit, and never escalated to "won't fit".
        #expect(result.state != .wontFit)
        if case .obstacle(_, let kind) = result.limit {
            #expect(kind == .keptObject)
        } else {
            Issue.record("Expected the estimated obstacle to be the limiting factor, got \(result.limit)")
        }
    }

    /// The widening must not perturb the all-measured path: identical inputs to
    /// the existing fixtures still classify exactly as before.
    @Test func measuredObstaclesAreUnchangedFromBaseline() {
        let kept = FitObstacle(footprint: box(1.2, 0, 0.8, 0.8), kind: .keptObject)   // defaults to .measured
        let g = FitFixtures.rectangularBedroom.fitGeometry(obstacles: [kept])
        let result = service.evaluate(item: box(-1.0, 0, 0.8, 0.8), in: g, errorMargin: 0.05)
        #expect(result.state == .fitsWithRoom)
    }
}
