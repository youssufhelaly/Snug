import SwiftUI
import ARKit

/// AR-assisted corner-tapping capture — Snug's default method. Runs on any
/// iPhone with ARKit world tracking (no LiDAR), which is why it leads the
/// registry and is the experience non-Pro users get.
struct ManualARCaptureMethod: RoomCaptureMethod {
    let id = "manual-ar"
    let displayName = "Tap the corners"
    let summary = "Point at the floor and tap each corner. Works on any recent iPhone."
    let provenance: RoomCaptureProvenance = .manualAR

    var isSupported: Bool { ARWorldTrackingConfiguration.isSupported }

    func makeCaptureView(
        onComplete: @escaping (RoomModel) -> Void,
        onFailure: @escaping (CaptureFailure) -> Void
    ) -> AnyView {
        AnyView(ManualARCaptureView(onComplete: onComplete, onFailure: onFailure))
    }
}
