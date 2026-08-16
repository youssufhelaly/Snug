import Foundation
import Testing
import simd
@testable import Snug

/// The pure derivation of first-person "step inside" vantages from a `RoomModel`:
/// one per opening (stood just inside, facing the room center) plus a center
/// vantage, with eye height clamped under the ceiling.
struct WalkthroughVantageTests {

    /// A ~3.6 m × 3.0 m rectangle centered on the origin (centroid ≈ (0, 0)).
    private static func bedroom(openings: [RoomOpening] = [], ceiling: Float = 2.5) -> RoomModel {
        RoomModel(
            provenance: .manualAR,
            floorCorners: [
                PlanePoint(x: -1.8, z: -1.5),
                PlanePoint(x:  1.8, z: -1.5),
                PlanePoint(x:  1.8, z:  1.5),
                PlanePoint(x: -1.8, z:  1.5),
            ],
            ceilingHeight: ceiling,
            openings: openings
        )
    }

    private static func door(from: SIMD2<Float>, to: SIMD2<Float>) -> RoomOpening {
        RoomOpening(kind: .door, start: PlanePoint(from), end: PlanePoint(to))
    }

    @Test func emptyRoomHasOnlyCenter() {
        let vantages = WalkthroughVantage.vantages(for: Self.bedroom())
        #expect(vantages.count == 1)
        #expect(vantages.first?.id == "center")
        // Center sits at the floor centroid.
        let c = vantages.first!.position
        #expect(abs(c.x) < 0.001)
        #expect(abs(c.y) < 0.001)
    }

    @Test func degenerateRoomHasNoVantages() {
        let line = RoomModel(
            provenance: .manualAR,
            floorCorners: [PlanePoint(x: 0, z: 0), PlanePoint(x: 1, z: 0)],
            ceilingHeight: 2.4
        )
        #expect(WalkthroughVantage.vantages(for: line).isEmpty)
    }

    @Test func doorVantageStandsInsideFacingCenter() {
        // Door on the near (-Z) wall, centered.
        let room = Self.bedroom(openings: [Self.door(from: [-0.6, -1.5], to: [0.6, -1.5])])
        let vantages = WalkthroughVantage.vantages(for: room)
        #expect(vantages.count == 2)   // doorway + center
        let doorway = try! #require(vantages.first { $0.id != "center" })

        // Stood ~0.6 m inside the wall (door mid z = -1.5 → position z ≈ -0.9), and
        // strictly inside the room polygon.
        #expect(abs(doorway.position.x) < 0.001)
        #expect(doorway.position.y > -1.5 && doorway.position.y < 1.5)
        #expect(abs(doorway.position.y - -0.9) < 0.01)

        // Facing the centroid: forward (sin, cos) points from the vantage toward (0,0).
        let fwd = SIMD2(sin(doorway.initialYaw), cos(doorway.initialYaw))
        let toCenter = simd_normalize(SIMD2<Float>(0, 0) - doorway.position)
        #expect(simd_dot(fwd, toCenter) > 0.99)
    }

    @Test func eyeHeightClampsUnderLowCeiling() {
        #expect(WalkthroughVantage.vantages(for: Self.bedroom(ceiling: 2.5)).first!.eyeHeight == 1.6)
        // 1.7 m ceiling → 1.6 would poke through; clamp to ceiling − 0.2 = 1.5.
        let low = WalkthroughVantage.vantages(for: Self.bedroom(ceiling: 1.7)).first!.eyeHeight
        #expect(abs(low - 1.5) < 0.001)
    }

    @Test func repeatedKindsAreNumbered() {
        let room = Self.bedroom(openings: [
            RoomOpening(kind: .window, start: PlanePoint(x: -1.8, z: -0.5), end: PlanePoint(x: -1.8, z: 0.5)),
            RoomOpening(kind: .window, start: PlanePoint(x: 1.8, z: -0.5), end: PlanePoint(x: 1.8, z: 0.5)),
        ])
        let labels = WalkthroughVantage.vantages(for: room).map(\.label)
        #expect(labels.contains("Window 1"))
        #expect(labels.contains("Window 2"))
        #expect(labels.contains("Center"))
    }

    @Test func singleKindIsNotNumbered() {
        let room = Self.bedroom(openings: [Self.door(from: [-0.6, -1.5], to: [0.6, -1.5])])
        #expect(WalkthroughVantage.vantages(for: room).map(\.label).contains("Doorway"))
    }

    @Test func vantageIDsAreStableAndUnique() {
        let opening = Self.door(from: [-0.6, -1.5], to: [0.6, -1.5])
        let room = Self.bedroom(openings: [opening])
        let ids = WalkthroughVantage.vantages(for: room).map(\.id)
        #expect(Set(ids).count == ids.count)               // unique
        #expect(ids.contains("opening-\(opening.id.uuidString)"))   // tied to the opening
    }
}
