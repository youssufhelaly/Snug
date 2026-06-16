import Testing
import Foundation
import simd
@testable import Snug

/// `FurniturePlacementService` is pure arithmetic on resolved raycast inputs.
/// These tests cover the two behaviors most likely to misplace furniture:
/// width back-projection clamping, and clamping a position into the room.
struct FurniturePlacementServiceTests {

    private let bedroom: [SIMD2<Float>] = FitFixtures.rectangularBedroom.floorCorners.map(\.simd2)

    private func observation(_ category: FurnitureCategory, boxWidth: CGFloat) -> FurnitureObservation {
        FurnitureObservation(
            category: category,
            confidence: 0.9,
            boundingBox: CGRect(x: 0.3, y: 0.3, width: boxWidth, height: 0.4),
            frameTimestamp: 0
        )
    }

    // MARK: - Width estimation + clamping

    @Test func widthWithinFortyPercentOfPriorIsTrusted() {
        // sofa prior width 2.20 → 0.5 * 3.0 * 1.2 = 1.8, inside [1.32, 3.08].
        let (dims, fellBack) = FurniturePlacementService.estimatedDimensions(
            category: .sofa, boundingBoxWidth: 0.5, raycastDistance: 3.0
        )
        #expect(!fellBack)
        #expect(abs(dims.x - 1.8) < 0.001)
        // depth/height always priors.
        #expect(dims.y == FurnitureCategory.sofa.defaultDimensions.y)
        #expect(dims.z == FurnitureCategory.sofa.defaultDimensions.z)
    }

    @Test func widthBeyondFortyPercentFallsBackToPrior() {
        // 0.1 * 3.0 * 1.2 = 0.36, well below the 1.32 floor → prior, estimated.
        let (dims, fellBack) = FurniturePlacementService.estimatedDimensions(
            category: .sofa, boundingBoxWidth: 0.1, raycastDistance: 3.0
        )
        #expect(fellBack)
        #expect(dims == FurnitureCategory.sofa.defaultDimensions)
    }

    @Test func missingDistanceFallsBackToPrior() {
        let (dims, fellBack) = FurniturePlacementService.estimatedDimensions(
            category: .desk, boundingBoxWidth: 0.5, raycastDistance: nil
        )
        #expect(fellBack)
        #expect(dims == FurnitureCategory.desk.defaultDimensions)
    }

    // MARK: - Room containment clamp

    @Test func pointInsideRoomIsUnchanged() {
        let inside = SIMD2<Float>(0, 0)
        #expect(FurniturePlacementService.clamped(inside, toRoom: bedroom) == inside)
    }

    @Test func pointOutsideRoomIsClampedInside() {
        let outside = SIMD2<Float>(5, 0)   // far past the +x wall at 1.8
        let clamped = FurniturePlacementService.clamped(outside, toRoom: bedroom)
        #expect(Geometry2D.isPoint(clamped, insidePolygon: bedroom))
    }

    // MARK: - Full placement

    @Test func raycastHitProducesDetectedFloorSnappedFootprint() {
        let input = FurniturePlacementService.Input(
            observation: observation(.sofa, boxWidth: 0.5),
            appearance: FurnitureAppearance(colorCategory: .cream, materialClass: .fabric),
            raycastHitXZ: SIMD2(0.2, -0.4),
            raycastDistance: 3.0,
            sessionFloorY: 0.0,
            roomCorners: bedroom,
            cameraPositionXZ: nil,
            cameraForwardXZ: nil
        )
        let footprint = FurniturePlacementService().place(input)
        #expect(footprint.detectionConfidence == .detected)
        // Y snapped to floor + half height (sofa height 0.80 → center at 0.40).
        #expect(abs(footprint.worldPosition.y - 0.40) < 0.001)
        #expect(footprint.worldPosition.x == 0.2)
        #expect(footprint.worldPosition.z == -0.4)
    }

    @Test func missingRaycastFallsBackToEstimated() {
        let input = FurniturePlacementService.Input(
            observation: observation(.chair, boxWidth: 0.4),
            appearance: FurnitureAppearance(colorCategory: .lightGrey, materialClass: .fabric),
            raycastHitXZ: nil,
            raycastDistance: nil,
            sessionFloorY: 0.0,
            roomCorners: bedroom,
            cameraPositionXZ: SIMD2(0, -1),
            cameraForwardXZ: SIMD2(0, 1)
        )
        let footprint = FurniturePlacementService().place(input)
        #expect(footprint.detectionConfidence == .estimated)
        // Even a fallback position must land inside the room.
        let xz = SIMD2(footprint.worldPosition.x, footprint.worldPosition.z)
        #expect(Geometry2D.isPoint(xz, insidePolygon: bedroom))
    }
}
