import SwiftUI
import RealityKit
import UIKit
import simd

/// The Phase 1 diorama: a `RoomModel` rendered in RealityKit as a cozy, stylized
/// "play mode" world, with an instant PLAY/BUY material toggle, orbit/zoom/pan
/// camera, and a soft grounding base.
///
/// The hard product rule lives here: **geometry is identical between modes.**
/// Switching PLAY↔BUY only swaps materials and lighting — never a vertex moves.
/// The cross-fade is done by snapshotting the current frame (offscreen, via
/// `OffscreenSnapshotRenderer`), swapping materials underneath, and fading the
/// snapshot out (< 400 ms).
///
/// ## Migrated to `RealityView`
/// This was a `UIViewRepresentable` wrapping a `.nonAR` `ARView`. It is now a native
/// SwiftUI `RealityView`. Three ARView conveniences had no direct `RealityView`
/// equivalent and moved:
/// - **Snapshot** (`ARView.snapshot`) → `OffscreenSnapshotRenderer` (RealityKit's
///   `RealityRenderer`), used for both the cross-fade freeze and the list thumbnail.
/// - **Image-based lighting** (`ARView.environment.lighting.resource`) → an
///   `ImageBasedLightComponent` on a dedicated entity plus an
///   `ImageBasedLightReceiverComponent` on the scene root (PLAY only).
/// - **Background colour** (`ARView.environment.background`) → a SwiftUI
///   `Color(palette.background)` layer behind the `RealityView` in
///   `RoomDioramaScreen`, which cross-fades natively with the mode change.
struct RoomSceneView: View {
    let room: RoomModel
    let mode: RoomRenderMode
    /// Incremented by the parent to request a spring camera reset.
    var resetToken: Int = 0
    /// Called once with PNG data after the first frames render, for the room's
    /// list thumbnail. Optional.
    var onThumbnail: ((Data) -> Void)? = nil
    /// When non-nil, the diorama is in furniture-EDITING mode: these footprints
    /// (not `room.detectedFurniture`) drive the furniture entities live via
    /// `syncFurniture`, tinted by `placementStates`. Nil = static viewing mode.
    var editableFurniture: [FurnitureFootprint]? = nil
    var placementStates: [UUID: PlacementState] = [:]
    /// The selected piece (drives highlight + which entity a drag/pinch targets).
    var selectedFurnitureID: UUID? = nil
    /// Called when a tap selects a furniture id (or nil for empty-space deselect).
    var onSelectFurniture: ((UUID?) -> Void)? = nil
    /// Called when a drag/pinch ends with the mutated footprints, for persistence.
    var onFurnitureChanged: (([FurnitureFootprint]) -> Void)? = nil

    /// The scene/camera/culling engine. Held in `@State` so the single instance
    /// survives `body` re-evaluations (mode toggle, reset) — `RealityView`'s `make`
    /// closure runs once against it; `update` drives it from external state.
    @State private var controller = RoomSceneController()

    /// The current cross-fade freeze frame, produced offscreen on a mode change and
    /// faded out by `crossfadeOverlay`. Nil when no fade is in flight.
    @State private var crossfadeImage: UIImage?
    @State private var fadeOpacity: Double = 0
    /// Bumped per fade so a finished fade's completion can't clear a freeze a newer
    /// toggle already replaced it with.
    @State private var crossfadeToken = 0

    @Environment(\.displayScale) private var displayScale

    var body: some View {
        GeometryReader { geo in
            RealityView { content in
                controller.makeEntities(room: room, mode: mode, editingFurniture: editableFurniture != nil, onThumbnail: onThumbnail)
                content.add(controller.root)
                content.add(controller.cameraAnchor)
                // Per-frame loop: reset spring, dollhouse wall culling, one-time
                // thumbnail. Retained on the controller so it isn't cancelled the
                // instant `make` returns; `[weak controller]` avoids a retain cycle.
                // `SceneEvents.Update` fires on the main thread; `assumeIsolated`
                // bridges the non-isolated handler to the controller's main-actor
                // methods (and crashes loudly if that ever stops being true).
                controller.updateSub = content.subscribe(to: SceneEvents.Update.self) { [weak controller] event in
                    MainActor.assumeIsolated {
                        controller?.onSceneUpdate(deltaTime: event.deltaTime)
                    }
                }
            } update: { _ in
                controller.applyExternalState(mode: mode, resetToken: resetToken)
                if let editableFurniture {
                    controller.syncFurniture(editableFurniture, states: placementStates, selectedID: selectedFurnitureID)
                }
            }
            .overlay { gestureLayer }
            .overlay { crossfadeOverlay }
            .onChange(of: crossfadeImage) { _, image in startCrossfade(image) }
            .onChange(of: geo.size) { syncPixelSize(geo.size) }
            .onChange(of: displayScale) { syncPixelSize(geo.size) }
            .onAppear {
                // Snap the freeze to full opacity in the SAME state mutation that
                // introduces the image, so the overlay's first committed frame is
                // already opaque. If opacity stayed at 0 until `.onChange` →
                // `startCrossfade` ran, SwiftUI could commit one frame of the
                // just-swapped materials showing through the transparent overlay —
                // the inverse of the intended freeze. `startCrossfade` still drives
                // the fade-OUT.
                controller.crossfade = { image in
                    if image != nil { fadeOpacity = 1 }
                    crossfadeImage = image
                }
                syncPixelSize(geo.size)
            }
        }
    }

    private func syncPixelSize(_ size: CGSize) {
        controller.pixelSize = CGSize(width: size.width * displayScale,
                                      height: size.height * displayScale)
    }

    // MARK: - Overlays

    private var gestureLayer: some View {
        SceneGestureOverlay(
            controller: controller,
            onSelectFurniture: onSelectFurniture,
            onFurnitureChanged: onFurnitureChanged
        )
    }

    /// The cross-fade freeze: shown instantly at full opacity (covering the material
    /// swap), then animated out over 350 ms by `startCrossfade`. Inserted with no
    /// transition so it does not fade *in*.
    @ViewBuilder private var crossfadeOverlay: some View {
        if let image = crossfadeImage {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .opacity(fadeOpacity)
                .allowsHitTesting(false)
                .ignoresSafeArea()
        }
    }

    /// Drive the freeze-frame out. Snaps to full opacity (covering the just-swapped
    /// materials), then animates to clear and drops the image. Triggered by every
    /// change to `crossfadeImage`, so a rapid re-toggle restarts the fade cleanly.
    private func startCrossfade(_ image: UIImage?) {
        guard image != nil else { return }
        crossfadeToken += 1
        let token = crossfadeToken
        fadeOpacity = 1
        withAnimation(.easeOut(duration: 0.35)) {
            fadeOpacity = 0
        } completion: {
            if crossfadeToken == token { crossfadeImage = nil }
        }
    }
}

/// A transparent UIKit layer over the `RealityView` that hosts the three camera
/// gesture recognizers. SwiftUI has no clean way to distinguish a one-finger drag
/// (orbit) from a two-finger drag (pan), so the recognizers — which coordinate on
/// touch count exactly as they did on the old `ARView` — stay in UIKit and feed the
/// controller's camera intents. `RealityView` needs no touches of its own here.
private struct SceneGestureOverlay: UIViewRepresentable {
    let controller: RoomSceneController
    /// Tap selection callback (nil = deselect).
    var onSelectFurniture: ((UUID?) -> Void)? = nil
    /// Called with the mutated footprints when a furniture drag/pinch ends.
    var onFurnitureChanged: (([FurnitureFootprint]) -> Void)? = nil

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        context.coordinator.controller = controller
        context.coordinator.onSelectFurniture = onSelectFurniture
        context.coordinator.onFurnitureChanged = onFurnitureChanged

        let orbit = UIPanGestureRecognizer(target: context.coordinator,
                                            action: #selector(Coordinator.handleOrbit(_:)))
        orbit.maximumNumberOfTouches = 1
        view.addGestureRecognizer(orbit)

        let pan = UIPanGestureRecognizer(target: context.coordinator,
                                         action: #selector(Coordinator.handlePan(_:)))
        pan.minimumNumberOfTouches = 2
        pan.maximumNumberOfTouches = 2
        view.addGestureRecognizer(pan)

        let pinch = UIPinchGestureRecognizer(target: context.coordinator,
                                             action: #selector(Coordinator.handlePinch(_:)))
        view.addGestureRecognizer(pinch)

        // Tap selects/deselects furniture. Coexists with the pan recognizers (a
        // tap is a discrete touch; pans require movement).
        let tap = UITapGestureRecognizer(target: context.coordinator,
                                         action: #selector(Coordinator.handleTap(_:)))
        view.addGestureRecognizer(tap)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.controller = controller
        context.coordinator.onSelectFurniture = onSelectFurniture
        context.coordinator.onFurnitureChanged = onFurnitureChanged
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// `@MainActor` so the `@objc` recognizer callbacks (which UIKit always delivers
    /// on the main thread) can call the controller's main-actor camera intents.
    @MainActor
    final class Coordinator: NSObject {
        weak var controller: RoomSceneController?
        var onSelectFurniture: ((UUID?) -> Void)?
        var onFurnitureChanged: (([FurnitureFootprint]) -> Void)?

        /// What the in-flight single-finger drag is doing, decided at `.began`.
        private enum DragMode { case orbit, moveFurniture, consumed }
        private var dragMode: DragMode = .orbit

        @objc func handleOrbit(_ gesture: UIPanGestureRecognizer) {
            guard let controller, let view = gesture.view else { return }
            switch gesture.state {
            case .began:
                dragMode = decideDragMode(start: gesture.location(in: view), view: view, controller: controller)
            case .changed:
                switch dragMode {
                case .moveFurniture:
                    controller.dragFurniture(toScreenPoint: gesture.location(in: view), viewSize: view.bounds.size)
                case .orbit:
                    let t = gesture.translation(in: view)
                    controller.orbit(dx: Float(t.x), dy: Float(t.y))
                    gesture.setTranslation(.zero, in: view)
                case .consumed:
                    break   // the drag only selected a piece; don't move or orbit
                }
            case .ended, .cancelled, .failed:
                if dragMode == .moveFurniture {
                    onFurnitureChanged?(controller.endFurnitureDrag())
                }
                dragMode = .orbit
            default:
                break
            }
        }

        /// Decide whether a single-finger drag moves furniture, orbits, or just
        /// selects. Skips the hit-test entirely when there's no furniture.
        private func decideDragMode(start: CGPoint, view: UIView, controller: RoomSceneController) -> DragMode {
            guard controller.hasFurniture else { return .orbit }
            guard let id = controller.furnitureID(atScreenPoint: start, viewSize: view.bounds.size) else {
                return .orbit   // empty space → camera
            }
            if id == controller.selectedFurnitureID {
                controller.beginFurnitureDrag(id, atScreenPoint: start, viewSize: view.bounds.size)
                return .moveFurniture
            }
            // Dragging an UNselected piece selects it but doesn't move it (a second
            // drag, now that it's selected, moves it).
            onSelectFurniture?(id)
            return .consumed
        }

        @objc func handlePan(_ gesture: UIPanGestureRecognizer) {
            guard let view = gesture.view else { return }
            let t = gesture.translation(in: view)
            controller?.pan(dx: Float(t.x), dy: Float(t.y))
            gesture.setTranslation(.zero, in: view)
        }

        /// What the in-flight pinch is doing, decided at `.began`.
        private enum PinchMode { case zoom, resizeFurniture }
        private var pinchMode: PinchMode = .zoom

        @objc func handlePinch(_ gesture: UIPinchGestureRecognizer) {
            guard let controller, let view = gesture.view else { return }
            switch gesture.state {
            case .began:
                // Pinch centered on the selected entity resizes it; otherwise zoom.
                if controller.hasFurniture,
                   let id = controller.furnitureID(atScreenPoint: gesture.location(in: view), viewSize: view.bounds.size),
                   id == controller.selectedFurnitureID {
                    controller.beginFurnitureResize(id)
                    pinchMode = .resizeFurniture
                } else {
                    pinchMode = .zoom
                }
            case .changed:
                switch pinchMode {
                case .resizeFurniture:
                    // Cumulative scale since gesture start — do NOT reset to 1.
                    controller.resizeFurniture(scale: Float(gesture.scale))
                case .zoom:
                    controller.pinch(scale: Float(gesture.scale))
                    gesture.scale = 1
                }
            case .ended, .cancelled, .failed:
                if pinchMode == .resizeFurniture {
                    onFurnitureChanged?(controller.endFurnitureResize())
                }
                pinchMode = .zoom
            default:
                break
            }
        }

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let controller, let view = gesture.view else { return }
            // Skip all hit-testing when there's no furniture to hit.
            guard controller.hasFurniture else { return }
            let point = gesture.location(in: view)
            let id = controller.furnitureID(atScreenPoint: point, viewSize: view.bounds.size)
            onSelectFurniture?(id)
        }
    }
}

/// Owns the RealityKit scene, camera rig, gesture math, per-mode materials,
/// dollhouse wall culling, the cross-fade, and the thumbnail snapshot for one
/// `RoomSceneView`. A plain reference type driven by the SwiftUI view; not
/// `@Observable` — the only thing the view observes is the cross-fade image, which
/// the controller pushes through the `crossfade` callback.
@MainActor
final class RoomSceneController {

    // MARK: Scene
    /// Scene root; added to `RealityViewContent` by the view. Holds geometry, lights,
    /// and the image-based-light source/receiver.
    let root = AnchorEntity(world: .zero)
    /// Camera root; added to content separately so root transforms can never bleed
    /// into the camera pose.
    let cameraAnchor = AnchorEntity(world: .zero)
    private let camera = Entity()
    private let keyLight = DirectionalLight()
    private let fillA = DirectionalLight()
    private let fillB = DirectionalLight()
    /// The entity carrying the PLAY image-based light. The scene root receives from
    /// it (PLAY only) via `ImageBasedLightReceiverComponent`. Named so the offscreen
    /// snapshot can re-point its clone's receiver at the cloned source.
    private let iblEntity = Entity()
    static let iblEntityName = "snug_ibl_source"
    /// The warm studio environment for PLAY image-based lighting. Built asynchronously
    /// (GPU work) after the scene attaches; nil until ready and in BUY, where lighting
    /// stays neutral.
    private var environment: EnvironmentResource?

    private var floorEntity: ModelEntity?
    /// The floor's chunky outline under-sheet (PLAY only).
    private var floorOutline: ModelEntity?
    private var baseEntity: ModelEntity?
    /// Soft drop shadow grounding the floating room cube against the solid void
    /// backdrop (PLAY only). A baked contact-shadow plane tucked under the base.
    private var dropShadow: ModelEntity?

    /// One wall edge and all of its PLAY-mode companions that must hide together
    /// when the wall is culled (the open-dollhouse look): the inverted-hull
    /// `outline`, the chunky white `cap` rim, and the emissive `cornice` strip.
    /// `midXZ`/`outwardXZ` drive culling. The companions cull with `entity`.
    private struct WallNode {
        let entity: ModelEntity
        let outline: ModelEntity?
        let cap: ModelEntity?
        let cornice: ModelEntity?
        let midXZ: SIMD2<Float>
        let outwardXZ: SIMD2<Float>
    }
    private var walls: [WallNode] = []
    /// Styled openings: a container holding a trim frame + an inner pane (glass /
    /// door panel / blown-out void) + mullions/rails. `entity` is the container
    /// (toggled by culling); `pane` is the palette-driven inner surface; `trims`
    /// are the frame/mullion bars, also palette-driven so they go neutral in BUY;
    /// `wallIndex` ties it to its wall so culling stays in sync; `kind` selects the
    /// PLAY pane material (windows/openings become white voids, doors stay paneled).
    private var openings: [(entity: Entity, pane: ModelEntity, trims: [ModelEntity], wallIndex: Int, kind: RoomOpening.Kind)] = []
    /// BUY-mode dimension labels (lie flat on the floor like a blueprint).
    private var labels: [ModelEntity] = []

    // MARK: Phase 2 furniture (separate keyed store — never mixed into the
    // wall/floor/opening scene building, so the PLAY/BUY geometry invariant is
    // untouched). In editing mode these are driven live by the placement tray via
    // `syncFurniture`; in viewing mode `buildGeometry` adds them once, statically.
    private var furnitureEntities: [UUID: Entity] = [:]
    /// Last-synced footprint per id, so `syncFurniture` only rebuilds an entity
    /// when its geometry actually changed (cheap re-tints otherwise).
    private var furnitureSnapshots: [UUID: FurnitureFootprint] = [:]
    /// When true, `buildGeometry` skips the static furniture pass — the tray owns
    /// furniture entities through `syncFurniture`.
    private var editingFurniture = false
    /// Last-synced footprints (non-cleared), kept so the UIKit gesture overlay can
    /// hit-test a screen tap against the floor rectangles without a SwiftUI round-trip.
    private(set) var currentFootprints: [FurnitureFootprint] = []
    /// The currently selected piece (drives the Clay highlight + gesture gating).
    /// Readable by the gesture overlay to decide move-vs-select on drag start.
    private(set) var selectedFurnitureID: UUID?
    /// The room being edited — stored so live drag/pinch can validate without a
    /// SwiftUI round-trip. Set in `makeEntities`.
    private var editingRoom: RoomModel?
    /// The piece a single-finger drag is currently moving (nil when not dragging).
    private var draggingFurnitureID: UUID?
    /// Previous placement state during a drag, so the "became invalid" warning
    /// haptic fires once on transition rather than every move.
    private var lastDragState: PlacementState?

    /// Whether any furniture exists — the overlay skips all hit-testing when false.
    var hasFurniture: Bool { !currentFootprints.isEmpty }

    // MARK: Camera state

    /// Calibration for the orthographic view-volume. The diorama uses a TRUE
    /// orthographic camera (`OrthographicCameraComponent`), so parallel lines stay
    /// parallel by projection, not by faking a narrow FOV. This constant is no
    /// longer a real field of view: it sets how far the camera sits (`radius`, for
    /// orbit + clipping) and, through the same value, calibrates `orthoScale(forRadius:)`
    /// so the framing matches the values the team already tuned. Smaller = camera
    /// sits farther back; apparent size is governed by the ortho scale. Both modes.
    static let isoFOVDegrees: Float = 14
    /// True isometric viewing angle above the horizon: `atan(1/√2) ≈ 35.26°`.
    /// Paired with a 45° azimuth this is the canonical diorama orientation.
    static let isoElevation: Float = atan(1 / Float(2).squareRoot())

    private var target = SIMD3<Float>.zero
    private var azimuth: Float = .pi / 4          // 45° — canonical diorama azimuth
    private var elevation: Float = RoomSceneController.isoElevation
    private var radius: Float = 5
    private var radiusRange: ClosedRange<Float> = 1...20
    private var centroidXZ = SIMD2<Float>.zero

    private var defaultAzimuth: Float = .pi / 4
    private var defaultElevation: Float = .pi / 5
    private var defaultRadius: Float = 5
    private var defaultTarget = SIMD3<Float>.zero

    /// In-flight spring reset animation, advanced by the scene update loop.
    private struct CameraAnim {
        var elapsed: TimeInterval = 0
        let duration: TimeInterval
        let fromAz, toAz, fromEl, toEl, fromR, toR: Float
        let fromTarget, toTarget: SIMD3<Float>
    }
    private var cameraAnim: CameraAnim?

    // MARK: Misc
    private(set) var mode: RoomRenderMode = .play
    /// Whether PLAY-mode outlines are currently shown; read by `cullWalls` so a
    /// culled wall's outline hides with it.
    private var showsOutlines = true
    /// Whether PLAY-mode wall caps / cornice strips are shown; read by `cullWalls`
    /// so a culled wall's cap and glow strip hide with it.
    private var showsWallCaps = true
    private var showsCornice = true

    /// TEMPORARY: drop preview furniture into the diorama so the Phase-3 look can
    /// be eyeballed on device. This is NOT real placement — flip to `false` (or
    /// delete this flag, `placeDemoFurniture`, and its call) before shipping.
    /// The preview pieces are not mode-aware: they keep their PLAY styling in BUY.
    static let demoFurniture = false
    /// Bumped on every `setMode`; a snapshot callback applies its frame only if it's
    /// still the latest generation, so rapid toggles can't flash a stale one.
    private var modeGeneration = 0
    var lastResetToken = 0
    var onThumbnail: ((Data) -> Void)?
    private var didSnapshot = false
    private var frameCount = 0
    /// Retained per-frame subscription (set by the view from `RealityViewContent`).
    var updateSub: EventSubscription?
    /// Pushes a cross-fade freeze frame up to the SwiftUI view. Set by the view.
    var crossfade: ((UIImage?) -> Void)?
    /// The view's drawable size in PIXELS (points × display scale), kept current by
    /// the view; the offscreen snapshot renders at this resolution.
    var pixelSize: CGSize = .zero

    // MARK: - Setup

    /// Build all scene entities (geometry, lights, camera). The view adds `root` and
    /// `cameraAnchor` to its `RealityViewContent` and wires the per-frame loop.
    func makeEntities(room: RoomModel, mode: RoomRenderMode, editingFurniture: Bool = false, onThumbnail: ((Data) -> Void)?) {
        self.mode = mode
        self.editingFurniture = editingFurniture
        self.editingRoom = room
        self.onThumbnail = onThumbnail

        buildLights()
        root.addChild(keyLight)
        root.addChild(fillA)
        root.addChild(fillB)
        iblEntity.name = Self.iblEntityName
        root.addChild(iblEntity)
        buildGeometry(room: room)

        // True orthographic projection — the canonical isometric-diorama camera. The
        // ortho `scale` (view-volume height) is set every frame in `updateCamera`,
        // derived from `radius`, so the existing orbit / pinch-zoom / reset machinery
        // keeps driving a single value and needs no other change.
        camera.components.set(OrthographicCameraComponent())
        cameraAnchor.addChild(camera)

        frameCamera(room: room)
        applyPalette(for: mode)
        updateCamera()
        loadEnvironment()
    }

    private func buildLights() {
        // Warm key from top-right, cooler fill from the left, warm back fill. The
        // soft ambient wrap comes from image-based lighting (`StudioEnvironment`);
        // RealityKit has no dedicated ambient-light entity (still true on iOS 26),
        // so this back/fill pair supplements the IBL and stands in for it on the
        // first frames before the async environment loads. Directional lights use
        // only their direction, so aiming at the origin is correct even when the
        // room isn't centered there. Tints/intensities are set per mode in
        // `applyPalette`.
        keyLight.look(at: .zero, from: [2.5, 4.0, 2.5], relativeTo: nil)
        fillA.look(at: .zero, from: [-3.0, 2.0, -1.0], relativeTo: nil)
        fillB.look(at: .zero, from: [0.4, 1.4, -2.2], relativeTo: nil)
    }

    // MARK: - Geometry (mode-independent)

    private func buildGeometry(room: RoomModel) {
        let corners = room.floorCorners.map(\.simd2)
        guard corners.count >= 3 else { return }
        centroidXZ = corners.reduce(.zero, +) / Float(corners.count)
        let height = room.ceilingHeight

        // Grounding base: a chunky rounded platform under the room so the diorama
        // reads as a solid floating model. Its soft drop shadow (PLAY) lands on the
        // void backdrop just below it; real per-item contact shadows arrive with
        // furniture in Phase 3.
        if let base = makeBase(corners: corners) {
            baseEntity = base
            root.addChild(base)
        }
        if let shadow = makeDropShadow(corners: corners) {
            dropShadow = shadow
            root.addChild(shadow)
        }

        // Floor: a thin double-sided sheet triangulated from the polygon, so any
        // room shape (rectangle, L, …) renders correctly from above regardless
        // of back-face culling.
        if let floorMesh = Self.floorMesh(corners: corners) {
            let floor = ModelEntity(mesh: floorMesh, materials: [placeholderMaterial()])
            floorEntity = floor
            root.addChild(floor)
            // Floor outline: a slightly larger dark sheet tucked just below, so
            // its border reads as a chunky rim (culling-independent).
            if let outline = OutlineEntity.floorShell(corners: corners, pivot: centroidXZ,
                                                      y: -0.004, color: outlineColor) {
                floorOutline = outline
                root.addChild(outline)
            }
        }

        // Walls: chunky full-height slabs, one per polygon edge, each topped by a
        // white cap rim and lined with a warm emissive cornice strip (PLAY).
        let wallDepth: Float = 0.08   // thicker than a sheet → reads as a model slab
        let capHeight: Float = 0.06
        for wall in room.walls {
            let a = wall.start.simd2, b = wall.end.simd2
            let mid = (a + b) / 2
            let dir = b - a
            let length = simd_length(dir)
            guard length > 0.01 else { continue }
            let yaw = atan2(-dir.y, dir.x)
            let orientation = simd_quatf(angle: yaw, axis: [0, 1, 0])

            // Outward XZ normal (away from the room centroid) — needed now so the
            // cornice can be nudged onto the *inner* face.
            var outward = SIMD2<Float>(dir.y, -dir.x)
            if simd_dot(outward, mid - centroidXZ) < 0 { outward = -outward }
            outward = simd_normalize(outward)

            let mesh = MeshResource.generateBox(width: length, height: height, depth: wallDepth)
            let entity = ModelEntity(mesh: mesh, materials: [placeholderMaterial()])
            entity.position = SIMD3(mid.x, height / 2, mid.y)
            entity.orientation = orientation
            root.addChild(entity)

            // Inverted-hull outline sibling, matching the wall's transform.
            let outline = OutlineEntity.boxShell(size: [length, height, wallDepth], color: outlineColor)
            if let outline {
                outline.position = entity.position
                outline.orientation = orientation
                root.addChild(outline)
            }

            // Chunky white cap rim, proud of the wall on every edge so the slab
            // reads as a molded model piece. Material set in `applyPalette`.
            let capMesh = MeshResource.generateBox(size: [length + 0.04, capHeight, wallDepth + 0.05],
                                                   cornerRadius: 0.02)
            let cap = ModelEntity(mesh: capMesh, materials: [placeholderMaterial()])
            cap.position = SIMD3(mid.x, height + capHeight / 2 - 0.005, mid.y)
            cap.orientation = orientation
            root.addChild(cap)

            // Warm emissive cornice strip tucked just inside the top inner edge —
            // the hidden light-cove glow. Material set in `applyPalette`.
            let corniceMesh = MeshResource.generateBox(size: [length * 0.94, 0.03, 0.03], cornerRadius: 0.012)
            let cornice = ModelEntity(mesh: corniceMesh, materials: [placeholderMaterial()])
            let innerNudge = -outward * (wallDepth / 2 + 0.02)
            cornice.position = SIMD3(mid.x + innerNudge.x, height - 0.05, mid.y + innerNudge.y)
            cornice.orientation = orientation
            root.addChild(cornice)

            walls.append(WallNode(entity: entity, outline: outline, cap: cap,
                                  cornice: cornice, midXZ: mid, outwardXZ: outward))
        }

        // Openings: proud panels on the inner face of their nearest wall.
        for opening in room.openings {
            guard let panel = makeOpening(opening, walls: room.walls, ceiling: height) else { continue }
            root.addChild(panel.entity)
            openings.append((panel.entity, panel.pane, panel.trims, panel.wallIndex, opening.kind))
        }

        // Dimension labels (shown only in BUY): wall length, laid flat near each
        // wall's midpoint like a floor-plan annotation.
        for wall in room.walls {
            guard let label = makeDimensionLabel(for: wall) else { continue }
            label.isEnabled = false
            labels.append(label)
            root.addChild(label)
        }

        // Phase 2: detected existing furniture, rendered as stylized identity
        // boxes (collision + tap-target tagged) so it appears in the diorama. Y is
        // floor-relative (the box center is half its height above this y=0 floor),
        // so it sits ON the floor regardless of the AR session's altitude. In
        // editing mode this static pass is skipped — `syncFurniture` (driven by the
        // placement tray) owns the entities so they can update live.
        if !editingFurniture {
            for footprint in room.detectedFurniture where !footprint.isCleared {
                root.addChild(FurnitureEntityBuilder.entity(for: footprint))
            }
        }

        // TEMPORARY furniture preview — only when there's no real detected
        // furniture, so detection testing isn't cluttered by the demo cluster.
        // Delete with `placeDemoFurniture`.
        if Self.demoFurniture && room.detectedFurniture.isEmpty { placeDemoFurniture(at: centroidXZ) }
    }

    /// TEMPORARY visual preview of the Phase-3 furniture — NOT real placement.
    /// Drops a compact living-room cluster at the room center so the stylized
    /// materials, outlines, and contact shadows can be judged on device across
    /// box, cylinder, and sphere forms. Offsets are modest (~2.4 × 1.6 m) to fit
    /// most rooms; in a very small room some pieces may clip the walls. Delete
    /// this method and the `demoFurniture` flag when catalog placement lands.
    private func placeDemoFurniture(at center: SIMD2<Float>) {
        let origin = SIMD3<Float>(center.x, 0, center.y)
        func add(_ kind: PlayModeFurniture.Kind, dx: Float, dz: Float, yaw: Float = 0) {
            let piece = PlayModeFurniture.make(kind)
            piece.position = origin + SIMD3(dx, 0, dz)
            if yaw != 0 { piece.orientation = simd_quatf(angle: yaw, axis: [0, 1, 0]) }
            root.addChild(piece)
        }
        // Cozy reference-style arrangement with real negative space: sofa centered
        // on the back wall, an angled armchair in a front corner, table on the rug,
        // plant + lamp flanking the sofa in the back corners. Offsets are kept
        // within ~±1.15 m so they don't clip the walls of a ~3 m room; a very small
        // or non-square room may still need the (forthcoming) real placement system.
        add(.rug,         dx: 0,     dz: 0.05)
        add(.sofa,        dx: 0,     dz: -0.85)
        add(.coffeeTable, dx: 0,     dz: 0.0)
        add(.armchair,    dx: -0.95, dz: 0.7,  yaw: .pi / 5)
        add(.plantTall,   dx: 1.1,   dz: -0.85)
        add(.floorLamp,   dx: -1.1,  dz: -0.85)
    }

    /// A thin, double-sided floor sheet. Two triangle sets at ±epsilon Y with
    /// opposite normals guarantee a correctly-lit floor from above no matter how
    /// RealityKit culls faces (it can't be wound "wrong").
    private static func floorMesh(corners: [SIMD2<Float>]) -> MeshResource? {
        let tris = PolygonTriangulator.triangulate(corners)
        guard !tris.isEmpty else { return nil }
        let n = corners.count
        let eps: Float = 0.003

        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        positions.reserveCapacity(n * 2)
        normals.reserveCapacity(n * 2)
        for c in corners { positions.append(SIMD3(c.x, eps, c.y)); normals.append(SIMD3(0, 1, 0)) }   // top
        for c in corners { positions.append(SIMD3(c.x, -eps, c.y)); normals.append(SIMD3(0, -1, 0)) } // bottom

        var indices = tris
        let nn = UInt32(n)
        for t in stride(from: 0, to: tris.count, by: 3) {
            // Bottom copy: same triangle, reversed winding, offset to lower ring.
            indices.append(contentsOf: [tris[t] + nn, tris[t + 2] + nn, tris[t + 1] + nn])
        }

        var d = MeshDescriptor(name: "floor")
        d.positions = MeshBuffers.Positions(positions)
        d.normals = MeshBuffers.Normals(normals)
        d.primitives = .triangles(indices)
        return try? MeshResource.generate(from: [d])
    }

    private func makeBase(corners: [SIMD2<Float>]) -> ModelEntity? {
        let xs = corners.map(\.x), zs = corners.map(\.y)
        guard let minX = xs.min(), let maxX = xs.max(),
              let minZ = zs.min(), let maxZ = zs.max() else { return nil }
        let margin: Float = 0.5
        let w = (maxX - minX) + margin * 2
        let dz = (maxZ - minZ) + margin * 2
        // A deep, rounded platform — the chunky base of the floating model. Its top
        // sits at floor level (y == 0); it extrudes downward.
        let baseHeight: Float = 0.14
        let mesh = MeshResource.generateBox(size: [w, baseHeight, dz], cornerRadius: 0.10)
        let entity = ModelEntity(mesh: mesh, materials: [placeholderMaterial()])
        entity.position = SIMD3((minX + maxX) / 2, -baseHeight / 2, (minZ + maxZ) / 2)
        return entity
    }

    /// A soft baked drop shadow grounding the floating cube on the void backdrop
    /// (PLAY only). A horizontal contact-shadow plane, larger than the base and
    /// tucked just beneath it, so from the isometric angle it reads as a soft blob
    /// under the model rather than a hard cast shadow.
    private func makeDropShadow(corners: [SIMD2<Float>]) -> ModelEntity? {
        let xs = corners.map(\.x), zs = corners.map(\.y)
        guard let minX = xs.min(), let maxX = xs.max(),
              let minZ = zs.min(), let maxZ = zs.max() else { return nil }
        let margin: Float = 0.5
        let w = (maxX - minX) + margin * 2
        let dz = (maxZ - minZ) + margin * 2
        guard let shadow = ContactShadow.plane(footprint: [w * 1.5, dz * 1.5]) else { return nil }
        shadow.position = SIMD3((minX + maxX) / 2, -0.155, (minZ + maxZ) / 2)
        return shadow
    }

    private func makeOpening(_ opening: RoomOpening, walls roomWalls: [WallSegment], ceiling: Float) -> (entity: Entity, pane: ModelEntity, trims: [ModelEntity], wallIndex: Int)? {
        let a = opening.start.simd2, b = opening.end.simd2
        let mid = (a + b) / 2
        let dir = b - a
        let width = simd_length(dir)
        guard width > 0.05 else { return nil }
        let yaw = atan2(-dir.y, dir.x)

        // Vertical extent by kind (heights are often unknown on manual AR).
        let (sill, panelHeight): (Float, Float)
        switch opening.kind {
        case .door:
            sill = 0
            panelHeight = min(opening.height ?? 2.05, ceiling * 0.95)
        case .window:
            let h = min(opening.height ?? 1.1, ceiling * 0.7)
            sill = 0.9
            panelHeight = h
        case .opening:
            sill = 0
            panelHeight = ceiling * 0.98
        }

        // Tie to the nearest wall (true point-to-segment distance) so culling
        // hides the panel together with its wall.
        var wallIndex = 0
        var bestDist = Float.greatestFiniteMagnitude
        for (i, wall) in roomWalls.enumerated() {
            let dist = Geometry2D.distance(from: mid, toSegment: wall.start.simd2, wall.end.simd2)
            if dist < bestDist { bestDist = dist; wallIndex = i }
        }

        // Build the styled unit (frame + pane + dividers), then place + orient the
        // whole container, sitting proud on the inner face (nudged into the room).
        let (container, pane, trims) = Self.buildOpening(kind: opening.kind, width: width, height: panelHeight)
        let inward = walls.indices.contains(wallIndex) ? -walls[wallIndex].outwardXZ : SIMD2<Float>(0, 0)
        let offset = inward * 0.05
        container.position = SIMD3(mid.x + offset.x, sill + panelHeight / 2, mid.y + offset.y)
        container.orientation = simd_quatf(angle: yaw, axis: [0, 1, 0])
        return (container, pane, trims, wallIndex)
    }

    /// Builds a styled opening in local space so a captured door/window reads as
    /// one rather than a flat colored slab: a warm trim frame around the perimeter,
    /// a recessed inner pane (returned so the palette can drive it — pale glass in
    /// PLAY, neutral in BUY), and kind-specific dividers (a cross mullion for
    /// windows, two rails for a paneled door). Local axes: x along the wall, y up,
    /// z = wall thickness; the frame stands proud of both faces so it reads from
    /// inside the open-top dollhouse regardless of which face points inward.
    private static func buildOpening(kind: RoomOpening.Kind, width: Float, height: Float)
        -> (container: Entity, pane: ModelEntity, trims: [ModelEntity]) {
        let container = Entity()
        container.name = "opening_\(kind.rawValue)"

        // Adaptive trim width so a small opening isn't all-frame.
        let frameW = min(0.08, width * 0.18, height * 0.18)
        let frameD: Float = 0.09   // proud of the 0.06-deep wall box, both faces
        let barD: Float = 0.05     // dividers sit just behind the frame face

        // Frame bars carry a placeholder material; `applyPalette` re-materialises
        // them per mode (warm trim in PLAY, neutral in BUY) via the returned list,
        // so the frames never keep PLAY-warm color in the true-color BUY view.
        var trims: [ModelEntity] = []
        func bar(_ size: SIMD3<Float>, at p: SIMD3<Float>) {
            let e = ModelEntity(mesh: .generateBox(size: size, cornerRadius: 0.015),
                                materials: [SimpleMaterial(color: .gray, isMetallic: false)])
            e.position = p
            container.addChild(e)
            trims.append(e)
        }

        // Recessed inner pane (palette-driven; placeholder material until applied).
        let paneW = max(width - frameW * 2, 0.04)
        let paneH = max(height - frameW * 2, 0.04)
        let pane = ModelEntity(mesh: .generateBox(size: [paneW, paneH, 0.03], cornerRadius: 0.01),
                               materials: [SimpleMaterial(color: .gray, isMetallic: false)])
        container.addChild(pane)

        // Perimeter frame.
        let halfH = (height - frameW) / 2
        let halfW = (width - frameW) / 2
        bar([width, frameW, frameD], at: [0,  halfH, 0])    // top
        bar([width, frameW, frameD], at: [0, -halfH, 0])    // bottom
        bar([frameW, height, frameD], at: [-halfW, 0, 0])   // left
        bar([frameW, height, frameD], at: [ halfW, 0, 0])   // right

        // Kind-specific dividers (full barD depth → visible from the interior).
        let divider = frameW * 0.5
        switch kind {
        case .window:
            bar([divider, paneH, barD], at: [0, 0, 0])      // vertical mullion
            bar([paneW, divider, barD], at: [0, 0, 0])      // horizontal mullion
        case .door:
            bar([paneW, divider, barD], at: [0,  paneH * 0.18, 0])   // upper rail
            bar([paneW, divider, barD], at: [0, -paneH * 0.18, 0])   // lower rail
        case .opening:
            break   // archway: frame only
        }

        return (container, pane, trims)
    }

    private func makeDimensionLabel(for wall: WallSegment) -> ModelEntity? {
        let a = wall.start.simd2, b = wall.end.simd2
        let mid = (a + b) / 2
        let dir = b - a
        guard simd_length(dir) > 0.01 else { return nil }
        let yaw = atan2(-dir.y, dir.x)

        let mesh = MeshResource.generateText(
            SnugFormat.meters(wall.length),
            extrusionDepth: 0.01,
            font: .systemFont(ofSize: 0.16, weight: .semibold),
            containerFrame: .zero,
            alignment: .center,
            lineBreakMode: .byTruncatingTail
        )
        let textEntity = ModelEntity(mesh: mesh, materials: [UnlitMaterial(color: UIColor(rgb: 0x2B2722))])
        // Recenter the generated text on its own origin.
        let bounds = textEntity.visualBounds(relativeTo: textEntity)
        textEntity.position = -bounds.center

        // Lay flat on the floor and align to the wall, nudged toward the
        // interior so it doesn't sit under the wall box.
        let holder = ModelEntity()
        holder.addChild(textEntity)
        var inward = SIMD2<Float>(dir.y, -dir.x)
        if simd_dot(inward, mid - centroidXZ) > 0 { inward = -inward }
        inward = simd_normalize(inward) * 0.25
        holder.position = SIMD3(mid.x + inward.x, 0.02, mid.y + inward.y)
        let layFlat = simd_quatf(angle: -.pi / 2, axis: [1, 0, 0])
        let align = simd_quatf(angle: yaw, axis: [0, 1, 0])
        holder.orientation = align * layFlat
        return holder
    }

    // MARK: - Materials / palette

    /// Throwaway initial material; `applyPalette` overrides it immediately after
    /// the geometry is built.
    private func placeholderMaterial() -> SimpleMaterial {
        SimpleMaterial(color: .gray, isMetallic: false)
    }

    /// Outline color (identical across modes; pulled from the palette so colors
    /// stay centralized in Theme).
    private var outlineColor: UIColor { RoomPalette.palette(for: .play).outline }

    /// Swap only materials + lighting (and outline / label visibility). No
    /// geometry is touched — the identical-geometry invariant between PLAY and
    /// BUY holds (outlines are sibling entities toggled with `isEnabled`).
    private func applyPalette(for mode: RoomRenderMode) {
        let palette = RoomPalette.palette(for: mode)

        // One shared material instance per surface (Step 9: don't allocate per
        // entity).
        let floorMat = PlayModeMaterials.floor(palette)
        let wallMat = PlayModeMaterials.wall(palette)
        let openingMat = PlayModeMaterials.opening(palette)
        let trimMat = PlayModeMaterials.openingTrim(palette)
        let voidMat = PlayModeMaterials.voidWindow(palette)
        let baseMat = PlayModeMaterials.base(palette)
        let capMat = PlayModeMaterials.wallCap(palette)
        let corniceMat = PlayModeMaterials.cornice(palette)

        setMaterial(floorMat, on: floorEntity)
        setMaterial(baseMat, on: baseEntity)
        for wall in walls {
            setMaterial(wallMat, on: wall.entity)
            setMaterial(capMat, on: wall.cap)
            setMaterial(corniceMat, on: wall.cornice)
        }
        // Windows / open openings blow out to a white void in PLAY; doors keep a
        // paneled face. BUY uses the neutral pane everywhere.
        for opening in openings {
            let usesVoid = palette.usesVoidWindows && opening.kind != .door
            setMaterial(usesVoid ? voidMat : openingMat, on: opening.pane)
            for trim in opening.trims { setMaterial(trimMat, on: trim) }
        }

        // Outlines / caps / cornice (PLAY only). These also obey culling —
        // refreshed each frame in `cullWalls`; set the baseline here.
        showsOutlines = palette.showsOutlines
        showsWallCaps = palette.showsWallCaps
        showsCornice = palette.showsCornice
        floorOutline?.isEnabled = showsOutlines
        for wall in walls {
            wall.outline?.isEnabled = showsOutlines && wall.entity.isEnabled
            wall.cap?.isEnabled = showsWallCaps && wall.entity.isEnabled
            wall.cornice?.isEnabled = showsCornice && wall.entity.isEnabled
        }

        // Soft drop shadow grounds the floating cube against the void (PLAY only).
        dropShadow?.isEnabled = palette.showsDropShadow

        // Dimension labels (BUY only).
        for label in labels { label.isEnabled = palette.showsDimensions }

        // Lighting: warm 3-point in PLAY, neutral in BUY. In PLAY the directional
        // rig is dialed down (Theme) because the image-based light carries the
        // ambient wrap — the key light's main job here is the soft cast shadow.
        keyLight.light.color = palette.keyTint
        keyLight.light.intensity = palette.keyIntensity
        fillA.light.color = palette.fillTint
        fillA.light.intensity = palette.fillIntensity
        fillB.light.color = palette.backTint
        fillB.light.intensity = palette.backIntensity

        // Soft cast shadow from the key light — PLAY only, so BUY's neutral
        // measuring look is unchanged. A large maximumDistance + depth bias keeps
        // it gentle rather than hard-edged.
        keyLight.shadow = (mode == .play)
            ? DirectionalLightComponent.Shadow(maximumDistance: 8, depthBias: 2.0)
            : nil

        // Warm image-based lighting in PLAY (once `environment` is built); none in
        // BUY. Kept last so the directional rig is in place regardless of whether
        // the async environment has loaded yet.
        applyEnvironmentLighting()
    }

    /// Apply the warm studio environment as PLAY image-based lighting, or none in
    /// BUY. On the old `ARView` this set `environment.lighting.resource`; `RealityView`
    /// has no such hook, so the IBL is driven by components: the source lives on
    /// `iblEntity` (set once `environment` loads) and the scene root receives from it
    /// only in PLAY. Removing the receiver in BUY restores the neutral measuring look.
    /// The visible "void" backdrop is no longer a skybox here — it's a SwiftUI colour
    /// layer behind the `RealityView` (see `RoomDioramaScreen`).
    private func applyEnvironmentLighting() {
        if mode == .play, let environment {
            iblEntity.components.set(ImageBasedLightComponent(source: .single(environment)))
            root.components.set(ImageBasedLightReceiverComponent(imageBasedLight: iblEntity))
        } else {
            root.components.remove(ImageBasedLightReceiverComponent.self)
        }
    }

    /// Build the warm studio environment off the main actor, then apply it. There
    /// is NO graceful fallback for the IBL API: a runtime failure is surfaced
    /// loudly (assertionFailure in debug, a console warning otherwise) instead of
    /// being masked. The directional rig still lights the scene either way, but the
    /// soft GI wrap is the intended look and its absence should be obvious.
    private func loadEnvironment() {
        Task { @MainActor [weak self] in
            do {
                let resource = try await StudioEnvironment.makeResource()
                guard let self else { return }
                self.environment = resource
                self.applyEnvironmentLighting()
            } catch {
                assertionFailure("Snug StudioEnvironment IBL failed to build: \(error)")
                print("⚠️ Snug: image-based lighting unavailable — \(error)")
            }
        }
    }

    private func setMaterial(_ material: any RealityKit.Material, on entity: ModelEntity?) {
        guard let entity, var model = entity.model else { return }
        model.materials = [material]
        entity.model = model
    }

    /// Cross-fade to a new render mode: snapshot the current frame (offscreen),
    /// swap materials beneath it, then hand the freeze to the view to fade out in
    /// < 400 ms. If the offscreen snapshot fails it is surfaced loudly by
    /// `OffscreenSnapshotRenderer` and we apply the palette WITHOUT a fade — never a
    /// fabricated frame.
    func setMode(_ newMode: RoomRenderMode, animated: Bool) {
        guard newMode != mode else { return }
        let oldMode = mode
        mode = newMode
        modeGeneration += 1
        let generation = modeGeneration

        let size = pixelSize
        guard animated, size.width > 0, size.height > 0 else {
            applyPalette(for: newMode)
            return
        }

        Task { @MainActor in
            let image = await self.captureSnapshot(mode: oldMode, pixelSize: size)
            // A newer toggle has superseded this one; let its callback drive the
            // cross-fade rather than flashing a stale frame on top of it.
            guard self.modeGeneration == generation else { return }
            guard let image else {
                // Failure already surfaced by the renderer — swap without a fade.
                self.applyPalette(for: newMode)
                return
            }
            // Show the freeze first, then swap materials underneath it.
            self.crossfade?(image)
            self.applyPalette(for: newMode)
        }
    }

    // MARK: - Snapshot

    /// Render the current scene offscreen into a `UIImage`, composited over `mode`'s
    /// background colour. Clones the live scene + camera (the renderer must not be
    /// handed live, parented entities) and re-points the cloned IBL receiver at the
    /// cloned source so PLAY lighting matches the on-screen frame.
    private func captureSnapshot(mode: RoomRenderMode, pixelSize: CGSize) async -> UIImage? {
        let sceneClone = root.clone(recursive: true)
        // A cloned `ImageBasedLightReceiverComponent` still references the ORIGINAL
        // source entity (not in the offscreen scene), so re-point it at the clone.
        if root.components[ImageBasedLightReceiverComponent.self] != nil,
           let clonedSource = sceneClone.findEntity(named: Self.iblEntityName) {
            sceneClone.components.set(ImageBasedLightReceiverComponent(imageBasedLight: clonedSource))
        }
        let cameraClone = camera.clone(recursive: false)
        cameraClone.transform = Transform(matrix: camera.transformMatrix(relativeTo: nil))

        guard let raw = await OffscreenSnapshotRenderer.image(
            scene: sceneClone, camera: cameraClone, pixelSize: pixelSize) else { return nil }
        return Self.composite(raw, over: RoomPalette.palette(for: mode).background)
    }

    /// Flatten a (transparent-backed) render over a solid background colour so the
    /// freeze frame and thumbnail carry the diorama's backdrop, matching what the
    /// SwiftUI background layer shows on screen.
    private static func composite(_ image: UIImage, over color: UIColor) -> UIImage {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = image.scale
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: image.size, format: format)
        return renderer.image { context in
            color.setFill()
            context.fill(CGRect(origin: .zero, size: image.size))
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }
    }

    // MARK: - Camera

    private func frameCamera(room: RoomModel) {
        let corners = room.floorCorners.map(\.simd2)
        guard !corners.isEmpty else { return }
        let xs = corners.map(\.x), zs = corners.map(\.y)
        let minX = xs.min()!, maxX = xs.max()!, minZ = zs.min()!, maxZ = zs.max()!
        // Aim at the true floor-polygon centroid, not the bounding-box center: for
        // an L-shaped room the bbox center can land in the missing quadrant.
        let centroid = corners.reduce(SIMD2<Float>.zero, +) / Float(corners.count)
        target = SIMD3(centroid.x, room.ceilingHeight * 0.35, centroid.y)

        let span = simd_length(SIMD2(maxX - minX, maxZ - minZ))
        let extent = max(span, room.ceilingHeight)
        // Tighter framing so the room fills more of the screen. NOTE: this camera is
        // ORTHOGRAPHIC — `orthoScale(forRadius:)` works out to `multiplier · extent`
        // (the FOV term cancels), so the multiplier on `fitDistance` IS the fraction
        // of `extent` the view spans vertically. 0.85 fills more than the old 1.2
        // without clipping (extent uses the bbox diagonal, an over-estimate of the
        // visible footprint). The range still lets the user pinch out to ~3× for the
        // full room.
        let halfFOV = (Self.isoFOVDegrees * .pi / 180) / 2
        let fitDistance = (extent * 0.5) / tan(halfFOV)
        radius = max(fitDistance * 0.85, 2.0)
        radiusRange = max(fitDistance * 0.3, 0.8)...max(fitDistance * 3.0, 14)
        // Slightly steeper than the canonical iso angle — a more top-down read makes
        // the floor plan and furniture placement clearer.
        elevation = .pi / 4

        defaultAzimuth = azimuth
        defaultElevation = elevation
        defaultRadius = radius
        defaultTarget = target
    }

    private func updateCamera() {
        let position = target + SIMD3<Float>(
            radius * cosf(elevation) * sinf(azimuth),
            radius * sinf(elevation),
            radius * cosf(elevation) * cosf(azimuth)
        )
        camera.look(at: target, from: position, relativeTo: nil)

        // Drive the orthographic view-volume from `radius` so orbit/zoom/reset (all
        // of which already mutate `radius`) keep working unchanged. Re-setting the
        // value-type component is cheap and only happens on camera moves.
        var ortho = OrthographicCameraComponent()
        ortho.scale = Self.orthoScale(forRadius: radius)
        camera.components.set(ortho)
    }

    /// The orthographic `scale` (vertical world extent the view spans) that matches
    /// what a perspective camera at `radius` with the iso calibration FOV would have
    /// framed — so switching to true ortho keeps the tuned framing at every zoom
    /// level, only removing the perspective foreshortening (which is the point).
    private static func orthoScale(forRadius radius: Float) -> Float {
        let halfFOV = (isoFOVDegrees * .pi / 180) / 2
        return 2 * radius * tan(halfFOV)
    }

    func resetCamera(animated: Bool) {
        if animated {
            cameraAnim = CameraAnim(
                duration: 0.45,
                fromAz: azimuth, toAz: defaultAzimuth,
                fromEl: elevation, toEl: defaultElevation,
                fromR: radius, toR: defaultRadius,
                fromTarget: target, toTarget: defaultTarget
            )
        } else {
            azimuth = defaultAzimuth
            elevation = defaultElevation
            radius = defaultRadius
            target = defaultTarget
            updateCamera()
        }
    }

    // MARK: - External state (driven by the SwiftUI view's `update`)

    func applyExternalState(mode newMode: RoomRenderMode, resetToken: Int) {
        if mode != newMode { setMode(newMode, animated: true) }
        if lastResetToken != resetToken {
            lastResetToken = resetToken
            resetCamera(animated: true)
        }
    }

    /// Reconcile the live furniture entities with the placement tray's footprints
    /// (editing mode only). Adds new pieces, removes cleared/deleted ones, rebuilds
    /// an entity only when its geometry changed (position/size/rotation), and
    /// re-tints each by its `PlacementState`. Keyed by `footprint.id` in a store
    /// separate from the wall/floor scene, so it never perturbs the PLAY/BUY
    /// geometry invariant.
    func syncFurniture(_ footprints: [FurnitureFootprint], states: [UUID: PlacementState], selectedID: UUID?) {
        let active = footprints.filter { !$0.isCleared }
        currentFootprints = active
        selectedFurnitureID = selectedID
        let activeIDs = Set(active.map(\.id))

        // Remove entities for pieces that were cleared or deleted.
        for (id, entity) in furnitureEntities where !activeIDs.contains(id) {
            entity.removeFromParent()
            furnitureEntities[id] = nil
            furnitureSnapshots[id] = nil
        }

        for footprint in active {
            // (Re)build when new or when its geometry changed; a box mesh is cheap,
            // and this keeps size/position/rotation edits correct without mutating
            // meshes in place.
            if furnitureEntities[footprint.id] == nil || furnitureSnapshots[footprint.id] != footprint {
                furnitureEntities[footprint.id]?.removeFromParent()
                let entity = FurnitureEntityBuilder.entity(for: footprint)
                root.addChild(entity)
                furnitureEntities[footprint.id] = entity
                furnitureSnapshots[footprint.id] = footprint
            }
            if let entity = furnitureEntities[footprint.id] {
                let selected = footprint.id == selectedID
                FurnitureEntityBuilder.applyPlacementState(
                    states[footprint.id] ?? .valid,
                    selected: selected,
                    to: entity
                )
                // Selection "pop": scale to 1.03 when selected, 1.0 otherwise. Only
                // animate when the scale actually changes, so a re-sync (e.g. after a
                // drag ends) doesn't re-fire it — and it stays put during a live drag,
                // which never round-trips through syncFurniture. RealityKit's
                // transform-animation API has no spring timing; a short easeOut reads
                // as the snappy pop the spec calls for (~0.2 s).
                let targetScale: Float = selected ? 1.03 : 1.0
                if abs(entity.transform.scale.x - targetScale) > 0.001 {
                    var transform = entity.transform
                    transform.scale = SIMD3(repeating: targetScale)
                    entity.move(to: transform, relativeTo: entity.parent, duration: 0.2, timingFunction: .easeOut)
                }
            }
        }
    }

    // MARK: - Furniture hit-testing (orthographic screen → world)

    /// The world-space ray for a screen point under the ORTHOGRAPHIC diorama camera.
    /// Every screen point casts a ray parallel to the camera forward; its origin is
    /// offset in the camera's right/up axes by the screen offset × world-units-per-
    /// point (`orthoScale / viewHeight`). Shared by both the floor intersection
    /// (drag) and the box hit-test (selection) so they can never disagree.
    ///
    /// The right/up/forward basis is read DIRECTLY from the camera's live world
    /// matrix columns — not reconstructed from `cross(forward, worldUp)`. Manual
    /// trig matches RealityKit's rendered orientation only when the camera is on a
    /// primary axis; off-axis (orbited yaw + pitch) the two drift apart, which is
    /// the "accurate from some angles, not others" tap bug. The matrix columns ARE
    /// the orientation RealityKit renders with, so the ray locks to the visuals.
    private func orthoRay(forScreenPoint point: CGPoint, viewSize: CGSize)
        -> (origin: SIMD3<Float>, direction: SIMD3<Float>)? {
        guard viewSize.width > 0, viewSize.height > 0 else { return nil }
        let m = camera.transformMatrix(relativeTo: nil)
        let right = simd_normalize(SIMD3(m.columns.0.x, m.columns.0.y, m.columns.0.z))   // +X
        let up = simd_normalize(SIMD3(m.columns.1.x, m.columns.1.y, m.columns.1.z))      // +Y
        let forward = simd_normalize(SIMD3(-m.columns.2.x, -m.columns.2.y, -m.columns.2.z)) // -Z = view dir
        let camPos = SIMD3(m.columns.3.x, m.columns.3.y, m.columns.3.z)

        let worldPerPoint = Self.orthoScale(forRadius: radius) / Float(viewSize.height)
        let offX = Float(point.x - viewSize.width / 2) * worldPerPoint
        let offY = Float(point.y - viewSize.height / 2) * worldPerPoint
        // Screen y grows downward → subtract `up`.
        let origin = camPos + right * offX - up * offY
        return (origin, forward)
    }

    /// Intersect a screen point's ortho ray with the floor plane (Y = 0). Used by
    /// drag-to-move. No view/projection matrices or ARSession needed.
    func floorPoint(forScreenPoint point: CGPoint, viewSize: CGSize) -> SIMD2<Float>? {
        guard let ray = orthoRay(forScreenPoint: point, viewSize: viewSize),
              abs(ray.direction.y) > 1e-5 else { return nil }
        let t = (0 - ray.origin.y) / ray.direction.y
        let hit = ray.origin + ray.direction * t
        return SIMD2(hit.x, hit.z)
    }

    /// The furniture id under a screen point — the nearest piece whose 3D oriented
    /// box the ortho ray enters. This is an ANALYTIC ray↔OBB test against the
    /// footprints (not `Scene.raycast`, whose collision participation in a non-AR
    /// `RealityView` is unreliable, and not a 2D floor projection, which missed
    /// tall/rotated pieces). It hits the real box the user sees at any camera
    /// angle. The overlay skips this entirely when there's no furniture.
    func furnitureID(atScreenPoint point: CGPoint, viewSize: CGSize) -> UUID? {
        guard let ray = orthoRay(forScreenPoint: point, viewSize: viewSize) else { return nil }
        var bestT = Float.greatestFiniteMagnitude
        var bestID: UUID?
        for footprint in currentFootprints {
            if let t = Self.rayEntersBox(origin: ray.origin, direction: ray.direction, footprint: footprint),
               t < bestT {
                bestT = t
                bestID = footprint.id
            }
        }
        return bestID
    }

    /// Entry distance where `ray` enters the footprint's oriented box (rotated
    /// about Y, sitting on the floor), or nil if it misses. Standard ray–OBB slab
    /// test done in the box's local frame. Deterministic and independent of
    /// RealityKit collision state, so it's reliable at every angle.
    private static func rayEntersBox(origin: SIMD3<Float>, direction: SIMD3<Float>,
                                     footprint: FurnitureFootprint) -> Float? {
        let center = footprint.worldPosition   // .y is already half-height above the floor
        let half = SIMD3(footprint.dimensions.x / 2, footprint.dimensions.z / 2, footprint.dimensions.y / 2)
        // Express the ray in the box's local frame (inverse yaw about Y).
        let c = cos(footprint.yRotation), s = sin(footprint.yRotation)
        func toLocal(_ v: SIMD3<Float>, translate: Bool) -> SIMD3<Float> {
            let p = translate ? v - center : v
            return SIMD3(p.x * c + p.z * s, p.y, -p.x * s + p.z * c)   // Ry(-θ)
        }
        let o = toLocal(origin, translate: true)
        let d = toLocal(direction, translate: false)

        var tMin = -Float.greatestFiniteMagnitude
        var tMax = Float.greatestFiniteMagnitude
        for axis in 0..<3 {
            let oi = o[axis], di = d[axis], h = half[axis]
            if abs(di) < 1e-6 {
                if oi < -h || oi > h { return nil }   // parallel to slab and outside it
            } else {
                var t1 = (-h - oi) / di
                var t2 = (h - oi) / di
                if t1 > t2 { swap(&t1, &t2) }
                tMin = max(tMin, t1)
                tMax = min(tMax, t2)
                if tMin > tMax { return nil }
            }
        }
        return tMax >= 0 ? max(tMin, 0) : nil
    }

    // MARK: - Live drag-to-move (driven by the gesture overlay)

    /// Offset captured at grab: (box floor-center) − (floor point under the finger).
    /// Maintained through the drag so the piece keeps its position RELATIVE to the
    /// finger instead of snapping its center under the finger — which, on a tilted
    /// camera, made the box float above the fingertip.
    private var dragGrabOffset = SIMD2<Float>(0, 0)

    /// Begin moving `id`. Captures the grab offset so the piece tracks the finger
    /// without jumping. A light tap confirms the grab.
    func beginFurnitureDrag(_ id: UUID, atScreenPoint point: CGPoint, viewSize: CGSize) {
        draggingFurnitureID = id
        lastDragState = nil
        if let footprint = currentFootprints.first(where: { $0.id == id }),
           let grab = floorPoint(forScreenPoint: point, viewSize: viewSize) {
            dragGrabOffset = SIMD2(footprint.worldPosition.x, footprint.worldPosition.z) - grab
        } else {
            dragGrabOffset = .zero
        }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    /// Move the dragging piece so its center sits under `screenPoint` on the floor.
    /// Mutates the entity transform + tint directly (no SwiftUI round-trip, for
    /// immediacy); the final footprints are pushed up in `endFurnitureDrag`. The
    /// floor-anchor invariant holds: only X/Z change, never Y.
    func dragFurniture(toScreenPoint screenPoint: CGPoint, viewSize: CGSize) {
        guard let id = draggingFurnitureID,
              let room = editingRoom,
              let floor = floorPoint(forScreenPoint: screenPoint, viewSize: viewSize),
              let index = currentFootprints.firstIndex(where: { $0.id == id }) else { return }

        currentFootprints[index].worldPosition.x = floor.x + dragGrabOffset.x
        currentFootprints[index].worldPosition.z = floor.y + dragGrabOffset.y   // SIMD2.y carries world Z; .y altitude untouched
        let footprint = currentFootprints[index]

        let state = FurniturePlacementValidator.validate(
            footprint: footprint, against: room, existingFootprints: currentFootprints)

        if let entity = furnitureEntities[id] {
            entity.position = footprint.worldPosition
            FurnitureEntityBuilder.applyPlacementState(state, selected: true, to: entity)
            furnitureSnapshots[id] = footprint   // keep snapshot in sync so the post-drag re-sync won't rebuild
        }

        if state == .invalid && lastDragState != .invalid {
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
        }
        lastDragState = state
    }

    /// End the drag and return the updated footprints for persistence.
    func endFurnitureDrag() -> [FurnitureFootprint] {
        draggingFurnitureID = nil
        lastDragState = nil
        return currentFootprints
    }

    // MARK: - Live pinch-to-resize (width/depth only)

    private var resizingFurnitureID: UUID?
    /// Dimensions captured at pinch start, so the cumulative gesture scale applies
    /// to a stable base rather than compounding each callback.
    private var resizeBaseDimensions: SIMD3<Float> = .one

    static let minFurnitureWidth: Float = 0.30
    static let maxFurnitureWidth: Float = 3.50
    static let minFurnitureDepth: Float = 0.30
    static let maxFurnitureDepth: Float = 2.50

    func beginFurnitureResize(_ id: UUID) {
        guard let footprint = currentFootprints.first(where: { $0.id == id }) else { return }
        resizingFurnitureID = id
        resizeBaseDimensions = footprint.dimensions
        lastDragState = nil
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    /// Scale width (X) and depth (Y) by the cumulative gesture `scale`, clamped.
    /// Height (Z) is NEVER changed. The footprint center is unchanged and height is
    /// fixed, so the box grows/shrinks around its center and stays floor-anchored.
    /// The mesh + collision shape are replaced in place (no remove/re-add → no pop).
    func resizeFurniture(scale: Float) {
        guard let id = resizingFurnitureID,
              let room = editingRoom,
              let index = currentFootprints.firstIndex(where: { $0.id == id }) else { return }

        let width = min(max(resizeBaseDimensions.x * scale, Self.minFurnitureWidth), Self.maxFurnitureWidth)
        let depth = min(max(resizeBaseDimensions.y * scale, Self.minFurnitureDepth), Self.maxFurnitureDepth)
        let height = resizeBaseDimensions.z   // unchanged
        currentFootprints[index].dimensions = SIMD3(width, depth, height)
        let footprint = currentFootprints[index]

        let state = FurniturePlacementValidator.validate(
            footprint: footprint, against: room, existingFootprints: currentFootprints)

        if let entity = furnitureEntities[id] as? ModelEntity, var model = entity.model {
            // generateBox uses (width: x, height: z, depth: y) — the convention in
            // FurnitureEntityBuilder. Replace mesh + collision in place.
            model.mesh = .generateBox(width: width, height: height, depth: depth, cornerRadius: 0.04)
            entity.model = model
            entity.collision = CollisionComponent(shapes: [.generateBox(size: SIMD3(width, height, depth))])
            // Drop the stale-sized selection border so applyPlacementState rebuilds
            // it to fit the resized box.
            entity.findEntity(named: FurnitureEntityBuilder.selectionOutlineName)?.removeFromParent()
            FurnitureEntityBuilder.applyPlacementState(state, selected: true, to: entity)
            furnitureSnapshots[id] = footprint
        }

        if state == .invalid && lastDragState != .invalid {
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
        }
        lastDragState = state
    }

    func endFurnitureResize() -> [FurnitureFootprint] {
        resizingFurnitureID = nil
        lastDragState = nil
        return currentFootprints
    }

    // MARK: - Per-frame loop

    func onSceneUpdate(deltaTime: TimeInterval) {
        advanceCameraAnim(deltaTime: deltaTime)
        cullWalls()
        captureThumbnailIfNeeded()
    }

    private func advanceCameraAnim(deltaTime: TimeInterval) {
        guard var anim = cameraAnim else { return }
        anim.elapsed += deltaTime
        let t = Float(min(1, anim.elapsed / anim.duration))
        let e = Self.easeOutBack(t)
        azimuth = anim.fromAz + (anim.toAz - anim.fromAz) * e
        elevation = anim.fromEl + (anim.toEl - anim.fromEl) * e
        radius = anim.fromR + (anim.toR - anim.fromR) * e
        target = anim.fromTarget + (anim.toTarget - anim.fromTarget) * e
        updateCamera()
        cameraAnim = (t >= 1) ? nil : anim
    }

    /// Hide walls between the camera and the room interior — the open-dollhouse
    /// view. A wall is hidden when the camera is on its outward side.
    private func cullWalls() {
        let cam = camera.position(relativeTo: nil)
        let camXZ = SIMD2(cam.x, cam.z)
        var hidden = [Bool](repeating: false, count: walls.count)
        for (i, wall) in walls.enumerated() {
            let toCam = camXZ - wall.midXZ
            let isHidden = simd_dot(wall.outwardXZ, toCam) > 0.05
            hidden[i] = isHidden
            wall.entity.isEnabled = !isHidden
            wall.outline?.isEnabled = !isHidden && showsOutlines
            wall.cap?.isEnabled = !isHidden && showsWallCaps
            wall.cornice?.isEnabled = !isHidden && showsCornice
        }
        for opening in openings where hidden.indices.contains(opening.wallIndex) {
            opening.entity.isEnabled = !hidden[opening.wallIndex]
        }
    }

    private func captureThumbnailIfNeeded() {
        guard !didSnapshot, onThumbnail != nil else { return }
        frameCount += 1
        // Give the scene a few frames to render (and the async environment a chance
        // to load) before grabbing the thumbnail. Wait, too, until the view's pixel
        // size is known so the offscreen render is correctly sized.
        guard frameCount >= 8 else { return }
        let size = pixelSize
        guard size.width > 0, size.height > 0 else { return }
        didSnapshot = true
        let mode = self.mode
        Task { @MainActor in
            guard let image = await self.captureSnapshot(mode: mode, pixelSize: size),
                  let data = image.pngData() else { return }
            self.onThumbnail?(data)
        }
    }

    private static func easeOutBack(_ t: Float) -> Float {
        let c1: Float = 1.70158
        let c3 = c1 + 1
        let p = t - 1
        return 1 + c3 * p * p * p + c1 * p * p
    }

    // MARK: - Gesture intents (from `SceneGestureOverlay`)

    /// One-finger drag → orbit. `dx`/`dy` are incremental screen-point deltas.
    func orbit(dx: Float, dy: Float) {
        cameraAnim = nil
        azimuth -= dx * 0.008
        elevation = min(max(elevation - dy * 0.008, 0.06), .pi / 2 - 0.05)
        updateCamera()
    }

    /// Two-finger drag → pan the look-at target across the floor, in the camera's
    /// screen plane (right/forward derived from the current azimuth).
    func pan(dx: Float, dy: Float) {
        cameraAnim = nil
        let right = SIMD3<Float>(cosf(azimuth), 0, -sinf(azimuth))
        let forward = SIMD3<Float>(sinf(azimuth), 0, cosf(azimuth))
        let scale = radius * 0.0016
        var newTarget = target
        newTarget -= right * dx * scale
        newTarget += forward * dy * scale
        // Keep the target from wandering far outside the room footprint.
        let limit: Float = radiusRange.upperBound
        newTarget.x = min(max(newTarget.x, centroidXZ.x - limit), centroidXZ.x + limit)
        newTarget.z = min(max(newTarget.z, centroidXZ.y - limit), centroidXZ.y + limit)
        target = newTarget
        updateCamera()
    }

    /// Pinch → zoom. `scale` is the recognizer's incremental scale (reset to 1 each
    /// callback), so dividing `radius` by it matches the old behaviour exactly.
    func pinch(scale: Float) {
        cameraAnim = nil
        guard scale > 0 else { return }
        radius = min(max(radius / scale, radiusRange.lowerBound), radiusRange.upperBound)
        updateCamera()
    }
}
