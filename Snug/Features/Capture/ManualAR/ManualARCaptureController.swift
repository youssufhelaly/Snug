import Foundation
import ARKit
import RealityKit
import Combine
import simd
import UIKit

/// Drives the AR-assisted corner-tapping capture: it owns the ARKit session,
/// turns screen taps into metric floor coordinates via raycasting, renders the
/// growing outline, and assembles a `RoomModel` at the end.
///
/// This runs on `ARWorldTrackingConfiguration` with no LiDAR dependency, so it
/// works on any modern iPhone. It is an `NSObject`/`ObservableObject` (rather
/// than `@Observable`) because it has to be the `ARSession` and coaching-overlay
/// delegate, which require `NSObject` conformance; the published properties
/// drive the SwiftUI overlay.
final class ManualARCaptureController: NSObject, ObservableObject, ARSessionDelegate, ARCoachingOverlayViewDelegate {

    /// Where we are in the capture flow.
    enum Step: Equatable {
        case findingFloor
        case markingCorners
        case measuringHeight
        case markingOpenings
        case review
    }

    /// ARKit tracking confidence, surfaced so the user is warned before they
    /// trust a low-quality measurement (CLAUDE.md: never hide low confidence).
    enum TrackingQuality: Equatable {
        case initializing
        case limited(String)
        case good

        var isUsable: Bool { self == .good }
    }

    // MARK: - Published state

    @Published private(set) var step: Step = .findingFloor
    @Published private(set) var corners: [PlanePoint] = []
    @Published private(set) var openings: [RoomOpening] = []
    @Published private(set) var ceilingHeight: Float?
    @Published private(set) var trackingQuality: TrackingQuality = .initializing
    @Published private(set) var lastRaycastFailed = false
    /// First tap of an in-progress opening; the second tap completes it.
    @Published private(set) var pendingOpeningStart: PlanePoint?
    /// Which kind of opening the next tap-pair will create.
    @Published var openingKind: RoomOpening.Kind = .door

    /// Called once with the finished room.
    var onComplete: ((RoomModel) -> Void)?

    // MARK: - AR scene

    private weak var arView: ARView?
    private var floorY: Float?
    private var cornerMarkers: [AnchorEntity] = []
    private let edgeContainer = AnchorEntity(world: .zero)

    // MARK: - Derived helpers for the UI

    /// Live edge lengths between consecutive marked corners (open polyline).
    var edgeLengths: [Float] {
        guard corners.count >= 2 else { return [] }
        return (1..<corners.count).map { corners[$0 - 1].distance(to: corners[$0]) }
    }

    var canClosePolygon: Bool { corners.count >= 3 }

    // MARK: - Session lifecycle

    func attach(to arView: ARView) {
        self.arView = arView
        arView.session.delegate = self

        let config = ARWorldTrackingConfiguration()
        // Horizontal planes anchor the floor (and let us detect the ceiling);
        // vertical planes help when marking openings on walls.
        config.planeDetection = [.horizontal, .vertical]
        arView.session.run(config)

        arView.scene.addAnchor(edgeContainer)
        addCoachingOverlay(to: arView)

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        arView.addGestureRecognizer(tap)
    }

    func stop() {
        arView?.session.pause()
    }

    private func addCoachingOverlay(to arView: ARView) {
        let coaching = ARCoachingOverlayView()
        coaching.goal = .horizontalPlane
        coaching.session = arView.session
        coaching.delegate = self
        coaching.activatesAutomatically = true
        coaching.translatesAutoresizingMaskIntoConstraints = false
        arView.addSubview(coaching)
        NSLayoutConstraint.activate([
            coaching.topAnchor.constraint(equalTo: arView.topAnchor),
            coaching.bottomAnchor.constraint(equalTo: arView.bottomAnchor),
            coaching.leadingAnchor.constraint(equalTo: arView.leadingAnchor),
            coaching.trailingAnchor.constraint(equalTo: arView.trailingAnchor),
        ])
    }

    // MARK: - Tap handling

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        guard let arView, let point = gesture.view.map({ gesture.location(in: $0) }) else { return }

        switch step {
        case .findingFloor:
            // Taps are ignored until the floor plane is established.
            break
        case .markingCorners:
            if let hit = raycastHorizontal(from: point, in: arView) {
                addCorner(at: hit)
            } else {
                flagRaycastFailure()
            }
        case .measuringHeight:
            if let hit = raycastHorizontal(from: point, in: arView), let floorY {
                let height = hit.y - floorY
                // Reject obvious mis-hits (floor re-taps) — a real ceiling is
                // well above head height. Manual entry remains available.
                if height > 1.5 {
                    setCeilingHeight(height)
                } else {
                    flagRaycastFailure()
                }
            } else {
                flagRaycastFailure()
            }
        case .markingOpenings:
            if let hit = raycastHorizontal(from: point, in: arView) {
                addOpeningPoint(PlanePoint(x: hit.x, z: hit.z))
            } else {
                flagRaycastFailure()
            }
        case .review:
            break
        }
    }

    /// Raycasts a screen point to a horizontal plane (existing or estimated),
    /// returning the world-space hit. Works without LiDAR via plane
    /// estimation from feature points.
    private func raycastHorizontal(from point: CGPoint, in arView: ARView) -> SIMD3<Float>? {
        let results = arView.raycast(from: point, allowing: .estimatedPlane, alignment: .horizontal)
        guard let world = results.first?.worldTransform.columns.3 else { return nil }
        return SIMD3(world.x, world.y, world.z)
    }

    private func flagRaycastFailure() {
        lastRaycastFailed = true
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
    }

    // MARK: - Corners

    private func addCorner(at hit: SIMD3<Float>) {
        lastRaycastFailed = false
        if floorY == nil { floorY = hit.y }
        corners.append(PlanePoint(x: hit.x, z: hit.z))
        placeCornerMarker(at: SIMD3(hit.x, floorY ?? hit.y, hit.z))
        rebuildEdges()
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    func undoLastCorner() {
        guard !corners.isEmpty else { return }
        corners.removeLast()
        if let marker = cornerMarkers.popLast() {
            marker.removeFromParent()
        }
        if corners.isEmpty { floorY = nil }
        rebuildEdges()
    }

    func closePolygon() {
        guard canClosePolygon else { return }
        rebuildEdges(closed: true)
        step = .measuringHeight
    }

    /// Manual escape from the floor-finding step: if coaching never completes
    /// (a featureless room) but tracking is good, let the user start anyway so
    /// they're never trapped on the coaching screen.
    func beginMarkingManually() {
        guard step == .findingFloor else { return }
        step = .markingCorners
    }

    // MARK: - Ceiling height

    private func setCeilingHeight(_ height: Float) {
        lastRaycastFailed = false
        ceilingHeight = height
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    /// Manual fallback for ceiling height — the honest escape hatch for the one
    /// measurement that non-LiDAR AR can't capture reliably.
    func setManualCeilingHeight(meters: Float) {
        guard meters > 0 else { return }
        ceilingHeight = meters
    }

    func confirmHeightAndContinue() {
        guard ceilingHeight != nil else { return }
        step = .markingOpenings
    }

    // MARK: - Openings

    private func addOpeningPoint(_ point: PlanePoint) {
        lastRaycastFailed = false
        if let start = pendingOpeningStart {
            openings.append(RoomOpening(kind: openingKind, start: start, end: point))
            pendingOpeningStart = nil
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        } else {
            pendingOpeningStart = point
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
    }

    func removeLastOpening() {
        if pendingOpeningStart != nil {
            pendingOpeningStart = nil
        } else if !openings.isEmpty {
            openings.removeLast()
        }
    }

    // MARK: - Finish

    func finish() {
        guard corners.count >= 3, let height = ceilingHeight else { return }
        step = .review
        stop()
        let room = RoomModel(
            provenance: .manualAR,
            floorCorners: corners,
            ceilingHeight: height,
            openings: openings
        )
        onComplete?(room)
    }

    // MARK: - Rendering

    private func placeCornerMarker(at position: SIMD3<Float>) {
        let sphere = ModelEntity(
            mesh: .generateSphere(radius: 0.03),
            materials: [SimpleMaterial(color: .systemOrange, isMetallic: false)]
        )
        let anchor = AnchorEntity(world: position)
        anchor.addChild(sphere)
        arView?.scene.addAnchor(anchor)
        cornerMarkers.append(anchor)
    }

    /// Rebuilds the edge ribbons between corners as thin boxes. Cheap — the
    /// corner count is small (a handful) and edges only change on tap/undo.
    private func rebuildEdges(closed: Bool = false) {
        edgeContainer.children.removeAll()
        guard corners.count >= 2, let y = floorY else { return }
        let count = closed ? corners.count : corners.count - 1
        for i in 0..<count {
            let a = corners[i].simd2
            let b = corners[(i + 1) % corners.count].simd2
            addEdge(from: SIMD3(a.x, y, a.y), to: SIMD3(b.x, y, b.y))
        }
    }

    private func addEdge(from a: SIMD3<Float>, to b: SIMD3<Float>) {
        let length = simd_distance(a, b)
        guard length > 0 else { return }
        let box = ModelEntity(
            mesh: .generateBox(size: SIMD3(length, 0.01, 0.01)),
            materials: [SimpleMaterial(color: .systemTeal, isMetallic: false)]
        )
        box.position = (a + b) / 2
        let yaw = atan2(b.z - a.z, b.x - a.x)
        box.orientation = simd_quatf(angle: -yaw, axis: SIMD3(0, 1, 0))
        edgeContainer.addChild(box)
    }

    // MARK: - ARSessionDelegate

    func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
        switch camera.trackingState {
        case .normal:
            trackingQuality = .good
        case .limited(let reason):
            trackingQuality = .limited(Self.describe(reason))
        case .notAvailable:
            trackingQuality = .initializing
        }
    }

    private static func describe(_ reason: ARCamera.TrackingState.Reason) -> String {
        switch reason {
        case .initializing: "Starting up — move the phone slowly."
        case .excessiveMotion: "Slow down — you're moving too fast."
        case .insufficientFeatures: "Not enough detail here — try better light or more texture."
        case .relocalizing: "Re-finding your room — hold steady."
        @unknown default: "Tracking is limited — move slowly."
        }
    }

    // MARK: - ARCoachingOverlayViewDelegate

    func coachingOverlayViewDidDeactivate(_ coachingOverlayView: ARCoachingOverlayView) {
        // The floor plane is established; start collecting corners.
        if step == .findingFloor {
            step = .markingCorners
        }
    }
}
