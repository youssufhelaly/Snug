import Testing
import Foundation
import simd
@testable import Snug

/// FitService is the highest-stakes code in the app (CLAUDE.md). These tests
/// drive it against room fixtures shaped like real scans and assert the exact
/// four-state boundaries, including the honest "too close to call" band.
struct FitServiceTests {

    let service = FitService()
    let margin: Float = 0.05

    /// Build a furniture footprint at a floor position.
    private func box(
        _ x: Float, _ z: Float,
        _ width: Float, _ depth: Float,
        rotation: Float = 0
    ) -> OrientedFootprint {
        OrientedFootprint(center: SIMD2(x, z), size: SIMD2(width, depth), rotation: rotation)
    }

    // MARK: - The four states against a real-shaped room

    @Test func obviousFitHasRoomToSpare() {
        let g = FitFixtures.rectangularBedroom.fitGeometry()
        let result = service.evaluate(item: box(0, 0, 1.0, 0.9), in: g, errorMargin: margin)
        #expect(result.state == .fitsWithRoom)
        #expect(result.clearance > margin * 2)
    }

    @Test func obviousNoFit() {
        let g = FitFixtures.rectangularBedroom.fitGeometry()
        // Wider than the 3.6 m room.
        let result = service.evaluate(item: box(0, 0, 4.0, 1.0), in: g, errorMargin: margin)
        #expect(result.state == .wontFit)
        #expect(result.clearance < -margin)
    }

    @Test func clearanceExactlyAtMarginIsTooCloseToCall() {
        let g = FitFixtures.rectangularBedroom.fitGeometry()
        // Room half-width 1.8; box half-width 1.75 -> 0.05 gap each side == margin.
        let result = service.evaluate(item: box(0, 0, 3.5, 1.0), in: g, errorMargin: margin)
        #expect(result.state == .tooCloseToCall)
    }

    @Test func oneCentimeterInsideMarginNeverShowsAGreenCheck() {
        let g = FitFixtures.rectangularBedroom.fitGeometry()
        // Gap of 0.04 m — 1 cm inside the 0.05 margin band.
        let result = service.evaluate(item: box(0, 0, 3.52, 1.0), in: g, errorMargin: margin)
        #expect(result.state == .tooCloseToCall)
        #expect(result.state != .fits)
        #expect(result.state != .fitsWithRoom)
    }

    @Test func justPastMarginFits() {
        let g = FitFixtures.rectangularBedroom.fitGeometry()
        // Gap of 0.06 m — just outside the margin band.
        let result = service.evaluate(item: box(0, 0, 3.48, 1.0), in: g, errorMargin: margin)
        #expect(result.state == .fits)
    }

    // MARK: - Obstacles (kept objects)

    @Test func overlappingKeptObjectWontFit() {
        let kept = FitObstacle(footprint: box(1.0, 0, 0.8, 0.8), kind: .keptObject)
        let g = FitFixtures.rectangularBedroom.fitGeometry(obstacles: [kept])
        let result = service.evaluate(item: box(1.1, 0, 0.8, 0.8), in: g, errorMargin: margin)
        #expect(result.state == .wontFit)
        if case .obstacle(_, let kind) = result.limit {
            #expect(kind == .keptObject)
        } else {
            Issue.record("Expected an obstacle to be the limiting factor, got \(result.limit)")
        }
    }

    @Test func clearOfKeptObjectFits() {
        let kept = FitObstacle(footprint: box(1.2, 0, 0.8, 0.8), kind: .keptObject)
        let g = FitFixtures.rectangularBedroom.fitGeometry(obstacles: [kept])
        let result = service.evaluate(item: box(-1.0, 0, 0.8, 0.8), in: g, errorMargin: margin)
        #expect(result.state == .fitsWithRoom)
    }

    // MARK: - Wall with a window (window is not an obstacle)

    @Test func itemAgainstWallWithWindowStillFits() {
        let g = FitFixtures.bedroomWithWindow.fitGeometry()
        // A low console against the windowed far wall (+Z): far edge at
        // z = 1.35, a 0.15 m gap to the 1.5 wall — the window doesn't block it.
        let result = service.evaluate(item: box(0, 1.15, 1.0, 0.4), in: g, errorMargin: margin)
        #expect(result.state == .fits || result.state == .fitsWithRoom)
    }

    // MARK: - Rotation

    @Test func rotatedBoxFitsDiagonally() {
        let g = FitFixtures.rectangularBedroom.fitGeometry()
        let result = service.evaluate(item: box(0, 0, 1.0, 1.0, rotation: .pi / 4), in: g, errorMargin: margin)
        #expect(result.state == .fitsWithRoom)
    }

    @Test func rotatedBoxThatPokesOutWontFit() {
        let g = FitFixtures.rectangularBedroom.fitGeometry()
        // Its diagonal exceeds the room once rotated 45°.
        let result = service.evaluate(item: box(0, 0, 3.0, 3.0, rotation: .pi / 4), in: g, errorMargin: margin)
        #expect(result.state == .wontFit)
    }

    // MARK: - Non-convex (L-shaped) room

    @Test func boxInWideArmOfLShapedRoomFits() {
        let g = FitFixtures.lShapedStudio.fitGeometry()
        let result = service.evaluate(item: box(1.0, 1.0, 1.2, 1.2), in: g, errorMargin: margin)
        #expect(result.state == .fitsWithRoom)
    }

    @Test func boxInTheBittenOutCornerOfLShapedRoomWontFit() {
        let g = FitFixtures.lShapedStudio.fitGeometry()
        // (3,3) is in the missing quadrant of the L — outside the floor.
        let result = service.evaluate(item: box(3.0, 3.0, 1.0, 1.0), in: g, errorMargin: margin)
        #expect(result.state == .wontFit)
    }

    /// Regression: an item bridging the two arms of a U-shaped room puts all
    /// four corners on real floor while the notch walls pass clean through it —
    /// corner containment alone called this a fit. It must read as won't-fit.
    @Test func boxSpanningTheNotchOfAUShapedRoomWontFit() {
        let g = FitFixtures.uShapedLounge.fitGeometry()
        // 3.0 × 0.5 item centered above the notch: corners at x 1.5 / 4.5 land
        // in the arms, but the notch region x∈[2,4] under it is not floor.
        let result = service.evaluate(item: box(3.0, 3.5, 3.0, 0.5), in: g, errorMargin: margin)
        #expect(result.state == .wontFit)
        #expect(result.clearance < 0)
    }

    /// The same U-shaped room must still fit an item that sits entirely
    /// within one arm — the stricter containment can't over-reject.
    @Test func boxInsideOneArmOfAUShapedRoomFits() {
        let g = FitFixtures.uShapedLounge.fitGeometry()
        let result = service.evaluate(item: box(1.0, 3.0, 1.2, 1.2), in: g, errorMargin: margin)
        #expect(result.state == .fitsWithRoom)
    }

    // MARK: - Non-convex / rotated rooms (regression: no phantom wall floor)

    /// In an L-shaped room, a box far from one wall but near another must report
    /// the NEAR wall's gap — not a phantom floor from a far wall's line cutting
    /// across the reflex corner. This is the bug that made certain walls
    /// "un-reachable" in the harness.
    @Test func lShapedRoomReportsNearestWallNotAPhantomFar() {
        let g = FitFixtures.lShapedStudio.fitGeometry()
        // 0.6×0.6 box at (1,1): half-extent 0.3, so its left edge sits at x=0.7.
        // Nearest wall is the left wall (x=0); gap = 0.7 (NOT a phantom far-wall floor).
        let centered = service.evaluate(item: box(1.0, 1.0, 0.6, 0.6), in: g, errorMargin: margin)
        #expect(centered.state == .fitsWithRoom)
        #expect(abs(centered.clearance - 0.7) < 0.01)
    }

    @Test func lShapedRoomBoxReachesEachArmWall() {
        let g = FitFixtures.lShapedStudio.fitGeometry()
        // Push toward the bottom wall (z=0) in the bottom arm.
        let nearBottom = service.evaluate(item: box(1.0, 0.31, 0.6, 0.6), in: g, errorMargin: margin)
        #expect(nearBottom.state == .tooCloseToCall)
        // Push toward the far wall (x=4) in the bottom arm — also reachable.
        let nearFar = service.evaluate(item: box(3.69, 1.0, 0.6, 0.6), in: g, errorMargin: margin)
        #expect(nearFar.state == .tooCloseToCall)
    }

    /// A rotated (non-axis-aligned) room must behave like its upright twin —
    /// real captured rooms are almost never axis-aligned.
    @Test func rotatedRoomBehavesLikeUprightRoom() {
        let angle: Float = .pi / 6
        func rotated(_ p: SIMD2<Float>) -> SIMD2<Float> {
            SIMD2(p.x * cos(angle) - p.y * sin(angle),
                  p.x * sin(angle) + p.y * cos(angle))
        }
        let upright = RoomFootprint.rectangle(width: 3.6, depth: 3.0)
        let tilted = FitGeometry(room: RoomFootprint(corners: upright.corners.map(rotated)))
        let result = service.evaluate(item: box(0, 0, 1.0, 0.6), in: tilted, errorMargin: margin)
        #expect(result.state == .fitsWithRoom)
    }

    // MARK: - Corner-to-corner clearance (true distance, not SAT overestimate)

    @Test func diagonalCornerGapMeasuresTrueDistance() {
        let kept = FitObstacle(footprint: box(1, 1, 1, 1, rotation: .pi / 4), kind: .keptObject)
        let g = FitGeometry(room: RoomFootprint.rectangle(width: 6, depth: 6), obstacles: [kept])
        let result = service.evaluate(item: box(-1, -1, 1, 1, rotation: .pi / 4), in: g, errorMargin: margin)
        #expect(result.state == .fitsWithRoom)
        // The two rotated boxes are well apart corner-to-corner.
        #expect(result.clearance > 1.0)
    }

    // MARK: - Boundary classifier (the only place the four-state cut lives)

    @Test func classifierBoundaries() {
        #expect(FitService.classify(clearance: 0.11, errorMargin: margin) == .fitsWithRoom)
        #expect(FitService.classify(clearance: 0.10, errorMargin: margin) == .fits) // not > 2x
        #expect(FitService.classify(clearance: 0.051, errorMargin: margin) == .fits)
        #expect(FitService.classify(clearance: 0.05, errorMargin: margin) == .tooCloseToCall) // not > 1x
        #expect(FitService.classify(clearance: 0.0, errorMargin: margin) == .tooCloseToCall)
        #expect(FitService.classify(clearance: -0.05, errorMargin: margin) == .tooCloseToCall)
        #expect(FitService.classify(clearance: -0.051, errorMargin: margin) == .wontFit)
    }

    // MARK: - Fixture Codable round-trip (real exports must re-import)

    @Test func roundTripJSONDecodesIntoRoomModel() throws {
        let data = Data(FitFixtures.rectangularBedroomJSON.utf8)
        let room = try JSONDecoder().decode(RoomModel.self, from: data)
        #expect(room.floorCorners.count == 4)
        #expect(room.provenance == .manualAR)

        // And a full encode -> decode cycle preserves geometry.
        let reEncoded = try JSONEncoder().encode(room)
        let reDecoded = try JSONDecoder().decode(RoomModel.self, from: reEncoded)
        #expect(reDecoded == room)
    }
}
