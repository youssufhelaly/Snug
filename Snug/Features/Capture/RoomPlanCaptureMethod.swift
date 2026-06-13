import SwiftUI
import RoomPlan

/// RoomPlan (LiDAR) capture, wrapped as a `RoomCaptureMethod`. The actual
/// capture UI and session handling are the existing, untouched `CaptureScreen`
/// / `RoomCaptureCoordinator`; this conformer just adapts their `ScanRecord`
/// (a `CapturedRoom`) into the shared `RoomModel`.
///
/// It is only offered on LiDAR devices and is no longer the default — the
/// AR-assisted method runs everywhere. Nothing about the RoomPlan path was
/// removed in the pivot; it's demoted, not deleted.
struct RoomPlanCaptureMethod: RoomCaptureMethod {
    let id = "roomplan"
    let displayName = "LiDAR scan"
    let summary = "Fast 10-second sweep. Pro iPhones with LiDAR only."
    let provenance: RoomCaptureProvenance = .roomPlan

    var isSupported: Bool { RoomCaptureSession.isSupported }

    func makeCaptureView(
        onComplete: @escaping (RoomModel) -> Void,
        onFailure: @escaping (CaptureFailure) -> Void
    ) -> AnyView {
        AnyView(
            CaptureScreen(
                onComplete: { record in
                    onComplete(RoomModel(capturedRoom: record.room, id: record.id, capturedAt: record.capturedAt))
                },
                onFailure: onFailure
            )
        )
    }
}
