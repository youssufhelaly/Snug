import Testing
import Foundation
import simd
@testable import Snug

/// `FurniturePlacementValidator` is a pure boundary + overlap classifier. These
/// tests pin the three states against a rectangular room and neighbor pieces.
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

    @Test func fiveCentimetersFromWallIsTooClose() {
        // Right corners at x=2.95 → 0.05 m from the 3.0 wall (< 0.08 wallMargin).
        let state = FurniturePlacementValidator.validate(
            footprint: footprint(2.45, 0, 1, 1), against: room(width: 6, depth: 6), existingFootprints: [])
        #expect(state == .tooClose)
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

    @Test func usesPhase0RoomFixture() {
        // A 1.0 × 0.9 m piece centered in the ~3.6 × 3.0 m bedroom fixture fits.
        let state = FurniturePlacementValidator.validate(
            footprint: footprint(0, 0, 1.0, 0.9),
            against: FitFixtures.rectangularBedroom,
            existingFootprints: [])
        #expect(state == .valid)
    }
}
