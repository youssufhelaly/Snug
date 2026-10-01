import Testing
import Foundation
import simd
@testable import Snug

/// `FurniturePlacementValidator` maps `FitService`'s four states onto the
/// diorama's three tints. These tests pin the tint against a rectangular room
/// and neighbor pieces, and prove it always agrees with the fit badge.
struct FurniturePlacementValidatorTests {

    /// A rectangular `RoomModel` centered at the origin.
    private func room(width: Float, depth: Float) -> RoomModel {
        let hx = width / 2, hz = depth / 2
        return RoomModel(
            provenance: .manualAR,
            floorCorners: [
                PlanePoint(x: -hx, z: -hz),
                PlanePoint(x: hx, z: -hz),
                PlanePoint(x: hx, z: hz),
                PlanePoint(x: -hx, z: hz),
            ],
            ceilingHeight: 2.5
        )
    }

    private func footprint(_ x: Float, _ z: Float, _ w: Float, _ d: Float,
                           rotation: Float = 0, id: UUID = UUID()) -> FurnitureFootprint {
        FurnitureFootprint(
            id: id,
            category: .sofa,
            worldPosition: SIMD3(x, d / 2, z),
            dimensions: SIMD3(w, d, 0.8),
            yRotation: rotation,
            appearance: FurnitureAppearance(colorCategory: .other, materialClass: .other),
            detectionConfidence: .manual
        )
    }

    @Test func centeredInLargeRoomIsValid() {
        let state = FurniturePlacementValidator.validate(
            footprint: footprint(0, 0, 1, 1), against: room(width: 6, depth: 6), existingFootprints: [])
        #expect(state == .valid)
    }

    @Test func cornerOutsideRoomIsInvalid() {
        // Center at x=2.8, half-width 0.5 → right corners at 3.3, past the 3.0 wall.
        let state = FurniturePlacementValidator.validate(
            footprint: footprint(2.8, 0, 1, 1), against: room(width: 6, depth: 6), existingFootprints: [])
        #expect(state == .invalid)
    }

    @Test func fourCentimetersFromWallIsTooClose() {
        // Right corners at x=2.96 → 0.04 m from the 3.0 wall, inside the 5 cm margin.
        let state = FurniturePlacementValidator.validate(
            footprint: footprint(2.46, 0, 1, 1), against: room(width: 6, depth: 6), existingFootprints: [])
        #expect(state == .tooClose)
    }

    @Test func eightCentimetersFromWallIsValid() {
        // 0.08 m clears the 5 cm margin, so the badge says "Fits" and the tint is
        // calm. The old validator's separate 8 cm rule turned this amber.
        let state = FurniturePlacementValidator.validate(
            footprint: footprint(2.42, 0, 1, 1), against: room(width: 6, depth: 6), existingFootprints: [])
        #expect(state == .valid)
    }

    @Test func overlappingFootprintIsInvalid() {
        let a = footprint(0, 0, 1, 1)
        let b = footprint(0.5, 0, 1, 1)   // centers 0.5 apart, widths 1 → overlap
        let state = FurniturePlacementValidator.validate(
            footprint: b, against: room(width: 6, depth: 6), existingFootprints: [a])
        #expect(state == .invalid)
    }

    @Test func fourCentimetersApartIsTooClose() {
        let a = footprint(0, 0, 1, 1)        // x: -0.5...0.5
        let b = footprint(1.04, 0, 1, 1)     // x: 0.54...1.54 → 0.04 m gap (< 0.05)
        let state = FurniturePlacementValidator.validate(
            footprint: b, against: room(width: 6, depth: 6), existingFootprints: [a])
        #expect(state == .tooClose)
    }

    @Test func twentyCentimetersApartIsValidForBoth() {
        let a = footprint(0, 0, 1, 1)
        let b = footprint(1.2, 0, 1, 1)      // 0.20 m gap
        let r = room(width: 6, depth: 6)
        #expect(FurniturePlacementValidator.validate(footprint: a, against: r, existingFootprints: [b]) == .valid)
        #expect(FurniturePlacementValidator.validate(footprint: b, against: r, existingFootprints: [a]) == .valid)
    }

    @Test func footprintIsNotComparedAgainstItself() {
        let f = footprint(0, 0, 1, 1)
        // The same footprint in `existingFootprints` must be filtered by id, not
        // flagged as a self-overlap.
        let state = FurniturePlacementValidator.validate(
            footprint: f, against: room(width: 6, depth: 6), existingFootprints: [f])
        #expect(state == .valid)
    }

    /// Regression: an item bridging the two arms of a U-shaped room has all
    /// four corners on real floor but spans the cut-out notch — the red/amber/
    /// green feedback must call it invalid, matching FitService's containment.
    @Test func footprintSpanningUShapedNotchIsInvalid() {
        let state = FurniturePlacementValidator.validate(
            footprint: footprint(3.0, 3.5, 3.0, 0.5),
            against: FitFixtures.uShapedLounge,
            existingFootprints: [])
        #expect(state == .invalid)
    }

    @Test func footprintInsideOneArmOfUShapedRoomIsValid() {
        let state = FurniturePlacementValidator.validate(
            footprint: footprint(1.0, 3.0, 1.2, 1.2),
            against: FitFixtures.uShapedLounge,
            existingFootprints: [])
        #expect(state == .valid)
    }

    /// The tint and the fit badge must agree for every position, rotation and
    /// neighbor, because the tint is derived from the badge's own result.
    @Test(arguments: [-2.9, -2.5, -1.0, 0.0, 0.47, 0.52, 1.5, 2.44, 2.47, 2.5, 2.9] as [Float])
    func tintAlwaysMatchesTheFitBadge(x: Float) {
        let r = room(width: 6, depth: 6)
        let neighbor = footprint(1.0, 0, 1, 1)
        for rotation in [0, Float.pi / 8, Float.pi / 4] {
            let candidate = footprint(x, 0.3, 1, 0.8, rotation: rotation)
            var placed = r
            placed.detectedFurniture = [neighbor, candidate]
            let badge = placed.fitResult(for: candidate, excluding: candidate.id).state
            let tint = FurniturePlacementValidator.validate(
                footprint: candidate, against: r, existingFootprints: [neighbor, candidate])
            #expect(tint == PlacementState(badge))
        }
    }

    @Test func clearedNeighborsNeverBlock() {
        var cleared = footprint(0, 0, 1, 1)
        cleared.isCleared = true
        let state = FurniturePlacementValidator.validate(
            footprint: footprint(0.2, 0, 1, 1), against: room(width: 6, depth: 6), existingFootprints: [cleared])
        #expect(state == .valid)
    }

    @Test func usesPhase0RoomFixture() {
        // A 1.0 × 0.9 m piece centered in the ~3.6 × 3.0 m bedroom fixture fits.
        let state = FurniturePlacementValidator.validate(
            footprint: footprint(0, 0, 1.0, 0.9),
            against: FitFixtures.rectangularBedroom,
            existingFootprints: [])
        #expect(state == .valid)
    }
}
