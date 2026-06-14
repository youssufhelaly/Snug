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
    /// Set when a placement tap was ignored because tracking wasn't reliable
    /// enough yet. Surfaced so a tap that "does nothing" is explained, not silent.
    @Published private(set) var tapNeedsBetterTracking = false
    /// First tap of an in-progress opening; the second tap completes it.
    @Published private(set) var pendingOpeningStart: PlanePoint?
    /// Wall segment used by the first tap of an in-progress opening, so the
    /// second tap can be snapped to the same wall instead of a nearby AR plane.
    private var pendingOpeningWallIndex: Int?
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
    /// Derived from `floorTaps` (never stored) so it can't drift out of sync;
    /// the SwiftUI overlay re-reads it whenever `corners` changes, which is the
    /// same user action that mutates `floorTaps`.
    var floorLocked: Bool { cumulativeFloorWeight > 2.0 }

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

    /// Farthest a single tap can land from the camera and still be trusted (m).
    /// `.existingPlaneInfinite` raycasts can graze an infinitely-extended plane
    /// (the floor, or a wall seen edge-on) and resolve a "hit" 20+ m away. No
    /// renter's room corner is that far from the phone, so anything beyond this
    /// is a grazing artifact, not a real surface — reject it rather than place a
    /// corner that warps the whole floor plan and lags the scene. Set generously
    /// (a large studio's far corner can be ~8 m away when you stand back) but far
    /// below the 20 m+ artifacts this guards against.
    private static let maxTapReach: Float = 12.0

    /// Called once with the finished room.
    var onComplete: ((RoomModel) -> Void)?

    // MARK: - AR scene

    private weak var arView: ARView?
    private var floorY: Float?
    private var cornerMarkers: [AnchorEntity] = []
    private let edgeContainer = AnchorEntity(world: .zero)
    private let previewContainer = AnchorEntity(world: .zero)

    // Reused render resources. Every corner marker is the same sphere/material
    // and every edge shares one material, so build them once. More importantly,
    // the FIRST time RealityKit renders a `ModelEntity` with a `SimpleMaterial`
    // it compiles that material's Metal shader synchronously on the main thread
    // — the visible "first corner tap freezes" hitch. Creating these eagerly and
    // pre-warming them at session start (see `prewarmRenderResources`) pays that
    // cost during start-up, where a brief stall is invisible, not on the user's
    // first tap.
    private lazy var cornerMarkerMesh: MeshResource = .generateSphere(radius: 0.03)
    private lazy var cornerMarkerMaterial = SimpleMaterial(color: .systemOrange, isMetallic: false)
    private lazy var edgeMaterial = SimpleMaterial(color: .systemTeal, isMetallic: false)

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

    /// World-space high-point Y values observed passively throughout the scan.
    /// Capped at `maxCeilingCandidates` so a long sweep can't grow this without
    /// bound — a 95th-percentile only needs a modest sample.
    private var ceilingCandidates: [Float] = []
    /// Distinct camera XZ positions that contributed passive candidates.
    private var passiveCameraPositions: [simd_float2] = []
    /// The most recent camera position that contributed a passive candidate.
    /// The spread gate compares against this (not against every prior position)
    /// so revisiting an area doesn't permanently block further collection.
    private var lastPassiveCameraPosition: simd_float2?
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
    /// Plausible residential ceiling range accepted from the one-time look-up.
    private static let ceilingEstimateRange: ClosedRange<Float> = 2.1...3.2
    /// Minimum plausible ceiling feature points needed before trusting look-up.
    private static let minimumActiveCeilingPoints = 60
    /// Round accepted look-up estimates to 5 cm to avoid false precision.
    private static let ceilingEstimateStep: Float = 0.05
    /// Hardcoded final fallback ceiling height (m).
    private static let defaultCeilingHeight: Float = 2.5
    /// Upper bound on collected candidates (memory cap).
    private static let maxCeilingCandidates = 600

    // MARK: - Correction-canvas trigger (Part 3)

    /// Whether the post-capture drag-to-correct canvas should open automatically.
    /// True if high-wall projection was used, the floor never locked, the
    /// ceiling height is low-confidence, OR the captured polygon fails geometry
    /// validation (self-intersecting / degenerate). The geometry check matters
    /// even on an otherwise high-confidence capture: raycasts can snag on
    /// furniture and produce a bow-tie outline that must never reach the fit
    /// system unreviewed.
    var needsCorrectionCanvas: Bool {
        usedHighWallProjection
            || !floorLocked
            || ceilingConfidence == .low
            || !GeometryValidator().validate(corners).isValid
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
        // Pin delegate callbacks to the main queue. Every ceiling/floor/mesh
        // collection buffer touched in those callbacks (ceilingCandidates,
        // floorTaps, activeFeaturePoints, meshAnchors) is also read on the main
        // actor by the close sequence (finish / runLookUp), so delivering the
        // callbacks on main keeps all of that access on one thread instead of
        // racing ARKit's default private delegate queue. Per-frame work here is
        // light and gated (it only runs after the floor is established, is
        // capped, and the one heavy pass — sampleMeshHits — is bounded), so it
        // does not block rendering.
        arView.session.delegateQueue = .main

        arView.session.run(makeConfiguration())

        arView.scene.addAnchor(edgeContainer)
        arView.scene.addAnchor(previewContainer)
        addCoachingOverlay(to: arView)
        prewarmRenderResources(in: arView)

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        arView.addGestureRecognizer(tap)
    }

    /// Renders a zero-scale (invisible) marker for a moment at session start so
    /// RealityKit generates the marker mesh and compiles the `SimpleMaterial`
    /// shader up front. Without this the compile happens lazily on the first
    /// corner tap and stalls the main thread — the reported first-tap freeze.
    /// One warmed `SimpleMaterial` covers the edge material too (same shader).
    private func prewarmRenderResources(in arView: ARView) {
        let warmMarker = ModelEntity(mesh: cornerMarkerMesh, materials: [cornerMarkerMaterial])
        warmMarker.scale = SIMD3(repeating: 0.001)
        let warmEdge = ModelEntity(
            mesh: .generateBox(size: SIMD3(0.1, 0.01, 0.01)),
            materials: [edgeMaterial]
        )
        warmEdge.scale = SIMD3(repeating: 0.001)

        let anchor = AnchorEntity(world: .zero)
        anchor.addChild(warmMarker)
        anchor.addChild(warmEdge)
        arView.scene.addAnchor(anchor)
        // Keep them in the scene long enough to render at least one frame (which
        // triggers shader compilation), then drop them.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            anchor.removeFromParent()
        }

        // The first haptics also have a small first-fire latency; warm the
        // generators used by placement so the first taps feel instant.
        UIImpactFeedbackGenerator(style: .light).prepare()
        UIImpactFeedbackGenerator(style: .medium).prepare()
    }

    private func makeConfiguration() -> ARWorldTrackingConfiguration {
        let config = ARWorldTrackingConfiguration()
        // Horizontal planes anchor the floor; vertical planes help when marking
        // openings on walls.
        config.planeDetection = [.horizontal, .vertical]
        // Avoid scene reconstruction during manual capture. It adds meaningful
        // startup load on LiDAR devices, while this flow only needs plane
        // raycasts plus feature points for the optional ceiling estimate.
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
        pendingOpeningWallIndex = nil
        closeWarning = nil
        lastRaycastFailed = false
        tapNeedsBetterTracking = false
        floorY = nil
        floorTaps = []
        lastPassiveCameraPosition = nil
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
            // Refuse taps until tracking is reliable: a tap placed during
            // `.limited`/`.initializing` tracking lands on a drifting estimated
            // plane and produces the "dots don't connect" outline. CLAUDE.md:
            // never hide low confidence — explain the refusal instead.
            guard trackingQuality.isUsable else { rejectTapForTracking(); return }
            tapNeedsBetterTracking = false
            if isHighWallModeActive {
                handleHighWallTap(at: point, in: arView)
            } else if let hit = raycastFloor(from: point, in: arView) {
                recordFloorTap(hit)
                addCorner(at: hit.world)
            } else {
                flagRaycastFailure()
            }
        case .markingOpenings:
            guard trackingQuality.isUsable else { rejectTapForTracking(); return }
            tapNeedsBetterTracking = false
            // Openings can be tapped on the wall face or along the floor/base.
            // Try both explicitly, then snap the best hit to the captured wall
            // outline so ARKit's detected wall/floor plane drift does not shift
            // the saved door/window.
            if let rawPoint = raycastOpeningPoint(from: point, in: arView) {
                addOpeningPoint(rawPoint)
            } else {
                flagRaycastFailure()
            }
        case .review:
            break
        }
    }

    /// Ignore a placement tap that arrived while tracking wasn't reliable, and
    /// surface why (the dot would otherwise drift). Cleared on the next good tap.
    private func rejectTapForTracking() {
        tapNeedsBetterTracking = true
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
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
        // Prefer real detected geometry over the feature-point estimate. A pure
        // `.estimatedPlane` raycast (the old behaviour) drifts and never carries
        // an `ARPlaneAnchor`, so the floor-classified 1.0 weight almost never
        // fired and the floor barely locked. Try, in order:
        //   1. `.existingPlaneGeometry` — exact detected floor patch, most
        //      accurate, and carries the plane anchor for proper weighting.
        //   2. `.existingPlaneInfinite` — extends that plane so far corners
        //      beyond the resolved patch still land at the true floor height.
        //   3. `.estimatedPlane` — last-resort feature-point estimate (0.2).
        let targets: [ARRaycastQuery.Target] = [
            .existingPlaneGeometry,
            .existingPlaneInfinite,
            .estimatedPlane,
        ]
        let origin = cameraOrigin(in: arView)
        for target in targets {
            guard let result = arView.raycast(from: point, allowing: target, alignment: .horizontal).first else { continue }
            let w = result.worldTransform.columns.3
            let world = SIMD3(w.x, w.y, w.z)
            // Reject a grazing intersection on the infinitely-extended floor far
            // down the room (same warp-and-lag artifact as the high-wall path).
            if simd_distance(world, origin) > Self.maxTapReach { continue }
            if let baseline = sessionFloorY ?? floorY, abs(world.y - baseline) > 0.15 {
                continue
            }

            if let plane = result.anchor as? ARPlaneAnchor {
                let weight: Float = plane.classification == .floor ? 1.0 : 0.5
                return FloorRaycast(world: world, weight: weight, anchorID: plane.identifier, isPlaneAnchor: true)
            }
            // Estimated geometry — no plane anchor. A fresh UUID means the
            // unique-anchor dedup branch can never match for estimated taps; they
            // fall back to the 0.5 m spatial rule.
            return FloorRaycast(world: world, weight: 0.2, anchorID: UUID(), isPlaneAnchor: false)
        }
        return nil
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

        // Mutating @Published `corners` on the same tap drives the overlay
        // refresh that re-reads the derived `floorLocked`; floorTaps itself is
        // not published.
        objectWillChange.send()
        floorTaps.append((y: hit.world.y, weight: hit.weight, anchorID: hit.anchorID, position: posXZ))
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
        // The tap lands on the WALL, not the floor, so raycast against surfaces
        // of any alignment. A horizontal-only raycast (`raycastFloor`) can never
        // hit a vertical wall and was failing every high-wall tap with
        // "couldn't read that point".
        guard let wall = raycastAnySurface(from: screenPoint, in: arView) else {
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
        // X/Z from the wall tap, Y from the floor baseline — already snapped.
        // `addCorner` is the single writer of `floorY` (it falls back to this
        // baseline when there's no locked floor yet).
        addCorner(at: SIMD3(wall.x, baselineY, wall.z))
        isHighWallModeActive = false
    }
    /// Raycasts a high-wall tap to a point on the wall. A high-wall tap targets a
    /// *vertical* surface (the wall above a blocked floor corner), so we ask for
    /// vertical planes FIRST and only fall back to `.any` if none resolve. This
    /// matters: with `.any` alignment, `.existingPlaneInfinite` happily intersects
    /// the infinitely-extended FLOOR plane far down the room when you aim high at
    /// a distant wall, returning a point 20+ m away — the warp-and-lag bug.
    ///
    /// Within each alignment we try progressively more permissive targets:
    /// 1. `.existingPlaneInfinite` — extends a detected wall patch infinitely, so
    ///    a tap high on the wall (above the resolved extent) still hits.
    /// 2. `.existingPlaneGeometry` — exact detected extent (tighter when the tap
    ///    lands inside the patch).
    /// 3. `.estimatedPlane` — feature-point estimate for walls not yet promoted
    ///    to a plane anchor.
    ///
    /// For each target we keep the result CLOSEST to the camera and reject any
    /// hit beyond `maxTapReach` — a grazing intersection on an infinite plane.
    /// If everything misses or is implausibly far, we return nil and the caller
    /// surfaces "couldn't read that point" rather than inventing a far corner.
    private func raycastAnySurface(from point: CGPoint, in arView: ARView) -> SIMD3<Float>? {
        let targets: [ARRaycastQuery.Target] = [
            .existingPlaneInfinite,
            .existingPlaneGeometry,
            .estimatedPlane,
        ]
        let origin = cameraOrigin(in: arView)
        // Vertical first (we want the wall), then any-alignment as a fallback.
        for alignment in [ARRaycastQuery.TargetAlignment.vertical, .any] {
            for target in targets {
                let hits = arView.raycast(from: point, allowing: target, alignment: alignment)
                    .map { SIMD3($0.worldTransform.columns.3.x, $0.worldTransform.columns.3.y, $0.worldTransform.columns.3.z) }
                    .filter { simd_distance($0, origin) <= Self.maxTapReach }
                if let nearest = hits.min(by: { simd_distance($0, origin) < simd_distance($1, origin) }) {
                    return nearest
                }
            }
        }
        return nil
    }

    private func raycastOpeningPoint(from point: CGPoint, in arView: ARView) -> PlanePoint? {
        var candidates: [PlanePoint] = []
        candidates.append(contentsOf: raycastPlanePoints(from: point, in: arView, alignment: .vertical))
        candidates.append(contentsOf: raycastPlanePoints(from: point, in: arView, alignment: .horizontal))

        return candidates.min { lhs, rhs in
            openingProjectionDistance(for: lhs) < openingProjectionDistance(for: rhs)
        }
    }

    private func raycastPlanePoints(from point: CGPoint, in arView: ARView, alignment: ARRaycastQuery.TargetAlignment) -> [PlanePoint] {
        let targets: [ARRaycastQuery.Target] = [
            .existingPlaneGeometry,
            .existingPlaneInfinite,
            .estimatedPlane,
        ]
        return targets.compactMap { target in
            guard let world = arView.raycast(from: point, allowing: target, alignment: alignment).first?.worldTransform.columns.3 else {
                return nil
            }
            return PlanePoint(x: world.x, z: world.z)
        }
    }

    private func openingProjectionDistance(for point: PlanePoint) -> Float {
        guard let projection = projectedOpeningPoint(point, preferredWallIndex: pendingOpeningWallIndex) else {
            return Float.greatestFiniteMagnitude
        }
        return simd_distance(point.simd2, projection.point.simd2)
    }

    private func cameraY(in arView: ARView) -> Float {
        arView.session.currentFrame?.camera.transform.columns.3.y ?? 0
    }

    /// World-space camera position, used to reject implausibly far raycast hits.
    private func cameraOrigin(in arView: ARView) -> SIMD3<Float> {
        let c = arView.session.currentFrame?.camera.transform.columns.3 ?? SIMD4<Float>(repeating: 0)
        return SIMD3(c.x, c.y, c.z)
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
        guard Geometry2D.polygonArea(corners.map(\.simd2)) >= Self.minimumFloorArea else {
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

    /// Manual escape from the floor-finding step: if coaching never completes
    /// (a featureless room) but tracking is good, let the user start anyway so
    /// they're never trapped on the coaching screen.
    func beginMarkingManually() {
        guard step == .findingFloor else { return }
        step = .markingCorners
    }

    // MARK: - Ceiling estimation: passive collection (Part 2)

    /// Manual AR does not passively estimate ceiling height. Sparse feature
    /// points seen during corner capture vary too much scan-to-scan, so ceiling
    /// height comes only from the explicit one-time look-up step at the end.
    private func collectPassiveCeiling(_ frame: ARFrame) {
        // Intentionally empty.
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
        let threshold = floor + Self.ceilingFloorClearance
        // This runs on the main actor at scan close, so it must stay cheap: a
        // fully-meshed room can hold hundreds of thousands of vertices. We
        // stride large meshes down to a bounded sample and stop once we have
        // plenty of hits for a stable percentile.
        let maxHits = Self.maxCeilingCandidates
        sampling: for anchor in meshAnchors.values {
            let vertices = anchor.geometry.vertices
            let buffer = vertices.buffer.contents()
            let stride = max(1, vertices.count / 512)
            var i = 0
            while i < vertices.count {
                let ptr = buffer.advanced(by: vertices.offset + vertices.stride * i)
                // ARMeshGeometry packs vertices as three tightly-strided floats
                // (stride 12); read them individually rather than as a 16-byte
                // SIMD3 to avoid over-reading past the buffer.
                let local = ptr.assumingMemoryBound(to: (Float, Float, Float).self).pointee
                let world = anchor.transform * simd_make_float4(local.0, local.1, local.2, 1)
                if world.y >= threshold {
                    activeMeshHits.append(world.y)
                    if activeMeshHits.count >= maxHits { break sampling }
                }
                i += stride
            }
        }
    }

    // MARK: - Finish & ceiling resolution (Part 2)

    /// Begins the close sequence: run the one-time ceiling look-up, resolve the
    /// final ceiling height, then build the room.
    func finish() {
        // Guard against a double-tap of "Done": once we advance to `.review`
        // the close sequence (and its async look-up Task) is already running,
        // so a second call must not launch it again or emit a second room.
        guard corners.count >= 3, step != .review else { return }
        step = .review
        passiveCeilingHeight = nil

        Task { @MainActor in
            await runLookUp()
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

        if plausibleActiveCeilingHeights().count < Self.minimumActiveCeilingPoints {
            lookUpPrompt = "Keep pointing up…"
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        activeCeilingHeight = featurePointActiveHeight()

        isLookingUp = false
    }

    private func featurePointActiveHeight() -> Float? {
        let heights = plausibleActiveCeilingHeights().sorted()
        guard heights.count >= Self.minimumActiveCeilingPoints else { return nil }
        let median = heights[heights.count / 2]
        return Self.roundCeilingEstimate(median)
    }

    private func plausibleActiveCeilingHeights() -> [Float] {
        guard let floor = sessionFloorY else { return [] }
        return activeFeaturePoints.values.compactMap { y in
            let height = y - floor
            return Self.ceilingEstimateRange.contains(height) ? height : nil
        }
    }

    private static func roundCeilingEstimate(_ height: Float) -> Float {
        (height / ceilingEstimateStep).rounded() * ceilingEstimateStep
    }

    private func ceilingHeight(fromHits hits: [Float]) -> Float? {
        guard let floor = sessionFloorY, !hits.isEmpty else { return nil }
        return Self.percentile(hits.sorted(), 0.95) - floor
    }

    /// Strict priority resolution, then build and emit the `RoomModel`.
    /// 1. RoomPlan/future hand-off · 2. one-time look-up · 3. 2.5 m default.
    private func resolveCeilingAndComplete() {
        if let height = roomPlanCeilingHeight {
            resolvedCeilingHeight = height
            ceilingConfidence = .high
        } else if let height = activeCeilingHeight {
            resolvedCeilingHeight = height
            ceilingConfidence = .high
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

    private func addOpeningPoint(_ rawPoint: PlanePoint) {
        guard let projection = projectedOpeningPoint(rawPoint, preferredWallIndex: pendingOpeningWallIndex) else {
            flagRaycastFailure()
            return
        }

        lastRaycastFailed = false
        let point = projection.point
        if let start = pendingOpeningStart {
            openings.append(RoomOpening(kind: openingKind, start: start, end: point))
            pendingOpeningStart = nil
            pendingOpeningWallIndex = nil
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        } else {
            pendingOpeningStart = point
            pendingOpeningWallIndex = projection.wallIndex
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
    }

    private struct OpeningProjection {
        let point: PlanePoint
        let wallIndex: Int
    }

    private func projectedOpeningPoint(_ point: PlanePoint, preferredWallIndex: Int?) -> OpeningProjection? {
        guard corners.count >= 2 else { return nil }
        let pointVector = point.simd2

        if let preferredWallIndex, corners.indices.contains(preferredWallIndex) {
            return projection(of: pointVector, ontoWallAt: preferredWallIndex)
        }

        return corners.indices.compactMap { index in
            projection(of: pointVector, ontoWallAt: index)
        }
        .min { lhs, rhs in
            simd_distance(lhs.point.simd2, pointVector) < simd_distance(rhs.point.simd2, pointVector)
        }
    }

    private func projection(of point: SIMD2<Float>, ontoWallAt index: Int) -> OpeningProjection? {
        guard corners.indices.contains(index) else { return nil }
        let a = corners[index].simd2
        let b = corners[(index + 1) % corners.count].simd2
        let ab = b - a
        let lengthSquared = simd_length_squared(ab)
        guard lengthSquared > 0 else { return nil }

        let t = max(0, min(1, simd_dot(point - a, ab) / lengthSquared))
        return OpeningProjection(point: PlanePoint(a + t * ab), wallIndex: index)
    }

    func removeLastOpening() {
        if pendingOpeningStart != nil {
            pendingOpeningStart = nil
            pendingOpeningWallIndex = nil
        } else if !openings.isEmpty {
            openings.removeLast()
        }
    }

    // MARK: - Rendering

    private func placeCornerMarker(at position: SIMD3<Float>) {
        let sphere = ModelEntity(mesh: cornerMarkerMesh, materials: [cornerMarkerMaterial])
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
            materials: [edgeMaterial]
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
        // Delegate callbacks are pinned to the main queue (see `attach`), so the
        // @Published mutation is already on the main thread.
        trackingQuality = quality
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
