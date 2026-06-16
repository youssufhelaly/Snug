import Testing
import Foundation
import simd
@testable import Snug

/// Phase 2 value types: persistence backward-compatibility, the category priors,
/// and the kept-furniture → fit-obstacle bridge.
struct FurnitureModelTests {

    private func sampleFootprint(
        category: FurnitureCategory = .sofa,
        confidence: FurnitureFootprint.DetectionConfidence = .detected,
        isKept: Bool = false,
        isCleared: Bool = false
    ) -> FurnitureFootprint {
        FurnitureFootprint(
            category: category,
            worldPosition: SIMD3(0.5, 0.4, -0.3),
            dimensions: category.defaultDimensions,
            yRotation: .pi / 6,
            appearance: FurnitureAppearance(colorCategory: .cream, materialClass: .fabric),
            detectionConfidence: confidence,
            isKept: isKept,
            isCleared: isCleared
        )
    }

    // MARK: - Backward-compatible persistence

    /// A room blob written before `detectedFurniture` existed (no such key) must
    /// still decode, defaulting to an empty array. This is the exact JSON shape
    /// the app's fixture exporter produced in Phase 1.
    @Test func legacyBlobWithoutDetectedFurnitureDecodes() throws {
        let legacy = """
        {
          "id": "11111111-1111-1111-1111-111111111111",
          "capturedAt": 738000000,
          "provenance": "manualAR",
          "floorCorners": [
            {"x": -1.8, "z": -1.5},
            {"x": 1.8, "z": -1.5},
            {"x": 1.8, "z": 1.5},
            {"x": -1.8, "z": 1.5}
          ],
          "ceilingHeight": 2.5,
          "openings": []
        }
        """
        let room = try JSONDecoder().decode(RoomModel.self, from: Data(legacy.utf8))
        #expect(room.detectedFurniture.isEmpty)
        #expect(room.floorCorners.count == 4)
    }

    @Test func roomWithFurnitureRoundTrips() throws {
        let room = RoomModel(
            provenance: .manualAR,
            floorCorners: FitFixtures.rectangularBedroom.floorCorners,
            ceilingHeight: 2.5,
            detectedFurniture: [
                sampleFootprint(category: .sofa, isKept: true),
                sampleFootprint(category: .coffeeTable, confidence: .estimated),
            ]
        )
        let data = try JSONEncoder().encode(room)
        let decoded = try JSONDecoder().decode(RoomModel.self, from: data)
        #expect(decoded == room)
        #expect(decoded.detectedFurniture.count == 2)
    }

    // MARK: - Category priors

    @Test func everyCategoryHasPositivePriorDimensions() {
        for category in FurnitureCategory.allCases {
            let d = category.defaultDimensions
            #expect(d.x > 0 && d.y > 0 && d.z > 0)
        }
    }

    // MARK: - Kept-furniture → fit-obstacle bridge

    @Test func detectedFootprintBecomesMeasuredObstacle() {
        let obstacle = sampleFootprint(confidence: .detected).fitObstacle
        #expect(obstacle.confidence == .measured)
        #expect(obstacle.kind == .keptObject)
    }

    @Test func estimatedAndManualFootprintsWidenTheMargin() {
        #expect(sampleFootprint(confidence: .estimated).fitObstacle.confidence == .estimated)
        #expect(sampleFootprint(confidence: .manual).fitObstacle.confidence == .estimated)
    }

    @Test func footprintCollapsesToFloorRectangle() {
        let footprint = sampleFootprint(category: .desk)   // prior (1.2, 0.6, 0.75)
        let o = footprint.fitObstacle.footprint
        #expect(o.center == SIMD2(footprint.worldPosition.x, footprint.worldPosition.z))
        #expect(o.size == SIMD2(footprint.dimensions.x, footprint.dimensions.y))
        #expect(o.rotation == footprint.yRotation)
    }

    @Test func onlyKeptUnclearedFurnitureBecomesObstacles() {
        let furniture = [
            sampleFootprint(isKept: true,  isCleared: false),   // counts
            sampleFootprint(isKept: false, isCleared: false),   // not kept
            sampleFootprint(isKept: true,  isCleared: true),    // cleared away
        ]
        #expect(furniture.keptObstacles.count == 1)
    }
}
