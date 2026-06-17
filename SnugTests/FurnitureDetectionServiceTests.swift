import Testing
import Foundation
@testable import Snug

/// The pure, deterministic core of the detector: IoU and the rolling-track
/// consensus gate. (The Vision/CoreML glue is device-only and not exercised here.)
struct FurnitureDetectionServiceTests {

    private func obs(_ category: FurnitureCategory, _ box: CGRect, _ t: TimeInterval, confidence: Float = 0.9) -> FurnitureObservation {
        FurnitureObservation(category: category, confidence: confidence, boundingBox: box, frameTimestamp: t)
    }

    // MARK: - IoU

    @Test func iouOfIdenticalBoxesIsOne() {
        let r = CGRect(x: 0.2, y: 0.2, width: 0.4, height: 0.3)
        #expect(abs(FurnitureDetectionService.iou(r, r) - 1.0) < 0.0001)
    }

    @Test func iouOfDisjointBoxesIsZero() {
        let a = CGRect(x: 0, y: 0, width: 0.2, height: 0.2)
        let b = CGRect(x: 0.5, y: 0.5, width: 0.2, height: 0.2)
        #expect(FurnitureDetectionService.iou(a, b) == 0)
    }

    @Test func iouOfHalfOverlapIsKnownValue() {
        // Two unit-ish boxes overlapping in half their area:
        // A=[0,1]×[0,1], B=[0.5,1.5]×[0,1] → inter 0.5, union 1.5 → 1/3.
        let a = CGRect(x: 0, y: 0, width: 1, height: 1)
        let b = CGRect(x: 0.5, y: 0, width: 1, height: 1)
        #expect(abs(FurnitureDetectionService.iou(a, b) - (1.0 / 3.0)) < 0.0001)
    }

    // MARK: - Consensus gate

    private func consensus(_ observations: [FurnitureObservation]) -> [FurnitureObservation] {
        FurnitureDetectionService.consensus(
            from: observations,
            minConsecutiveFrames: FurnitureDetectionService.minimumConsecutiveFrames,   // 3
            minTrackDuration: FurnitureDetectionService.minimumTrackDuration            // 1.5
        )
    }

    @Test func trackConfirmedByThreeConsecutiveFrames() {
        let box = CGRect(x: 0.3, y: 0.2, width: 0.4, height: 0.3)
        let confirmed = consensus([
            obs(.sofa, box, 0.0),
            obs(.sofa, box, 0.1),
            obs(.sofa, box, 0.2),
        ])
        #expect(confirmed.count == 1)
        #expect(confirmed.first?.category == .sofa)
    }

    @Test func trackConfirmedByDurationEvenWithTwoFrames() {
        let box = CGRect(x: 0.1, y: 0.1, width: 0.3, height: 0.5)
        let confirmed = consensus([
            obs(.bed, box, 0.0),
            obs(.bed, box, 1.6),   // 1.6 s ≥ 1.5 s lifetime, only 2 frames
        ])
        #expect(confirmed.count == 1)
        #expect(confirmed.first?.category == .bed)
    }

    @Test func transientSingleHitIsRejected() {
        let confirmed = consensus([obs(.chair, CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2), 0.0)])
        #expect(confirmed.isEmpty)
    }

    @Test func atMostOnePerCategory() {
        let sofaBox = CGRect(x: 0.3, y: 0.2, width: 0.4, height: 0.3)
        let bedBox = CGRect(x: 0.1, y: 0.1, width: 0.3, height: 0.5)
        let confirmed = consensus([
            obs(.sofa, sofaBox, 0.0), obs(.sofa, sofaBox, 0.1), obs(.sofa, sofaBox, 0.2),
            obs(.bed, bedBox, 0.0), obs(.bed, bedBox, 1.6),
        ])
        #expect(confirmed.count == 2)
        #expect(Set(confirmed.map(\.category)) == [.sofa, .bed])
    }

    @Test func nonOverlappingSameCategoryStaySeparateTracksButOnlyOneReturned() {
        // Two sofas in different parts of the frame: two tracks, but consensus
        // returns at most one sofa (the higher mean-confidence one).
        let left = CGRect(x: 0.0, y: 0.2, width: 0.25, height: 0.3)
        let right = CGRect(x: 0.7, y: 0.2, width: 0.25, height: 0.3)
        let confirmed = consensus([
            obs(.sofa, left, 0.0, confidence: 0.75), obs(.sofa, left, 0.1, confidence: 0.75), obs(.sofa, left, 0.2, confidence: 0.75),
            obs(.sofa, right, 0.0, confidence: 0.95), obs(.sofa, right, 0.1, confidence: 0.95), obs(.sofa, right, 0.2, confidence: 0.95),
        ])
        #expect(confirmed.count == 1)
        // The returned observation should come from the higher-confidence cluster.
        #expect((confirmed.first?.confidence ?? 0) > 0.9)
    }

    @Test func emptyInputYieldsNoDetections() {
        #expect(consensus([]).isEmpty)
    }
}
