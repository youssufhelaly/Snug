import Foundation
import RoomPlan

/// One completed scan session.
///
/// `CapturedRoom` carries no public identity of its own, so every successful
/// capture is wrapped with our own id and timestamp. That id is what the
/// accuracy logger and fixture exporter use to refer to "this room."
struct ScanRecord: Identifiable {
    let id: UUID
    let capturedAt: Date
    let room: CapturedRoom

    init(room: CapturedRoom, id: UUID = UUID(), capturedAt: Date = Date()) {
        self.id = id
        self.capturedAt = capturedAt
        self.room = room
    }
}

/// Why a capture attempt ended without a usable room.
///
/// Every case maps to a dedicated friendly screen in `CaptureFailureView` —
/// per CLAUDE.md's hard rules, a failed scan is *told to the user*, never
/// papered over with invented geometry.
enum CaptureFailure: Equatable {
    /// Device has no LiDAR or RoomPlan is otherwise unavailable.
    case deviceUnsupported
    /// User declined (or previously declined) camera access.
    case cameraPermissionDenied
    /// User backed out mid-sweep before processing finished.
    case cancelled
    /// RoomPlan threw while capturing or post-processing the room.
    /// The associated value is a short human-readable detail used in the
    /// debug disclosure, not the headline copy.
    case processingFailed(String)
}
