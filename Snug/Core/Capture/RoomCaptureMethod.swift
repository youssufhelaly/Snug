import SwiftUI

/// A way to capture a room into the app's shared `RoomModel`.
///
/// The point of this protocol is that the rest of Snug — editor, catalog, fit
/// system, accuracy logger — depends only on `RoomModel`, never on *how* the
/// room was measured. RoomPlan (LiDAR) and AR-assisted corner tapping are two
/// conformers; a future manual-typing or remote method could be a third
/// without touching anything downstream.
@MainActor
protocol RoomCaptureMethod: Identifiable {
    /// Stable identifier, also used as the picker selection tag.
    var id: String { get }
    /// Short, friendly name for the method picker.
    var displayName: String { get }
    /// One-line description of how this method works / what it needs.
    var summary: String { get }
    /// Stamped onto every `RoomModel` this method produces.
    var provenance: RoomCaptureProvenance { get }
    /// Whether the current device can run this method right now.
    var isSupported: Bool { get }

    /// Builds the SwiftUI flow that drives one capture attempt. It calls
    /// `onComplete` with a finished `RoomModel`, or `onFailure` with a reason
    /// that maps to a friendly screen.
    func makeCaptureView(
        onComplete: @escaping (RoomModel) -> Void,
        onFailure: @escaping (CaptureFailure) -> Void
    ) -> AnyView
}

/// The capture methods Snug offers, in priority order. Manual AR is the
/// default because it runs on any modern iPhone; RoomPlan is offered only as a
/// higher-fidelity option on LiDAR-equipped Pro devices.
@MainActor
enum CaptureMethodRegistry {
    static var all: [any RoomCaptureMethod] {
        [ManualARCaptureMethod(), RoomPlanCaptureMethod()]
    }

    /// Methods this device can actually run.
    static var supported: [any RoomCaptureMethod] {
        all.filter(\.isSupported)
    }

    /// The method to start with: the first supported one (Manual AR on
    /// non-Pro devices, still Manual AR on Pro devices unless the user picks
    /// RoomPlan).
    static var `default`: (any RoomCaptureMethod)? {
        supported.first
    }
}
