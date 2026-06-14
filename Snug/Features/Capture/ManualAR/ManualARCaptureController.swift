import Foundation
import ARKit
import RealityKit
import Combine
import simd
import UIKit

/// Drives the AR-assisted corner-tapping capture: it owns the ARKit session,
/// turns screen taps into metric floor coordinates via raycasting, renders the
/// growing outline, estimates the ceiling height, and assembles a `RoomModel`
/// at the end.
///
/// This is the de-facto implementation object for `ManualARCaptureMethod` (the
/// method struct is a stateless factory; all per-session AR state lives here).
/// It runs on `ARWorldTrackingConfiguration` with no LiDAR dependency, so it
/// works on any modern iPhone. It is an `NSObject`/`ObservableObject` (rather
/// than `@Observable`) because it has to be the `ARSession` and coaching-overlay
/// delegate, which require `NSObject` conformance; the published properties
/// drive the SwiftUI overlay.
///
/// Capture-quality bookkeeping (`floorTaps`, the weighted `sessionFloorY`, the
/// ceiling pipeline, `usedHighWallProjection`) is documented at length in
/// CLAUDE.md under "Manual AR capture". Per the architecture rules, none of it
/// leaks into `RoomModel` except `resolvedCeilingHeight`, written once at close.
final class ManualARCaptureController: NSObject, ObservableObject, ARSessionDelegate, ARCoachingOverlayViewDelegate {

    /// Where we are in the capture flow. Note: there is no longer a manual
    /// `measuringHeight` step — ceiling height is estimated automatically (see
    /// the ceiling pipeline below), with an optional "look up" prompt at close.
    enum Step: Equatable {
        case findingFloor
        case markingCorners
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

    /// How much we trust the resolved ceiling height. Drives the display copy
    /// and the conditional correction-canvas trigger.
    enum CeilingConfidence: Equatable {
        /// RoomPlan height (LiDAR) or a successful "look up" active estimate.
        case high
        /// Passive-only estimate, or the hardcoded default fallback.
        case low
    }

    // MARK: - Published state

    @Published private(set) var step: Step = .findingFloor
    @Published private(set) var corners: [PlanePoint] = []
    @Published private(set) var openings: [RoomOpening] = []
    @Published private(set) var trackingQuality: TrackingQuality = .initializing
    @Published private(set) var lastRaycastFailed = false
    /// First tap of an in-progress opening; the second tap completes it.
    @Published private(set) var pendingOpeningStart: PlanePoint?
    /// Which kind of opening the next tap-pair will create.
    @Published var openingKind: RoomOpening.Kind = .door
    /// Set when an attempt to close the room was rejected (e.g. the corners are
    /// nearly in a line, so there's no real floor area). Surfaced to the user
    /// rather than silently producing a fake room.
    @Published private(set) var closeWarning: String?

    // MARK: High-wall projection (Part 1)

    /// True while the "Corner blocked?" toggle is active: the next tap targets a
    /// point on the wall *above* a blocked corner, which we project straight down
    /// to the floor baseline. Always toggleable; never disabled.
    @Published private(set) var isHighWallModeActive = false
    /// True once at least one corner was placed via high-wall projection. Feeds
    /// the conditional correction-canvas trigger; never written to `RoomModel`.
    @Published private(set) var usedHighWallProjection = false
    /// True when the cumulative deduplicated floor-tap weight exceeds `2.0`.
    /// Mirrors the private `floorTaps` weight sum for the SwiftUI overlay.
    @Published private(set) var floorLocked = false

    // MARK: Ceiling look-up (Part 2)

    /// True while the active "point at the ceiling" overlay is showing.
    @Published private(set) var isLookingUp = false
    /// Copy for the look-up overlay (extends to "Keep pointing up…" on retry).
    @Published private(set) var lookUpPrompt = "Almost done — point your phone at the ceiling for 1 second."

    // MARK: Two-tap intersection (deprecated — replaced by high-wall projection)

    /// Sub-flow kept only so the deprecated intersection machinery still
    /// compiles. No active UI path drives it any more; see high-wall projection.
    enum IntersectionStage: Equatable {
        case inactive
        case awaitingLeft
        case awaitingRight
        case preview
    }

    @Published private(set) var intersectionStage: IntersectionStage = .inactive
    @Published private(set) var intersectionWarning: String?
    @Published private(set) var pendingIntersectionCorner: PlanePoint?

    /// Smallest floor area we'll accept as a real room (m²). Below this the
    /// corners are effectively collinear/coincident — honesty over a fake scan.
    private static let minimumFloorArea: Float = 0.1

    /// Called once with the finished room.
    var onComplete: ((RoomModel) -> Void)?

    // MARK: - AR scene

    private weak var arView: ARView?
    private var floorY: Float?
    private var cornerMarkers: [AnchorEntity] = []
    private let edgeContainer = AnchorEntity(world: .zero)
    private let previewContainer = AnchorEntity(world: .zero)

    /// Whether this device can build a scene mesh (LiDAR). Drives the
    /// ceiling-estimation pipeline's device-capability split. Computed once.
    let supportsMesh = ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh)

    // MARK: - Floor baseline (Part 1)

    /// Weighted floor-height samples. Each direct floor-corner tap contributes
    /// one (after spatial deduplication); high-wall taps never append here.
    private var floorTaps: [(y: Float, weight: Float, anchorID: UUID, position: simd_float2)] = []

    /// Weighted-average floor height across all accepted floor taps.
    private var sessionFloorY: Float? {
        guard !floorTaps.isEmpty else { return nil }
        let totalWeight = floorTaps.reduce(0) { $0 + $1.weight }
        return floorTaps.reduce(0) { $0 + $1.y * $1.weight } / totalWeight
    }

    /// Cumulative deduplicated floor-tap weight. Floor is "locked" above `2.0`.
    private var cumulativeFloorWeight: Float {
        floorTaps.reduce(0) { $0 + $1.weight }
    }

    // MARK: - Ceiling estimation (Part 2)

    /// World-space high points observed passively throughout the scan, tagged
    /// with the camera position at observation time (for spatial-spread gating).
    private var ceilingCandidates: [(y: Float, cameraPosition: simd_float3)] = []
    /// Distinct camera XZ positions that contributed passive candidates.
    private var passiveCameraPositions: [simd_float2] = []
    /// Active "look up" hits: mesh-vertex Y values (LiDAR) above the threshold.
    private var activeMeshHits: [Float] = []
    /// Active "look up" feature points, deduplicated by ARKit identifier.
    private var activeFeaturePoints: [UInt64: Float] = [:]
    /// Mesh anchors currently known (LiDAR only), keyed by identifier.
    private var meshAnchors: [UUID: ARMeshAnchor] = [:]

    /// Passive ceiling estimate (m above the floor), or nil if the usable
    /// threshold wasn't met. Computed at scan close.
    private(set) var passiveCeilingHeight: Float?
    /// Active "look up" ceiling estimate (m above the floor), or nil.
    private(set) var activeCeilingHeight: Float?
    /// RoomPlan ceiling height — only ever non-nil on LiDAR devices that run
    /// RoomPlan. The manual-AR method does not run RoomPlan, so this stays nil
    /// here; it is kept in the resolution order so the priority chain reads
    /// faithfully and a future RoomPlan hand-off can populate it.
    private(set) var roomPlanCeilingHeight: Float?
    /// The single ceiling value written to `RoomModel` at close. Defaults to the
    /// honest 2.5 m fallback until resolution runs.
    private(set) var resolvedCeilingHeight: Float = 2.5
    /// Confidence in `resolvedCeilingHeight`; drives display copy and the
    /// conditional correction-canvas trigger.
    private(set) var ceilingConfidence: CeilingConfidence = .low

    /// Floor-relative height below which a point is too low to be ceiling: it's
    /// furniture, a door frame, or a mid-wall feature.
    private static let ceilingFloorClearance: Float = 1.8
    /// Hardcoded final fallback ceiling height (m).
    private static let defaultCeilingHeight: Float = 2.5

    // MARK: - Correction-canvas trigger (Part 3)

    /// Whether the post-capture drag-to-correct canvas should open automatically.
    /// True if high-wall projection was used, the floor never locked, or the
    /// ceiling height is low-confidence.
    var needsCorrectionCanvas: Bool {
        usedHighWallProjection || !floorLocked || ceilingConfidence == .low
    }

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

        arView.session.run(makeConfiguration())

        arView.scene.addAnchor(edgeContainer)
        arView.scene.addAnchor(previewContainer)
        addCoachingOverlay(to: arView)

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        arView.addGestureRecognizer(tap)
    }

    private func makeConfiguration() -> ARWorldTrackingConfiguration {
        let config = ARWorldTrackingConfiguration()
        // Horizontal planes anchor the floor; vertical planes help when marking
        // openings on walls.
        config.planeDetection = [.horizontal, .vertical]
        // On LiDAR devices, build a scene mesh so the ceiling "look up" step can
        // intersect real geometry rather than sparse feature points.
        if supportsMesh {
            config.sceneReconstruction = .mesh
        }
        return config
    }

    func stop() {
        arView?.session.pause()
    }

    /// Resets all capture state and restarts the session — used by the canvas's
    /// "Rescan" action so a retry never inherits the previous attempt's taps.
    func reset() {
        step = .findingFloor
        corners = []
        openings = []
        pendingOpeningStart = nil
        closeWarning = nil
        lastRaycastFailed = false
        floorY = nil
        floorTaps = []
        floorLocked = false
        isHighWallModeActive = false
        usedHighWallProjection = false
        ceilingCandidates = []
        passiveCameraPositions = []
        activeMeshHits = []
        activeFeaturePoints = [:]
        meshAnchors = [:]
        passiveCeilingHeight = nil
        activeCeilingHeight = nil
        roomPlanCeilingHeight = nil
        resolvedCeilingHeight = Self.defaultCeilingHeight
        ceilingConfidence = .low
        isLookingUp = false
        cornerMarkers.forEach { $0.removeFromParent() }
        cornerMarkers.removeAll()
        edgeContainer.children.removeAll()
        previewContainer.children.removeAll()
        arView?.session.run(makeConfiguration(), options: [.removeExistingAnchors, .resetTracking])
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
            if isHighWallModeActive {
                handleHighWallTap(at: point, in: arView)
            } else if let hit = raycastFloor(from: point, in: arView) {
                recordFloorTap(hit)
                addCorner(at: hit.world)
            } else {
                flagRaycastFailure()
            }
        case .markingOpenings:
            if let hit = raycastFloor(from: point, in: arView) {
                addOpeningPoint(PlanePoint(x: hit.world.x, z: hit.world.z))
            } else {
                flagRaycastFailure()
            }
        case .review:
            break
        }
    }

    /// A raycast onto a horizontal surface, tagged with the floor-tap weight and
    /// anchor identity the floor-baseline accounting needs.
    private struct FloorRaycast {
        let world: SIMD3<Float>
        let weight: Float
        let anchorID: UUID
        let isPlaneAnchor: Bool
    }

    /// Raycasts a screen point to a horizontal plane (existing or estimated),
    /// returning the world-space hit plus its floor-tap weight. Works without
    /// LiDAR via plane estimation from feature points.
    ///
    /// Weight mapping (exact, no invented confidence APIs):
    /// - `ARPlaneAnchor` classified `.floor` → `1.0`
    /// - any other detected plane anchor → `0.5`
    /// - estimated geometry only (no plane anchor) → `0.2`
    private func raycastFloor(from point: CGPoint, in arView: ARView) -> FloorRaycast? {
        let results = arView.raycast(from: point, allowing: .estimatedPlane, alignment: .horizontal)
        guard let result = results.first else { return nil }
        let w = result.worldTransform.columns.3
        let world = SIMD3(w.x, w.y, w.z)

        if let plane = result.anchor as? ARPlaneAnchor {
            let weight: Float = plane.classification == .floor ? 1.0 : 0.5
            return FloorRaycast(world: world, weight: weight, anchorID: plane.identifier, isPlaneAnchor: true)
        }
        // Estimated geometry — no plane anchor. A fresh UUID means the
        // unique-anchor dedup branch can never match for estimated taps; they
        // fall back to the 0.5 m spatial rule.
        return FloorRaycast(world: world, weight: 0.2, anchorID: UUID(), isPlaneAnchor: false)
    }

    /// Accumulates a floor-baseline sample after spatial deduplication. A tap is
    /// only kept if it is ≥ 0.5 m (XZ) from every existing tap, or it belongs to
    /// a plane anchor not yet represented. This stops repeated taps in one spot
    /// from dominating the weighted average (which would bias the baseline and
    /// warp every projected high-wall corner).
    private func recordFloorTap(_ hit: FloorRaycast) {
        let posXZ = simd_float2(hit.world.x, hit.world.z)
        let farEnough = floorTaps.allSatisfy { simd_distance($0.position, posXZ) >= 0.5 }
        let uniqueAnchor = hit.isPlaneAnchor && !floorTaps.contains { $0.anchorID == hit.anchorID }
        guard farEnough || uniqueAnchor else { return }

        floorTaps.append((y: hit.world.y, weight: hit.weight, anchorID: hit.anchorID, position: posXZ))
        floorLocked = cumulativeFloorWeight > 2.0
    }

    private func flagRaycastFailure() {
        lastRaycastFailed = true
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
    }

    // MARK: - High-wall projection (Part 1)

    /// Toggle the "Corner blocked?" mode. Always available — never disabled —
    /// even before the floor is locked (the UI shows a soft warning instead).
    func toggleHighWallMode() {
        isHighWallModeActive.toggle()
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    /// Place a corner from a tap on the wall above a blocked floor corner: keep
    /// the raycast's X/Z, but replace Y with the floor baseline. The corner is
    /// stored already floor-snapped, so it never appends to `floorTaps`.
    private func handleHighWallTap(at screenPoint: CGPoint, in arView: ARView) {
        guard let hit = raycastFloor(from: screenPoint, in: arView) else {
            flagRaycastFailure()
            return
        }

        let baselineY: Float
        if let y = sessionFloorY {
            baselineY = y
        } else {
            // Live fallback (NOT dead code): no floor tap yet, so estimate the
            // floor as 1.4 m below the camera and warn.
            baselineY = cameraY(in: arView) - 1.4
            NSLog("[ManualARCapture] High-wall tap before floor lock; estimating floor as cameraY - 1.4.")
        }

        usedHighWallProjection = true
        if floorY == nil { floorY = baselineY }
        // X/Z from the wall tap, Y from the floor baseline — already snapped.
        addCorner(at: SIMD3(hit.world.x, baselineY, hit.world.z))
    }

    private func cameraY(in arView: ARView) -> Float {
        arView.session.currentFrame?.camera.transform.columns.3.y ?? 0
    }

    // MARK: - Corners

    private func addCorner(at hit: SIMD3<Float>) {
        // Keep the render baseline aligned with the weighted floor once we have
        // one, so markers and edges sit on the same plane as projected corners.
        floorY = sessionFloorY ?? floorY ?? hit.y
        appendCorner(PlanePoint(x: hit.x, z: hit.z))
    }

    /// Shared corner-append used by both direct taps and high-wall projection.
    private func appendCorner(_ corner: PlanePoint) {
        lastRaycastFailed = false
        closeWarning = nil
        corners.append(corner)
        let y = floorY ?? 0
        placeCornerMarker(at: SIMD3(corner.x, y, corner.z))
        // Only the one new trailing edge changed — append it rather than
        // rebuilding every edge mesh on each tap during live AR.
        if corners.count >= 2 {
            let a = corners[corners.count - 2].simd2
            let b = corners[corners.count - 1].simd2
            addEdge(from: SIMD3(a.x, y, a.y), to: SIMD3(b.x, y, b.y))
        }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    func undoLastCorner() {
        guard !corners.isEmpty else { return }
        closeWarning = nil
        corners.removeLast()
        if let marker = cornerMarkers.popLast() {
            marker.removeFromParent()
        }
        if corners.isEmpty { floorY = nil }
        rebuildEdges()
    }

    func closePolygon() {
        guard canClosePolygon else { return }
        // Reject a degenerate outline (collinear/coincident taps) instead of
        // advancing with a zero-area "room" the fit system would trust.
        guard Self.polygonArea(corners) >= Self.minimumFloorArea else {
            closeWarning = "That doesn't look like a room yet — the corners are nearly in a line. Re-tap them around the floor."
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            return
        }
        closeWarning = nil
        rebuildEdges(closed: true)
        // Ceiling is estimated automatically (no manual measuring step), so go
        // straight to optional openings.
        step = .markingOpenings
    }

    /// Shoelace area of a floor polygon, winding-agnostic.
    private static func polygonArea(_ corners: [PlanePoint]) -> Float {
        guard corners.count >= 3 else { return 0 }
        var sum: Float = 0
        for i in corners.indices {
            let a = corners[i]
            let b = corners[(i + 1) % corners.count]
            sum += a.x * b.z - b.x * a.z
        }
        return abs(sum) / 2
    }

    /// Manual escape from the floor-finding step: if coaching never completes
    /// (a featureless room) but tracking is good, let the user start anyway so
    /// they're never trapped on the coaching screen.
    func beginMarkingManually() {
        guard step == .findingFloor else { return }
        step = .markingCorners
    }

    // MARK: - Ceiling estimation: passive collection (Part 2)

    /// Passive collection runs silently every frame on all devices. A candidate
    /// is kept only when it is comfortably above the floor and the camera has
    /// moved ≥ 0.4 m horizontally since the last contributing position — so the
    /// estimate reflects real spatial spread, not one spot stared at repeatedly.
    private func collectPassiveCeiling(_ frame: ARFrame) {
        guard let floor = sessionFloorY, let points = frame.rawFeaturePoints?.points else { return }
        let cam = frame.camera.transform.columns.3
        let camXZ = simd_float2(cam.x, cam.z)
        guard passiveCameraPositions.allSatisfy({ simd_distance($0, camXZ) >= 0.4 }) else { return }

        let camPos = simd_float3(cam.x, cam.y, cam.z)
        var added = false
        for p in points where p.y >= floor + Self.ceilingFloorClearance {
            ceilingCandidates.append((y: p.y, cameraPosition: camPos))
            added = true
        }
        if added { passiveCameraPositions.append(camXZ) }
    }

    /// Passive estimate: 95th-percentile candidate Y minus the floor, but only
    /// once we have ≥ 12 candidates from ≥ 3 distinct camera positions. Below
    /// that the data is discarded regardless of the Y values collected.
    private func computePassiveCeilingHeight() -> Float? {
        guard let floor = sessionFloorY else { return nil }
        guard ceilingCandidates.count >= 12, passiveCameraPositions.count >= 3 else { return nil }
        let sorted = ceilingCandidates.map(\.y).sorted()
        return Self.percentile(sorted, 0.95) - floor
    }

    /// Largest pairwise distance between passive capture positions — the "spread"
    /// that decides whether the passive estimate is trustworthy on its own.
    private func passiveCameraSpread() -> Float {
        var maxD: Float = 0
        for i in passiveCameraPositions.indices {
            for j in (i + 1)..<passiveCameraPositions.count {
                maxD = max(maxD, simd_distance(passiveCameraPositions[i], passiveCameraPositions[j]))
            }
        }
        return maxD
    }

    // MARK: - Ceiling estimation: active "look up" step (Part 2)

    /// Active collection runs only during the look-up window. Feature points are
    /// gathered on all devices (they back the non-LiDAR path and serve as the
    /// LiDAR fall-through when mesh hits are too few); LiDAR mesh hits are sampled
    /// separately from anchors at evaluation time (`sampleMeshHits`).
    private func collectActiveCeiling(_ frame: ARFrame) {
        guard let floor = sessionFloorY, let cloud = frame.rawFeaturePoints else { return }
        for (id, p) in zip(cloud.identifiers, cloud.points) where p.y >= floor + Self.ceilingFloorClearance {
            activeFeaturePoints[id] = p.y
        }
    }

    /// Snapshot mesh-vertex Y values above the ceiling threshold from all known
    /// mesh anchors. Used by the LiDAR look-up path in lieu of per-ray mesh
    /// intersection (simpler and robust); each qualifying vertex counts as a hit.
    private func sampleMeshHits() {
        guard let floor = sessionFloorY else { return }
        activeMeshHits.removeAll()
        for anchor in meshAnchors.values {
            let geometry = anchor.geometry
            let vertices = geometry.vertices
            let buffer = vertices.buffer.contents()
            for i in 0..<vertices.count {
                let ptr = buffer.advanced(by: vertices.offset + vertices.stride * i)
                // ARMeshGeometry packs vertices as three tightly-strided floats
                // (stride 12); read them individually rather than as a 16-byte
                // SIMD3 to avoid over-reading past the buffer.
                let local = ptr.assumingMemoryBound(to: (Float, Float, Float).self).pointee
                let world = anchor.transform * simd_make_float4(local.0, local.1, local.2, 1)
                if world.y >= floor + Self.ceilingFloorClearance {
                    activeMeshHits.append(world.y)
                }
            }
        }
    }

    /// Whether the look-up step should run: there is no usable passive estimate,
    /// or the passive observations were all bunched within ~1 m of each other.
    private func shouldRunLookUp() -> Bool {
        passiveCeilingHeight == nil || passiveCameraSpread() < 1.0
    }

    // MARK: - Finish & ceiling resolution (Part 2)

    /// Begins the close sequence: compute the passive estimate, optionally run
    /// the look-up step, resolve the final ceiling height, then build the room.
    func finish() {
        guard corners.count >= 3 else { return }
        step = .review
        passiveCeilingHeight = computePassiveCeilingHeight()

        if shouldRunLookUp() {
            Task { @MainActor in
                await runLookUp()
                resolveCeilingAndComplete()
            }
        } else {
            resolveCeilingAndComplete()
        }
    }

    /// Drive the 1-second look-up window (extending once for non-LiDAR if the
    /// feature-point count is short), then compute `activeCeilingHeight`.
    @MainActor
    private func runLookUp() async {
        activeMeshHits.removeAll()
        activeFeaturePoints.removeAll()
        lookUpPrompt = "Almost done — point your phone at the ceiling for 1 second."
        isLookingUp = true

        try? await Task.sleep(nanoseconds: 1_000_000_000)

        if supportsMesh {
            sampleMeshHits()
            if activeMeshHits.count >= 5 {
                activeCeilingHeight = ceilingHeight(fromHits: activeMeshHits)
            } else {
                // Too few mesh hits — fall through to feature points.
                activeCeilingHeight = featurePointActiveHeight()
            }
        } else {
            if activeFeaturePoints.count < 15 {
                lookUpPrompt = "Keep pointing up…"
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            activeCeilingHeight = activeFeaturePoints.count >= 15 ? featurePointActiveHeight() : nil
        }

        isLookingUp = false
    }

    private func featurePointActiveHeight() -> Float? {
        guard let floor = sessionFloorY, !activeFeaturePoints.isEmpty else { return nil }
        let sorted = activeFeaturePoints.values.sorted()
        guard sorted.count >= 15 else { return nil }
        return Self.percentile(sorted, 0.95) - floor
    }

    private func ceilingHeight(fromHits hits: [Float]) -> Float? {
        guard let floor = sessionFloorY, !hits.isEmpty else { return nil }
        return Self.percentile(hits.sorted(), 0.95) - floor
    }

    /// Strict priority resolution, then build and emit the `RoomModel`.
    /// 1. RoomPlan (LiDAR) · 2. active look-up · 3. passive · 4. 2.5 m default.
    private func resolveCeilingAndComplete() {
        if let height = roomPlanCeilingHeight {
            resolvedCeilingHeight = height
            ceilingConfidence = .high
        } else if let height = activeCeilingHeight {
            resolvedCeilingHeight = height
            ceilingConfidence = .high
        } else if let height = passiveCeilingHeight {
            resolvedCeilingHeight = height
            ceilingConfidence = .low
        } else {
            resolvedCeilingHeight = Self.defaultCeilingHeight
            ceilingConfidence = .low
        }

        stop()
        let room = RoomModel(
            provenance: .manualAR,
            floorCorners: corners,
            ceilingHeight: resolvedCeilingHeight,
            openings: openings
        )
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        onComplete?(room)
    }

    /// Nearest-rank percentile of an ascending-sorted array.
    private static func percentile(_ sortedAscending: [Float], _ p: Float) -> Float {
        guard !sortedAscending.isEmpty else { return 0 }
        let rank = Int((p * Float(sortedAscending.count)).rounded(.up)) - 1
        return sortedAscending[min(max(rank, 0), sortedAscending.count - 1)]
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

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        collectPassiveCeiling(frame)
        if isLookingUp { collectActiveCeiling(frame) }
    }

    func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
        for case let mesh as ARMeshAnchor in anchors { meshAnchors[mesh.identifier] = mesh }
    }

    func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
        for case let mesh as ARMeshAnchor in anchors { meshAnchors[mesh.identifier] = mesh }
    }

    func session(_ session: ARSession, didRemove anchors: [ARAnchor]) {
        for case let mesh as ARMeshAnchor in anchors { meshAnchors[mesh.identifier] = nil }
    }

    func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
        let quality: TrackingQuality
        switch camera.trackingState {
        case .normal:
            quality = .good
        case .limited(let reason):
            quality = .limited(Self.describe(reason))
        case .notAvailable:
            quality = .initializing
        }
        // ARSession delegate callbacks are not guaranteed to run on the main
        // thread (the delegate queue defaults to a private queue), and
        // @Published mutations must be made on the main thread — hop explicitly.
        DispatchQueue.main.async { [weak self] in
            self?.trackingQuality = quality
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

    // MARK: - Two-tap intersection (DEPRECATED — replaced by high-wall projection)
    //
    // Retained, not deleted (per the migration plan): this is the old
    // "corner blocked" solution — sight down each of the two walls and intersect
    // the sighting lines. High-wall projection replaced it because it needs only
    // a single tap and doesn't depend on the user holding the phone parallel to
    // each wall (a fiddly, error-prone aim that produced near-parallel lines and
    // corners behind the user). The public entry points below are deprecated and
    // no UI path drives them; the supporting math is kept intact for reference.

    /// The wall sightings collected so far in intersection mode: each is a floor
    /// point on the wall plus the camera's horizontal forward (the wall's
    /// direction) and floor position at tap time.
    private var intersectionTaps: [(point: SIMD2<Float>, dir: SIMD2<Float>, camFloor: SIMD2<Float>)] = []
    private var intersectionFloorY: Float?

    @available(*, deprecated, message: "Use high-wall projection instead")
    func beginIntersectionMode() {
        guard step == .markingCorners, intersectionStage == .inactive else { return }
        intersectionTaps.removeAll()
        intersectionFloorY = nil
        pendingIntersectionCorner = nil
        intersectionWarning = nil
        lastRaycastFailed = false
        intersectionStage = .awaitingLeft
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    @available(*, deprecated, message: "Use high-wall projection instead")
    func cancelIntersectionMode() {
        intersectionStage = .inactive
        intersectionTaps.removeAll()
        intersectionFloorY = nil
        pendingIntersectionCorner = nil
        intersectionWarning = nil
        previewContainer.children.removeAll()
    }

    @available(*, deprecated, message: "Use high-wall projection instead")
    func confirmIntersectionCorner() {
        guard intersectionStage == .preview, let corner = pendingIntersectionCorner else { return }
        if floorY == nil { floorY = intersectionFloorY }
        appendCorner(corner)
        intersectionStage = .inactive
        intersectionTaps.removeAll()
        intersectionFloorY = nil
        pendingIntersectionCorner = nil
        intersectionWarning = nil
        previewContainer.children.removeAll()
    }

    private func handleIntersectionTap(at screenPoint: CGPoint, in arView: ARView) {
        guard let hit = raycastFloor(from: screenPoint, in: arView),
              let sighting = cameraSighting(in: arView) else {
            flagRaycastFailure()
            return
        }
        lastRaycastFailed = false
        intersectionWarning = nil
        if intersectionFloorY == nil { intersectionFloorY = hit.world.y }

        let tap = (point: SIMD2(hit.world.x, hit.world.z), dir: sighting.forward, camFloor: sighting.floorPosition)

        if intersectionStage == .awaitingLeft {
            intersectionTaps = [tap]
            intersectionStage = .awaitingRight
            redrawIntersectionPreview()
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            return
        }

        guard let left = intersectionTaps.first else {
            intersectionTaps = [tap]
            intersectionStage = .awaitingRight
            return
        }

        let angle = Self.angleBetween(left.dir, tap.dir)
        guard angle >= 15, angle <= 165,
              let point = Self.lineIntersection(p1: left.point, d1: left.dir,
                                                p2: tap.point, d2: tap.dir) else {
            intersectionWarning = "These walls look parallel — tap two walls that meet at a corner."
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            redrawIntersectionPreview()
            return
        }

        let toPoint = point - tap.camFloor
        if simd_length(toPoint) > 1e-4, simd_dot(simd_normalize(toPoint), tap.dir) <= 0 {
            intersectionWarning = "Corner ended up behind you — try again from the other side."
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            redrawIntersectionPreview()
            return
        }

        intersectionTaps = [left, tap]
        pendingIntersectionCorner = PlanePoint(x: point.x, z: point.y)
        intersectionStage = .preview
        redrawIntersectionPreview()
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    private struct CameraSighting {
        let forward: SIMD2<Float>
        let floorPosition: SIMD2<Float>
    }

    private func cameraSighting(in arView: ARView) -> CameraSighting? {
        guard let frame = arView.session.currentFrame else { return nil }
        let transform = frame.camera.transform
        let forward3 = -SIMD3(transform.columns.2.x, transform.columns.2.y, transform.columns.2.z)
        let horizontal = SIMD2(forward3.x, forward3.z)
        let length = simd_length(horizontal)
        guard length > 1e-4 else { return nil }
        let position = transform.columns.3
        return CameraSighting(forward: horizontal / length,
                              floorPosition: SIMD2(position.x, position.z))
    }

    private static func angleBetween(_ a: SIMD2<Float>, _ b: SIMD2<Float>) -> Float {
        let clamped = min(max(simd_dot(a, b), -1), 1)
        return acos(clamped) * 180 / .pi
    }

    private static func lineIntersection(
        p1: SIMD2<Float>, d1: SIMD2<Float>,
        p2: SIMD2<Float>, d2: SIMD2<Float>
    ) -> SIMD2<Float>? {
        let denom = d1.x * d2.y - d1.y * d2.x
        guard abs(denom) > 1e-6 else { return nil }
        let diff = p2 - p1
        let t = (diff.x * d2.y - diff.y * d2.x) / denom
        let point = p1 + t * d1
        guard point.x.isFinite, point.y.isFinite else { return nil }
        return point
    }

    private func redrawIntersectionPreview() {
        previewContainer.children.removeAll()
        let y = floorY ?? intersectionFloorY ?? 0
        for tap in intersectionTaps {
            addDashedLine(through: tap.point, direction: tap.dir, y: y)
        }
        if let corner = pendingIntersectionCorner {
            let sphere = ModelEntity(
                mesh: .generateSphere(radius: 0.04),
                materials: [SimpleMaterial(color: .systemGreen, isMetallic: false)]
            )
            let anchor = AnchorEntity(world: SIMD3(corner.x, y, corner.z))
            anchor.addChild(sphere)
            previewContainer.addChild(anchor)
        }
    }

    private func addDashedLine(through point: SIMD2<Float>, direction dir: SIMD2<Float>, y: Float) {
        let halfLength: Float = 4
        let dash: Float = 0.1, gap: Float = 0.1
        var s: Float = -halfLength
        while s < halfLength {
            let a = point + dir * s
            let b = point + dir * min(s + dash, halfLength)
            addPreviewSegment(from: SIMD3(a.x, y, a.y), to: SIMD3(b.x, y, b.y))
            s += dash + gap
        }
    }

    private func addPreviewSegment(from a: SIMD3<Float>, to b: SIMD3<Float>) {
        let length = simd_distance(a, b)
        guard length > 0 else { return }
        let box = ModelEntity(
            mesh: .generateBox(size: SIMD3(length, 0.008, 0.008)),
            materials: [SimpleMaterial(color: .systemYellow, isMetallic: false)]
        )
        box.position = (a + b) / 2
        let yaw = atan2(b.z - a.z, b.x - a.x)
        box.orientation = simd_quatf(angle: -yaw, axis: SIMD3(0, 1, 0))
        previewContainer.addChild(box)
    }
}
