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

    // Native-gesture state. Camera gestures are cumulative in SwiftUI; that cumulative
    // tracking now lives on `RoomSceneController` (NOT `@State`), so orbit/zoom ticks
    // never invalidate `body`. Furniture-drag state decides move-vs-select per gesture.
    @State private var furnitureDragID: UUID?
    @State private var furnitureDragIsMove = false
    @State private var furnitureResizeActive = false

    @Environment(\.displayScale) private var displayScale
    @Environment(CatalogService.self) private var catalog

    /// Maps a placed footprint's `catalogItemID` to its bundled USDZ asset name, so
    /// the controller can load the realistic product model for BUY mode without
    /// depending on `CatalogService` directly. Nil for non-catalog pieces / items
    /// with no bundled model (→ the controller keeps the stylized box).
    private func catalogModelResolver() -> (String) -> String? {
        { [catalog] catalogID in
            catalog.items.first { $0.id == catalogID }?.modelAssetName
        }
    }

    var body: some View {
        GeometryReader { geo in
            RealityView { content in
                // RealityKit enables per-object motion blur by DEFAULT, which smears
                // the walls/floor into a blurry trail during a fast orbit/zoom. The
                // diorama is a clean stylized scene, not a film camera — disable it
                // (also cheaper to render). Only touches post-processing, never geometry.
                content.renderingEffects.motionBlur = .disabled
                controller.catalogModelAssetName = catalogModelResolver()
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
                controller.catalogModelAssetName = catalogModelResolver()
                controller.applyExternalState(mode: mode, resetToken: resetToken)
                if let editableFurniture {
                    controller.syncFurniture(editableFurniture, states: placementStates, selectedID: selectedFurnitureID)
                }
            }
            // Native RealityKit gestures. Furniture interactions are
            // `.targetedToAnyEntity()` (RealityKit unprojects to the right entity
            // for the orthographic camera — no manual ray math), at high priority
            // so they win when a touch lands on a piece; camera orbit/zoom are
            // plain gestures that handle empty space. (The old UIKit overlay +
            // manual ortho ray drifted off-axis; this is the fix.)
            // Gesture composition (this ordering is load-bearing — see below).
            // Furniture tap/drag/pinch are `.targetedToAnyEntity()`, so they only
            // fire when the touch lands on a piece. The CAMERA gestures are attached
            // as `.simultaneousGesture` ON PURPOSE: a plain `.gesture` orbit is LOWER
            // priority than the targeted gestures and SwiftUI won't deliver to it
            // until the targeted drag *fails* — but a targeted drag only fails once
            // the arbiter rules out an entity hit, which starves orbit to ~1 event/s
            // (the "laggy, non-responsive" bug). Simultaneous gestures never wait on
            // arbitration, so orbit/zoom stay smooth; they're GATED below so they no-op
            // while a furniture drag/resize is in flight (the targeted gesture sets the
            // flag), giving clean move-vs-orbit separation without the priority stall.
            // The tap pair keeps the priority relationship (furniture tap must beat the
            // empty-space deselect), and taps are discrete so they don't stall.
            .highPriorityGesture(furnitureTapGesture)
            .gesture(furnitureDragGesture)
            .gesture(furnitureMagnifyGesture)
            .gesture(deselectTapGesture)
            .simultaneousGesture(cameraOrbitGesture)
            .simultaneousGesture(cameraZoomGesture)
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

    // MARK: - Gestures (native RealityKit, entity-targeted)

    /// A horizontal plane (normal = +Y) at world height `y`, expressed as a 4×4
    /// transform for `unproject(…ontoPlane:)`. Used to drop the 2D drag point onto
    /// the floor during a furniture move.
    private static func horizontalPlane(atHeight y: Float) -> float4x4 {
        var m = matrix_identity_float4x4
        m.columns.3.y = y
        return m
    }

    /// Tap on a furniture entity → select it. RealityKit returns the exact tapped
    /// entity (correct unprojection for the ortho camera), so no manual ray.
    private var furnitureTapGesture: some Gesture {
        SpatialTapGesture().targetedToAnyEntity().onEnded { value in
            if let (_, id) = taggedFurnitureRoot(for: value.entity) {
                onSelectFurniture?(id)
            }
        }
    }

    /// Walk up from a hit entity to the box that carries the furniture tag — taps
    /// can land on a child (label / outline shell), which has no tag of its own.
    private func taggedFurnitureRoot(for entity: Entity) -> (entity: Entity, id: UUID)? {
        var current: Entity? = entity
        while let e = current {
            if let tag = e.components[FurnitureTagComponent.self] {
                return (e, tag.footprintID)
            }
            current = e.parent
        }
        return nil
    }

    /// Drag a furniture entity. On the selected piece → move it on the floor using
    /// RealityKit's native `unproject(…ontoPlane:)` (camera-correct, no manual ray);
    /// dragging an UNselected piece selects it without moving (a second drag moves).
    private var furnitureDragGesture: some Gesture {
        DragGesture()
            .targetedToAnyEntity()
            .onChanged { value in
                guard let (root, id) = taggedFurnitureRoot(for: value.entity),
                      let parent = root.parent else { return }
                let floorPlane = Self.horizontalPlane(atHeight: root.position.y)

                if furnitureDragID != id {
                    furnitureDragID = id

                    if id == selectedFurnitureID {
                        furnitureDragIsMove = true

                        if let start = value.unproject(value.startLocation, from: .local,
                                                       to: parent, ontoPlane: floorPlane) {
                            controller.beginFurnitureDrag(id, grabWorldXZ: SIMD2(start.x, start.z))
                        }
                    } else {
                        furnitureDragIsMove = false
                        onSelectFurniture?(id)
                    }
                }

                if furnitureDragIsMove,
                   let world = value.unproject(value.location, from: .local,
                                               to: parent, ontoPlane: floorPlane) {
                    controller.dragFurniture(toWorldXZ: SIMD2(world.x, world.z))
                }
            }
            .onEnded { _ in
                if furnitureDragIsMove {
                    onFurnitureChanged?(controller.endFurnitureDrag())
                }

                furnitureDragID = nil
                furnitureDragIsMove = false
            }
    }

    /// Pinch on the selected furniture entity → resize width/depth (height fixed).
    private var furnitureMagnifyGesture: some Gesture {
        MagnifyGesture().targetedToAnyEntity()
            .onChanged { value in
                guard let (_, id) = taggedFurnitureRoot(for: value.entity),
                      id == selectedFurnitureID else { return }
                if !furnitureResizeActive { controller.beginFurnitureResize(id); furnitureResizeActive = true }
                controller.resizeFurniture(scale: Float(value.magnification))
            }
            .onEnded { _ in
                if furnitureResizeActive {
                    onFurnitureChanged?(controller.endFurnitureResize())
                    furnitureResizeActive = false
                }
            }
    }

    /// Tap on empty space → deselect. (Fires only when no entity tap consumed it.)
    private var deselectTapGesture: some Gesture {
        TapGesture().onEnded { onSelectFurniture?(nil) }
    }

    /// One-finger drag on empty space → orbit. The controller tracks the cumulative
    /// translation and feeds itself incremental deltas, so this closure never writes
    /// `@State` (which would invalidate `body` every frame and stall the gesture).
    private var cameraOrbitGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                // Gate: a furniture drag (targeted gesture) sets `furnitureDragID` on
                // its first tick; once set, this simultaneous orbit no-ops so dragging
                // a piece doesn't also spin the camera. Empty-space drags never set it.
                guard furnitureDragID == nil else { return }
                controller.orbitContinuous(translation: value.translation)
            }
            .onEnded { _ in controller.endOrbit() }
    }

    /// Pinch on empty space → zoom. Cumulative magnification is converted to the
    /// incremental factor inside the controller — again, no `@State` written per tick.
    private var cameraZoomGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                // Gate: a pinch on the selected piece sets `furnitureResizeActive`;
                // while it's active this simultaneous zoom no-ops so resizing furniture
                // doesn't also zoom the camera.
                guard !furnitureResizeActive else { return }
                controller.zoomContinuous(magnification: value.magnification)
            }
            .onEnded { _ in controller.endZoom() }
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
    /// Last-synced placement state + selection (editing mode), so a PLAY↔BUY swap
    /// can re-tint furniture with the new mode's color while preserving the fit-state
    /// coloring — without waiting for a SwiftUI round-trip.
    private var lastFurnitureStates: [UUID: PlacementState] = [:]
    private var lastSelectedFurnitureID: UUID?
    /// When true, `buildGeometry` skips the static furniture pass — the tray owns
    /// furniture entities through `syncFurniture`.
    private var editingFurniture = false
    /// Last-synced footprints (non-cleared), so live drag/pinch can validate and
    /// look up the dragged piece without a SwiftUI round-trip.
    private(set) var currentFootprints: [FurnitureFootprint] = []
    /// The room being edited — stored so live drag/pinch can validate without a
    /// SwiftUI round-trip. Set in `makeEntities`.
    private var editingRoom: RoomModel?
    /// Resolves a footprint's `catalogItemID` to its bundled USDZ asset name (set by
    /// the view from `CatalogService`). Nil-returning for non-catalog pieces / items
    /// with no model → the stylized box is kept. The realistic model is BUY-only.
    var catalogModelAssetName: ((String) -> String?)?
    /// Footprint ids whose product model is currently loading, so a re-sync doesn't
    /// kick off a duplicate async load.
    private var modelLoadingIDs: Set<UUID> = []

    /// The piece a single-finger drag is currently moving (nil when not dragging).
    private var draggingFurnitureID: UUID?
    /// Previous placement state during a drag, so the "became invalid" warning
    /// haptic fires once on transition rather than every move.
    private var lastDragState: PlacementState?

    // MARK: Camera state

    /// Camera field of view (degrees). We use a PERSPECTIVE camera with a NARROW
    /// FOV, which reads as near-isometric (little foreshortening) while keeping the
    /// thing orthographic broke: RealityKit's native entity gesture hit-testing
    /// (`targetedToAnyEntity` / `unproject`) does NOT work against an
    /// `OrthographicCameraComponent` on iOS — taps/drags simply don't register.
    /// A long-lens perspective is the smallest change that restores reliable native
    /// gestures; BUY-mode scale is only mildly affected at this FOV (labels still
    /// show true measurements). Also drives initial framing in `frameCamera`.
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

        // Narrow-FOV PERSPECTIVE camera (NOT orthographic): native entity gesture
        // hit-testing (`targetedToAnyEntity`/`unproject`) is broken against an
        // ortho camera on iOS, so taps/drags don't register. A long lens keeps the
        // near-isometric look. Set ONCE here and never overwritten — `updateCamera`
        // only moves it (zoom = distance via `radius`), so it stays perspective for
        // the whole session (orbiting/zooming won't revert it and re-break gestures).
        var cam = PerspectiveCameraComponent()
        cam.fieldOfViewInDegrees = Self.isoFOVDegrees
        camera.components.set(cam)
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
                let entity = FurnitureEntityBuilder.entity(for: footprint, mode: mode)
                root.addChild(entity)
                // Track so a PLAY↔BUY swap can re-tint these static pieces too.
                furnitureEntities[footprint.id] = entity
                furnitureSnapshots[footprint.id] = footprint
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
            retintFurniture()
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
                self.retintFurniture()
                return
            }
            // Show the freeze first, then swap materials underneath it.
            self.crossfade?(image)
            self.applyPalette(for: newMode)
            self.retintFurniture()
        }
    }

    /// Re-tint furniture after a PLAY↔BUY swap — `applyPalette` only covers
    /// walls/floor/openings. Editing pieces keep their fit-state + selection
    /// coloring (re-applied for the new mode); static viewing pieces re-tint to the
    /// mode's base color. Geometry is never touched, only the material.
    private func retintFurniture() {
        for (id, entity) in furnitureEntities {
            if editingFurniture {
                FurnitureEntityBuilder.applyPlacementState(
                    lastFurnitureStates[id] ?? .valid,
                    selected: id == lastSelectedFurnitureID,
                    mode: mode,
                    to: entity
                )
            } else if let footprint = furnitureSnapshots[id] {
                FurnitureEntityBuilder.retint(entity, footprint: footprint, mode: mode)
            }
            // Show/hide the realistic product model for the new mode (BUY shows it,
            // PLAY restores the stylized box). Runs after the tint so the box
            // material is correct before the model is layered over it.
            if let footprint = furnitureSnapshots[id] {
                updateRealisticModel(for: footprint, on: entity)
            }
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
        // Tighter framing so the room fills more of the screen. `fitDistance` is the
        // distance at which the room `extent` exactly fills the narrow camera FOV;
        // 0.85 sits a bit closer so the room fills more (extent is the bbox diagonal,
        // an over-estimate of the visible footprint, so this won't clip). The range
        // lets the user pinch out to ~3× for the full room. With the narrow FOV this
        // reads near-isometric, but it IS perspective (required for native gestures).
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
        // Perspective camera: zoom is DISTANCE. `radius` (mutated by orbit/zoom/
        // reset) sets how far the camera sits, so `look(at:from:)` above is all that's
        // needed. We deliberately do NOT set a camera component here — the narrow-FOV
        // `PerspectiveCameraComponent` from `makeEntities` must persist (re-setting an
        // ortho component each frame is what re-broke native gesture hit-testing).
        camera.look(at: target, from: position, relativeTo: nil)
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
        lastFurnitureStates = states
        lastSelectedFurnitureID = selectedID
        let active = footprints.filter { !$0.isCleared }
        currentFootprints = active
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
                let entity = FurnitureEntityBuilder.entity(for: footprint, mode: mode)
                root.addChild(entity)
                furnitureEntities[footprint.id] = entity
                furnitureSnapshots[footprint.id] = footprint
            }
            if let entity = furnitureEntities[footprint.id] {
                let selected = footprint.id == selectedID
                FurnitureEntityBuilder.applyPlacementState(
                    states[footprint.id] ?? .valid,
                    selected: selected,
                    mode: mode,
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
                updateRealisticModel(for: footprint, on: entity)
            }
        }
    }

    // MARK: - Realistic catalog model (BUY only)

    /// Show the realistic product model (BUY + a catalog item with a bundled USDZ)
    /// or restore the stylized box (PLAY, non-catalog, or no asset). The USDZ loads
    /// asynchronously on first need; the box shows until it arrives, then the box
    /// mesh is hidden beneath it. Visual only — collision/fit/gestures stay on the box.
    private func updateRealisticModel(for footprint: FurnitureFootprint, on box: Entity) {
        let assetName = (mode == .buy)
            ? footprint.catalogItemID.flatMap { catalogModelAssetName?($0) }
            : nil

        guard let assetName else {
            // PLAY / non-catalog / no bundled model → ensure the stylized box shows.
            if FurnitureEntityBuilder.hasRealisticModel(box) {
                FurnitureEntityBuilder.removeRealisticModel(from: box)
                reapplyFurnitureState(for: footprint.id, on: box)
            }
            return
        }

        if FurnitureEntityBuilder.hasRealisticModel(box) {
            // Already showing: keep it fit to the current dimensions (covers resize).
            if let model = box.findEntity(named: FurnitureEntityBuilder.realisticModelName) {
                FurnitureEntityBuilder.scaleRealisticModel(model, to: footprint.dimensions)
            }
            return
        }

        guard !modelLoadingIDs.contains(footprint.id) else { return }
        modelLoadingIDs.insert(footprint.id)
        let id = footprint.id
        // The product's true color, applied to the (untextured placeholder) model so
        // BUY shows real color — identical source to the box's BUY tint, so model and
        // box never disagree. (Real product USDZ would pass nil to keep their materials.)
        let tint = FurnitureEntityBuilder.tint(
            footprint.appearance.colorCategory, exact: footprint.appearance.exactColorRGB, mode: .buy)
        Task { [weak self] in
            let model = await CatalogModelLoader.shared.model(named: assetName)
            guard let self else { return }
            self.modelLoadingIDs.remove(id)
            // The piece / mode may have changed while loading; re-validate.
            guard self.mode == .buy,
                  let box = self.furnitureEntities[id],
                  let model,
                  let dims = self.furnitureSnapshots[id]?.dimensions else { return }
            FurnitureEntityBuilder.attachRealisticModel(model, to: box, dimensions: dims, tint: tint)
            self.reapplyFurnitureState(for: id, on: box)   // box → transparent (red if invalid)
        }
    }

    /// Re-run the tint/visibility for one piece after its model visibility changed,
    /// using the last-synced state — editing pieces get the fit-state coloring,
    /// static pieces the plain retint.
    private func reapplyFurnitureState(for id: UUID, on box: Entity) {
        if editingFurniture {
            FurnitureEntityBuilder.applyPlacementState(
                lastFurnitureStates[id] ?? .valid,
                selected: id == lastSelectedFurnitureID,
                mode: mode,
                to: box
            )
        } else if let footprint = furnitureSnapshots[id] {
            FurnitureEntityBuilder.retint(box, footprint: footprint, mode: mode)
        }
    }

    // MARK: - Live drag-to-move (driven by native targeted gestures)

    /// Offset captured at grab: (box floor-center) − (floor point under the finger).
    /// Maintained through the drag so the piece keeps its position RELATIVE to the
    /// finger instead of snapping its center under the finger — which, on a tilted
    /// camera, made the box float above the fingertip.
    private var dragGrabOffset = SIMD2<Float>(0, 0)

    /// Begin moving `id`. `grabWorldXZ` is the world point the finger grabbed
    /// (from the native gesture's `convert(location3D)`); the offset to the box
    /// center is captured so the piece tracks the finger without snapping. A light
    /// tap confirms the grab.
    func beginFurnitureDrag(_ id: UUID, grabWorldXZ: SIMD2<Float>) {
        draggingFurnitureID = id
        lastDragState = nil
        if let footprint = currentFootprints.first(where: { $0.id == id }) {
            dragGrabOffset = SIMD2(footprint.worldPosition.x, footprint.worldPosition.z) - grabWorldXZ
        } else {
            dragGrabOffset = .zero
        }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    /// Move the dragging piece to `worldXZ` (the native gesture's unprojected floor
    /// point, in root/world space) plus the grab offset. Mutates the entity
    /// transform + tint directly for immediacy; final footprints are pushed up in
    /// `endFurnitureDrag`. Floor-anchor invariant: only X/Z change, never Y.
    func dragFurniture(toWorldXZ worldXZ: SIMD2<Float>) {
        guard let id = draggingFurnitureID,
              let room = editingRoom,
              let index = currentFootprints.firstIndex(where: { $0.id == id }) else { return }

        currentFootprints[index].worldPosition.x = worldXZ.x + dragGrabOffset.x
        currentFootprints[index].worldPosition.z = worldXZ.y + dragGrabOffset.y   // SIMD2.y carries world Z; altitude untouched
        let footprint = currentFootprints[index]

        let state = FurniturePlacementValidator.validate(
            footprint: footprint, against: room, existingFootprints: currentFootprints)

        if let entity = furnitureEntities[id] {
            entity.position = footprint.worldPosition
            FurnitureEntityBuilder.applyPlacementState(state, selected: true, mode: mode, to: entity)
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
            FurnitureEntityBuilder.applyPlacementState(state, selected: true, mode: mode, to: entity)
            // Keep a shown realistic model fit to the new size.
            if let visual = entity.findEntity(named: FurnitureEntityBuilder.realisticModelName) {
                FurnitureEntityBuilder.scaleRealisticModel(visual, to: footprint.dimensions)
            }
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

    // MARK: - Camera intents (driven by the SwiftUI gestures on RoomSceneView)
    //
    // `pan` is retained but currently unbound: SwiftUI has no clean two-finger-pan
    // gesture, so the camera exposes orbit + pinch-zoom. Re-wire `pan` if a
    // two-finger pan recognizer is added back.

    /// One-finger drag → orbit. `dx`/`dy` are incremental screen-point deltas.
    func orbit(dx: Float, dy: Float) {
        cameraAnim = nil
        azimuth -= dx * 0.008
        elevation = min(max(elevation - dy * 0.008, 0.06), .pi / 2 - 0.05)
        updateCamera()
    }

    // MARK: Continuous camera gestures (cumulative → incremental)
    //
    // SwiftUI hands the gesture's CUMULATIVE value each tick. We track the previous
    // value HERE — on this plain (non-observed) controller — and feed `orbit`/`pinch`
    // the per-tick delta, so the SwiftUI view's gesture closures never mutate `@State`.
    // Writing `@State` per tick would invalidate `body` ~60×/sec, re-running the
    // `RealityView` `update:` closure and rebuilding the gestures mid-touch — the
    // stall that drops camera movement to ~1 FPS.
    private var lastOrbitTranslation: CGSize = .zero
    private var lastZoomMagnification: CGFloat = 1

    /// Orbit from the drag gesture's cumulative translation.
    func orbitContinuous(translation: CGSize) {
        orbit(dx: Float(translation.width - lastOrbitTranslation.width),
              dy: Float(translation.height - lastOrbitTranslation.height))
        lastOrbitTranslation = translation
    }

    /// Zoom from the magnify gesture's cumulative magnification.
    func zoomContinuous(magnification: CGFloat) {
        guard lastZoomMagnification > 0 else { return }
        pinch(scale: Float(magnification / lastZoomMagnification))
        lastZoomMagnification = magnification
    }

    /// Reset the cumulative baselines when a camera gesture ends.
    func endOrbit() { lastOrbitTranslation = .zero }
    func endZoom() { lastZoomMagnification = 1 }

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
