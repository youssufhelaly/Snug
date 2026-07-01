import Foundation
import Testing
import simd
@testable import Snug

/// "Snap to wall" geometry: picking the wall the user tapped toward, then placing
/// a piece flush against *that* wall with its back to it. Square room, corners (x, z).
struct WallSnapServiceTests {

    /// 4×4 m room centered on the origin. Walls: 0 = bottom (z=-2), 1 = right (x=2),
    /// 2 = top (z=2), 3 = left (x=-2).
    private let square: [SIMD2<Float>] = [
        SIMD2(-2, -2), SIMD2(2, -2), SIMD2(2, 2), SIMD2(-2, 2)
    ]

    @Test func nearestWallIndexTracksTheTappedPoint() {
        #expect(WallSnapService.nearestWallIndex(to: SIMD2(0, -1.9), corners: square) == 0) // bottom
        #expect(WallSnapService.nearestWallIndex(to: SIMD2(1.9, 0), corners: square) == 1)  // right
        #expect(WallSnapService.nearestWallIndex(to: SIMD2(0, 1.9), corners: square) == 2)  // top
        #expect(WallSnapService.nearestWallIndex(to: SIMD2(-1.9, 0), corners: square) == 3) // left
    }

    @Test func snapsPieceFlushToTheChosenWallBackAgainstIt() throws {
        // Snap to the RIGHT wall (index 1), piece currently mid-room, depth 0.8.
        let snap = try #require(WallSnapService.snap(
            pieceCenter: SIMD2(0, 0), width: 1.0, depth: 0.8, toWall: 1, corners: square))
        // Inward normal (-1, 0); pushed in from x=2 by 0.4 + 0.02 → x ≈ 1.58, z kept.
        #expect(abs(snap.position.x - 1.58) < 0.001)
        #expect(abs(snap.position.y - 0.0) < 0.001)
        #expect(abs(snap.yRotation - (-.pi / 2)) < 0.001)   // atan2(-1, 0)
    }

    @Test func keepsPositionAlongTheWall() throws {
        // Snapping to the bottom wall (index 0) preserves the piece's x; only z moves.
        let snap = try #require(WallSnapService.snap(
            pieceCenter: SIMD2(1.2, 0.5), width: 0.6, depth: 0.6, toWall: 0, corners: square))
        #expect(abs(snap.position.x - 1.2) < 0.001)          // unchanged along the wall
        #expect(abs(snap.position.y - (-1.68)) < 0.001)      // z=-2 + 0.3 + 0.02
        #expect(abs(snap.yRotation - 0) < 0.001)             // inward normal (0,1) → yaw 0
    }

    @Test func chosenWallWinsEvenWhenAnotherIsCloser() throws {
        // Piece hugging the right wall, but the user asked for the LEFT wall (3).
        let snap = try #require(WallSnapService.snap(
            pieceCenter: SIMD2(1.8, 0), width: 0.8, depth: 0.8, toWall: 3, corners: square))
        #expect(abs(snap.position.x - (-1.58)) < 0.001)      // flush to the LEFT wall
        #expect(abs(snap.yRotation - (.pi / 2)) < 0.001)     // atan2(1, 0)
    }

    @Test func slidesAlongTheWallToTheNearestFreeSlot() throws {
        // The ideal slot is opposite the piece's center on the bottom wall (z≈-1.68,
        // x=0). Pretend the region x ∈ [-0.6, 0.6] there is occupied; the piece must
        // slide to the nearest free x just outside that band, on the closer side.
        let snap = try #require(WallSnapService.snap(
            pieceCenter: SIMD2(0.1, 0), width: 0.4, depth: 0.6, toWall: 0, corners: square,
            isFree: { position, _ in abs(position.x) > 0.6 - 1e-4 }))
        #expect(abs(snap.position.y - (-1.68)) < 0.001)      // still flush to the wall
        // Ideal x≈0.1 is blocked; nearest free is +x side (0.1 is closer to +0.6).
        #expect(snap.position.x > 0.6 - 0.06)                // just past the occupied band
        #expect(snap.position.x < 0.8)
    }

    @Test func fullWallFallsBackToTheIdealFlushSpot() throws {
        // Nothing is ever free → returns the ideal flush spot (caller lets it read red).
        let snap = try #require(WallSnapService.snap(
            pieceCenter: SIMD2(0.5, 0), width: 0.6, depth: 0.6, toWall: 0, corners: square,
            isFree: { _, _ in false }))
        #expect(abs(snap.position.x - 0.5) < 0.001)
        #expect(abs(snap.position.y - (-1.68)) < 0.001)
    }

    @Test func degenerateRoomOrBadIndexReturnsNil() {
        #expect(WallSnapService.nearestWallIndex(to: .zero, corners: []) == nil)
        #expect(WallSnapService.snap(pieceCenter: .zero, width: 0.8, depth: 0.8, toWall: 0, corners: []) == nil)
        #expect(WallSnapService.snap(pieceCenter: .zero, width: 0.8, depth: 0.8, toWall: 9, corners: square) == nil)
    }
}
