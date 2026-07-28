import SwiftUI
import RealityKit
import UIKit
import simd
import os

/// Logs Verified-track product-model loading (the zero-scaling guard).
private let catalogModelLogger = Logger(subsystem: "com.helaly.Snug", category: "CatalogModel")

/// The Phase 1 diorama: a `RoomModel` rendered in RealityKit as an open-top
/// "dollhouse" with orbit/zoom camera and a soft grounding base.
///
/// The hard product rule lives here: **everything inside the room is
/// true-to-color under neutral lighting.** The room's surfaces, the furniture,
/// and the lights never stylize, warm, or lighten a color the user owns —
/// seeing your real colors together IS the product. The playful brand warmth
/// is confined to the frame around the room (the terracotta backdrop, the
/// platform base, the wall-cap rims). Dimension labels are an info overlay
/// toggled by `showsDimensions`, not a different rendering.
///
/// ## Migrated to `RealityView`
/// This was a `UIViewRepresentable` wrapping a `.nonAR` `ARView`. It is now a native
/// SwiftUI `RealityView`. Two ARView conveniences had no direct `RealityView`
/// equivalent and moved:
/// - **Snapshot** (`ARView.snapshot`) → `OffscreenSnapshotRenderer` (RealityKit's
///   `RealityRenderer`), used for the room's list thumbnail.
/// - **Background colour** (`ARView.environment.background`) → a SwiftUI
///   `Color(palette.background)` layer behind the `RealityView` in
///   `RoomDioramaScreen`.
struct RoomSceneView: View {
    let room: RoomModel
    /// Whether the blueprint-style dimension labels are shown (the "measurements"
    /// info overlay). Purely additive — flipping it never changes a material.
    var showsDimensions: Bool = false
    /// Incremented by the parent to request a spring camera reset.
    var resetToken: Int = 0
    /// Diorama (orbit) vs first-person walkthrough. Purely a camera-pose + gesture
    /// change — the scene geometry is identical in both.
    var perspective: CameraPerspective = .diorama
    /// The standing spot the walkthrough camera should occupy (ignored in
    /// `.diorama`). Changing it while inside glides to the new vantage.
    var activeVantage: WalkthroughVantage? = nil
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
    /// "Snap to wall" pick mode: when true, the floor is tappable and a tap reports
    /// its world floor point via `onPickWallPoint` (instead of selecting/deselecting).
    var isPickingWall: Bool = false
    /// Fires with the tapped floor point (world x, z) while `isPickingWall`.
    var onPickWallPoint: ((SIMD2<Float>) -> Void)? = nil
    /// Reports a sandbox clay piece's colorable parts once its model loads, so the
    /// selection UI can offer a per-part recolor chip row.
    var onSandboxParts: ((UUID, [FurnitureEntityBuilder.ColorablePart]) -> Void)? = nil
    /// Fires with a part key when the user taps a specific part of the already-selected
    /// clay piece, so the color row can target that part. Nil → no per-part tapping.
    var onSelectSandboxPart: ((String) -> Void)? = nil

    /// The scene/camera/culling engine. Held in `@State` so the single instance
    /// survives `body` re-evaluations (label toggle, reset) — `RealityView`'s `make`
    /// closure runs once against it; `update` drives it from external state.
    @State private var controller = RoomSceneController()

    // Native-gesture state. Camera gestures are cumulative in SwiftUI; that cumulative
    // tracking now lives on `RoomSceneController` (NOT `@State`), so orbit/zoom ticks
    // never invalidate `body`. Furniture-drag state decides move-vs-select per gesture.
    @State private var furnitureDragID: UUID?
    @State private var furnitureDragIsMove = false
    @State private var furnitureResizeActive = false
    @State private var furnitureRotateActive = false

    @Environment(\.displayScale) private var displayScale
    @Environment(CatalogService.self) private var catalog
    @Environment(SandboxLibrary.self) private var sandbox

    /// Maps a placed footprint's `catalogItemID` to its bundled USDZ asset name, so
    /// the controller can load the realistic product model without depending on
    /// `CatalogService` directly. Nil for non-catalog pieces / items with no
    /// bundled model (→ the controller keeps the identity box).
    private func catalogModelResolver() -> (String) -> String? {
        { [catalog] catalogID in
            catalog.items.first { $0.id == catalogID }?.modelAssetName
        }
    }

    /// Maps a footprint's `sandboxAssetID` to its bundled generic USDZ — the
    /// elastic "digital clay" shape, stretched freely.
    private func sandboxModelResolver() -> (String) -> String? {
        { [sandbox] sandboxID in
            sandbox.assets.first { $0.id == sandboxID }?.modelAssetName
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
                controller.sandboxModelAssetName = sandboxModelResolver()
                controller.onSandboxParts = onSandboxParts
                controller.makeEntities(room: room, editingFurniture: editableFurniture != nil, onThumbnail: onThumbnail)
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
                controller.sandboxModelAssetName = sandboxModelResolver()
                controller.onSandboxParts = onSandboxParts
                controller.setWallPicking(isPickingWall)
                controller.setSurfaceStyle(room.surfaceStyle)
                controller.applyExternalState(showsDimensions: showsDimensions, resetToken: resetToken,
                                              perspective: perspective, vantage: activeVantage)
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
            .gesture(furniturePinchTwistGesture)
            .gesture(deselectTapGesture)
            .simultaneousGesture(cameraOrbitGesture)
            .simultaneousGesture(cameraZoomGesture)
            .onChange(of: geo.size) { syncPixelSize(geo.size) }
            .onChange(of: displayScale) { syncPixelSize(geo.size) }
            .onAppear { syncPixelSize(geo.size) }
            // Release the live RealityKit render context the instant we navigate
            // away, so it never contends with the capture ARView's session on the
            // next scan (the black-passthrough-every-other-scan bug). See
            // `RoomSceneController.teardown()`.
            .onDisappear { controller.teardown() }
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
            // Walkthrough is a preview, not an editor: no selecting/moving from inside.
            guard perspective == .diorama else { return }
            // "Snap to wall" pick mode: a tap (on the now-tappable floor or any piece)
            // reports its world floor point so the host can snap to the nearest wall.
            if isPickingWall {
                if let hit = value.unproject(value.location, from: .local,
                                             to: value.entity.parent ?? value.entity,
                                             ontoPlane: Self.horizontalPlane(atHeight: 0)) {
                    onPickWallPoint?(SIMD2(hit.x, hit.z))
                }
                return
            }
            if let (_, id) = taggedFurnitureRoot(for: value.entity) {
                // Tapping a part of the ALREADY-selected clay piece targets that part
                // for recoloring (instead of a no-op re-select). The tap resolved to
                // the box; we raycast the camera ray against the part colliders to find
                // which part. First tap selects the piece; a second tap picks a part.
                if id == selectedFurnitureID, onSelectSandboxPart != nil,
                   let through = value.unproject(value.location, from: .local, to: controller.root,
                                                 ontoPlane: Self.horizontalPlane(atHeight: 0)),
                   let partKey = controller.sandboxPartKey(forTapThrough: through, pieceID: id) {
                    onSelectSandboxPart?(partKey)
                    return
                }
                onSelectFurniture?(id)
            } else {
                // Tapped the (tappable-in-pick-mode) floor outside pick mode → deselect.
                onSelectFurniture?(nil)
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
                guard perspective == .diorama else { return }
                guard let (root, id) = taggedFurnitureRoot(for: value.entity),
                      let parent = root.parent else { return }
                let floorPlane = Self.horizontalPlane(atHeight: root.position.y)

                if furnitureDragID != id {
                    furnitureDragID = id

                    if id == selectedFurnitureID {
                        furnitureDragIsMove = true

                        // Anchor the grab at the finger's CURRENT location, not
                        // `startLocation`. DragGesture's ~10pt minimumDistance deadzone
                        // means the finger has already traveled before this first tick
                        // fires; anchoring at startLocation would make the piece lurch
                        // by that gap on frame one (the "initial hard push"). Using the
                        // same point we feed to `dragFurniture` below yields zero jump.
                        if let grab = value.unproject(value.location, from: .local,
                                                      to: parent, ontoPlane: floorPlane) {
                            controller.beginFurnitureDrag(id, grabWorldXZ: SIMD2(grab.x, grab.z))
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

    /// Two-finger pinch-AND-twist on the selected furniture entity: resize
    /// (width/depth, height fixed) and rotate about the vertical (yaw) AT ONCE —
    /// the standard iOS pinch-and-twist combo.
    ///
    /// `MagnifyGesture` and `RotateGesture` are composed with `.simultaneously(with:)`
    /// so SwiftUI recognizes BOTH from the same two-finger touch. Attaching them as
    /// two separate `.gesture()` modifiers (the previous shape) made them arbitrate
    /// exclusively — only one would ever win, so resize and rotate could never run
    /// together and twist-to-rotate was effectively unreachable once the pinch
    /// recognizer claimed the touches. As one composed gesture it stays mutually
    /// exclusive with the one-finger drag and is gated against the camera
    /// orbit/zoom `.simultaneousGesture`s via the `furnitureResizeActive` /
    /// `furnitureRotateActive` flags. The accessible path is the Fine Tune sheet's
    /// resize/rotate controls (VoiceOver users can't pinch-twist).
    private var furniturePinchTwistGesture: some Gesture {
        MagnifyGesture().targetedToAnyEntity()
            .simultaneously(with: RotateGesture().targetedToAnyEntity())
            .onChanged { value in
                guard perspective == .diorama else { return }
                // Either sub-gesture may be the one that fired this frame; both
                // carry the same targeted entity.
                guard let entity = value.first?.entity ?? value.second?.entity,
                      let (_, id) = taggedFurnitureRoot(for: entity),
                      id == selectedFurnitureID else { return }
                if let magnify = value.first {
                    if !furnitureResizeActive { controller.beginFurnitureResize(id); furnitureResizeActive = true }
                    controller.resizeFurniture(scale: Float(magnify.magnification))
                }
                if let rotate = value.second {
                    if !furnitureRotateActive { controller.beginFurnitureRotation(id); furnitureRotateActive = true }
                    controller.rotateFurniture(by: Float(rotate.rotation.radians))
                }
            }
            .onEnded { _ in
                if furnitureResizeActive {
                    onFurnitureChanged?(controller.endFurnitureResize())
                    furnitureResizeActive = false
                }
                if furnitureRotateActive {
                    onFurnitureChanged?(controller.endFurnitureRotation())
                    furnitureRotateActive = false
                }
            }
    }

    /// Tap on empty space → deselect. (Fires only when no entity tap consumed it.)
    private var deselectTapGesture: some Gesture {
        TapGesture().onEnded {
            guard perspective == .diorama else { return }
            onSelectFurniture?(nil)
        }
    }

    /// One-finger drag. In `.diorama` it orbits the camera; in `.walkthrough` it is
    /// the look-around (yaw/pitch of the eye-level view). Either way the controller
    /// tracks the cumulative translation and feeds itself incremental deltas, so this
    /// closure never writes `@State` (which would invalidate `body` every frame and
    /// stall the gesture).
    private var cameraOrbitGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                if perspective == .walkthrough {
                    controller.lookAroundContinuous(translation: value.translation)
                    return
                }
                // Gate: a furniture drag (targeted gesture) sets `furnitureDragID` on
                // its first tick; once set, this simultaneous orbit no-ops so dragging
                // a piece doesn't also spin the camera. Empty-space drags never set it.
                guard furnitureDragID == nil else { return }
                controller.orbitContinuous(translation: value.translation)
            }
            .onEnded { _ in
                if perspective == .walkthrough { controller.endLook() } else { controller.endOrbit() }
            }
    }

    /// Pinch → zoom. In the diorama it dollies the camera; in the walkthrough it
    /// changes the eye-level FOV (the controller branches on perspective). Cumulative
    /// magnification is converted to the incremental factor inside the controller.
    private var cameraZoomGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                // Gate: a pinch/twist on the selected piece sets `furnitureResizeActive`
                // / `furnitureRotateActive`; while either is active this simultaneous
                // zoom no-ops so manipulating furniture doesn't also zoom the camera.
                // (Both flags stay false in walkthrough, where furniture isn't editable.)
                guard !furnitureResizeActive, !furnitureRotateActive else { return }
                controller.zoomContinuous(magnification: value.magnification)
            }
            .onEnded { _ in controller.endZoom() }
    }

}

/// Owns the RealityKit scene, camera rig, gesture math, materials, dollhouse
/// wall culling, and the thumbnail snapshot for one `RoomSceneView`. A plain
/// reference type driven by the SwiftUI view; not `@Observable` — nothing in it
/// is observed, the view pushes state in through `applyExternalState` and friends.
@MainActor
final class RoomSceneController {

    // MARK: Scene
    /// Scene root; added to `RealityViewContent` by the view. Holds geometry and
    /// lights.
    let root = AnchorEntity(world: .zero)
    /// Camera root; added to content separately so root transforms can never bleed
    /// into the camera pose.
    let cameraAnchor = AnchorEntity(world: .zero)
    private let camera = Entity()
    private let keyLight = DirectionalLight()
    private let fillA = DirectionalLight()
    private let fillB = DirectionalLight()

    private var floorEntity: ModelEntity?
    private var baseEntity: ModelEntity?
    /// Soft drop shadow grounding the floating room cube against the solid void
    /// backdrop. A baked contact-shadow plane tucked under the base (frame, not
    /// room — it never darkens an in-room surface).
    private var dropShadow: ModelEntity?

    /// One wall edge and the chunky white `cap` rim that must hide together with
    /// it when the wall is culled (the open-dollhouse look). `midXZ`/`outwardXZ`
    /// drive culling.
    private struct WallNode {
        let entity: ModelEntity
        let cap: ModelEntity?
        let midXZ: SIMD2<Float>
        let outwardXZ: SIMD2<Float>
    }
    private var walls: [WallNode] = []
    /// Styled openings: a container holding a trim frame + an inner pane (glass /
    /// door panel) + mullions/rails. `entity` is the container (toggled by
    /// culling); `pane` is the palette-driven inner surface; `trims` are the
    /// frame/mullion bars; `wallIndex` ties it to its wall so culling stays in sync.
    private var openings: [(entity: Entity, pane: ModelEntity, trims: [ModelEntity], wallIndex: Int)] = []
    /// Dimension labels (lie flat on the floor like a blueprint), shown only
    /// while the measurements overlay is on.
    private var labels: [ModelEntity] = []

    // MARK: Phase 2 furniture (separate keyed store — never mixed into the
    // wall/floor/opening scene building). In editing mode these are driven live
    // by the placement tray via `syncFurniture`; in viewing mode `buildGeometry`
    // adds them once, statically.
    private var furnitureEntities: [UUID: Entity] = [:]
    /// Last-synced footprint per id, so `syncFurniture` only rebuilds an entity
    /// when its geometry actually changed (cheap re-tints otherwise).
    private var furnitureSnapshots: [UUID: FurnitureFootprint] = [:]
    /// Last-synced placement state + selection (editing mode), so a model
    /// attach/detach can re-apply the fit-state coloring without waiting for a
    /// SwiftUI round-trip.
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
    /// with no model → the identity box is kept.
    var catalogModelAssetName: ((String) -> String?)?
    /// Resolves a footprint's `sandboxAssetID` to its bundled generic USDZ (the
    /// elastic "digital clay" shape), stretched freely.
    var sandboxModelAssetName: ((String) -> String?)?
    /// Footprint ids whose product model is currently loading, so a re-sync doesn't
    /// kick off a duplicate async load.
    private var modelLoadingIDs: Set<UUID> = []
    /// The per-part tint currently baked into each piece's sandbox clay model, keyed
    /// by part name. Absent/empty = the model's original library materials. Lets a
    /// re-sync detect which parts changed (re-tint in place) or were reset to original
    /// (reload a fresh clone, since a flattened material can't be un-tinted).
    private var modelPartColors: [UUID: [String: SIMD3<Float>]] = [:]
    /// Reports the colorable parts of a sandbox clay model once it loads, so the
    /// selection UI can offer a per-part chip row. Keyed by footprint id.
    var onSandboxParts: ((UUID, [FurnitureEntityBuilder.ColorablePart]) -> Void)?

    /// A solid `UIColor` from an sRGB triple (0–1) — for tinting sandbox clay.
    private static func uiColor(_ rgb: SIMD3<Float>) -> UIColor {
        UIColor(red: CGFloat(rgb.x), green: CGFloat(rgb.y), blue: CGFloat(rgb.z), alpha: 1)
    }

    /// The per-part color map to bake into a sandbox piece's clay model. Prefers the
    /// explicit `partColors`; falls back to the legacy whole-piece `exactColorRGB`
    /// (applied to every discovered part) so pre-per-part rooms still render tinted.
    /// `[:]` means fully original.
    private func sandboxDesiredColors(
        _ footprint: FurnitureFootprint, model: Entity
    ) -> [String: SIMD3<Float>] {
        guard footprint.sandboxAssetID != nil else { return [:] }
        if let parts = footprint.appearance.partColors, !parts.isEmpty { return parts }
        if let rgb = footprint.appearance.exactColorRGB {
            var map: [String: SIMD3<Float>] = [:]
            for part in FurnitureEntityBuilder.colorableParts(of: model) { map[part.key] = rgb }
            return map
        }
        return [:]
    }

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
    /// gestures; on-screen scale is only mildly affected at this FOV (labels
    /// still show true measurements). Also drives initial framing in `frameCamera`.
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

    // MARK: Walkthrough (first-person) camera state
    //
    // Orthogonal to the orbital rig above: while `perspective == .walkthrough` the
    // camera sits at `walkPositionXZ`/`walkEyeHeight` and looks along
    // `lookYaw`/`lookPitch` (see `updateWalkthroughCamera`). The orbital fields
    // (azimuth/elevation/radius/target) are left untouched so `exitToDiorama` snaps
    // straight back to the iso framing the user left.

    /// Default human-eye FOV on entering the walkthrough. A WIDE lens is what makes
    /// a room feel spacious in first person — more peripheral vision, walls read as
    /// further away — vs the narrow near-iso diorama lens (which felt cramped). The
    /// two-finger pinch adjusts it live within `walkFOVRange` (spread = zoom in /
    /// narrower; pinch together = wider / more room around you).
    static let walkthroughDefaultFOV: Float = 78
    static let walkFOVRange: ClosedRange<Float> = 55...100

    private(set) var perspective: CameraPerspective = .diorama
    /// Current walkthrough FOV in degrees, mutated by the pinch gesture; reset to
    /// the default each time you step inside.
    private var walkFOV = RoomSceneController.walkthroughDefaultFOV
    /// The vantage the walkthrough camera currently occupies, so a re-sync with the
    /// same vantage is a no-op and a changed one glides.
    private var currentVantageID: String?
    private var walkPositionXZ = SIMD2<Float>.zero
    private var walkEyeHeight = WalkthroughVantage.standingEyeHeight
    /// Horizontal look angle: forward on XZ is `(sin, cos)`, matching `WalkthroughVantage`.
    private var lookYaw: Float = 0
    /// Vertical look angle (radians): +up, clamped so you never stare into the
    /// open-top "void" above the walls, nor past straight-down at the floor.
    private var lookPitch: Float = 0

    /// In-flight glide between vantages (position + look), advanced by the update loop.
    private struct WalkAnim {
        var elapsed: TimeInterval = 0
        let duration: TimeInterval
        let fromPos, toPos: SIMD2<Float>
        let fromYaw, toYaw, fromPitch, toPitch, fromEye, toEye: Float
    }
    private var walkAnim: WalkAnim?
    private var lastLookTranslation: CGSize = .zero

    // MARK: Misc
    /// The room's chosen wall/floor colors, overlaid on the palette by
    /// `applyPalette`. Set from the room in `makeEntities`; live changes arrive
    /// via `setSurfaceStyle` (materials only — geometry never moves).
    private var surfaceStyle: RoomSurfaceStyle = .unset
    /// Whether the blueprint dimension labels are currently shown (the
    /// measurements info overlay, driven by the view).
    private var showsDimensions = false

    var lastResetToken = 0
    var onThumbnail: ((Data) -> Void)?
    private var didSnapshot = false
    private var frameCount = 0
    /// Frames elapsed since the last pending realistic-model load finished. The
    /// thumbnail waits a few of these so freshly-attached models render into a frame
    /// before the offscreen snapshot, instead of capturing the stylized boxes.
    private var framesSinceModelsLoaded = 0
    /// Retained per-frame subscription (set by the view from `RealityViewContent`).
    var updateSub: EventSubscription?
    /// The view's drawable size in PIXELS (points × display scale), kept current by
    /// the view; the offscreen snapshot renders at this resolution.
    var pixelSize: CGSize = .zero

    // MARK: - Teardown

    /// Deterministically release the diorama's live RealityKit render context when
    /// the view navigates away, instead of leaving it to lazy `@State` dealloc.
    ///
    /// This is load-bearing for the AR capture flow: on iOS 26 a still-live
    /// `RealityView` render context contends with the capture `ARView`'s session,
    /// wedging the camera passthrough black on the NEXT scan (it toggled live↔black
    /// every other scan — view a room, scan, black; view a room, scan, fine). Tearing
    /// the diorama's per-frame loop and scene anchors down here, the moment we leave,
    /// means no diorama renderer is alive when capture re-opens. Idempotent.
    func teardown() {
        updateSub?.cancel()
        updateSub = nil
        root.children.removeAll()
        cameraAnchor.children.removeAll()
        root.removeFromParent()
        cameraAnchor.removeFromParent()
    }

    // MARK: - Setup

    /// Build all scene entities (geometry, lights, camera). The view adds `root` and
    /// `cameraAnchor` to its `RealityViewContent` and wires the per-frame loop.
    func makeEntities(room: RoomModel, editingFurniture: Bool = false, onThumbnail: ((Data) -> Void)?) {
        self.editingFurniture = editingFurniture
        self.editingRoom = room
        self.surfaceStyle = room.surfaceStyle
        self.onThumbnail = onThumbnail

        buildLights()
        root.addChild(keyLight)
        root.addChild(fillA)
        root.addChild(fillB)
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
        applyPalette()
        updateCamera()
    }

    private func buildLights() {
        // Neutral key from top-right, fills from the left and back. RealityKit
        // has no dedicated ambient-light entity (still true on iOS 26), so this
        // back/fill pair stands in for the ambient wrap. All white on purpose:
        // a tinted light would shift every perceived color in the room, breaking
        // the true-color promise. Directional lights use only their direction,
        // so aiming at the origin is correct even when the room isn't centered
        // there. Tints/intensities are set in `applyPalette`.
        keyLight.look(at: .zero, from: [2.5, 4.0, 2.5], relativeTo: nil)
        fillA.look(at: .zero, from: [-3.0, 2.0, -1.0], relativeTo: nil)
        fillB.look(at: .zero, from: [0.4, 1.4, -2.2], relativeTo: nil)
    }

    // MARK: - Geometry

    private func buildGeometry(room: RoomModel) {
        let corners = room.floorCorners.map(\.simd2)
        guard corners.count >= 3 else { return }
        centroidXZ = corners.reduce(.zero, +) / Float(corners.count)
        let height = room.ceilingHeight

        // Grounding base: a chunky rounded platform under the room so the diorama
        // reads as a solid floating model. Its soft drop shadow lands on the
        // void backdrop just below it.
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
        }

        // Walls: chunky full-height slabs, one per polygon edge, each topped by a
        // white cap rim (frame detailing — it sits above the wall, never on it).
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

            // Outward XZ normal (away from the room centroid).
            var outward = SIMD2<Float>(dir.y, -dir.x)
            if simd_dot(outward, mid - centroidXZ) < 0 { outward = -outward }
            outward = simd_normalize(outward)

            // `floorCorners` is where the floor meets the wall — the wall's INNER
            // face, and the exact line FitService measures clearance against. So the
            // slab is pushed fully OUTWARD by half its depth, putting its inner face
            // on the polygon line instead of straddling it. A centered slab used to
            // intrude `wallDepth/2` (4 cm) into the interior, so a piece reported as
            // "Fits" (5 cm clear of the line) sat only ~1 cm off the visible wall and
            // read as grazing/inside it. Now the visible interior == the fit
            // reference, so the badge matches what's on screen.
            let outwardShift = outward * (wallDepth / 2)
            let slabMid = mid + outwardShift

            let mesh = MeshResource.generateBox(width: length, height: height, depth: wallDepth)
            let entity = ModelEntity(mesh: mesh, materials: [placeholderMaterial()])
            entity.position = SIMD3(slabMid.x, height / 2, slabMid.y)
            entity.orientation = orientation
            root.addChild(entity)

            // Chunky white cap rim, proud of the wall on every edge so the slab
            // reads as a molded model piece. Material set in `applyPalette`.
            let capMesh = MeshResource.generateBox(size: [length + 0.04, capHeight, wallDepth + 0.05],
                                                   cornerRadius: 0.02)
            let cap = ModelEntity(mesh: capMesh, materials: [placeholderMaterial()])
            cap.position = SIMD3(slabMid.x, height + capHeight / 2 - 0.005, slabMid.y)
            cap.orientation = orientation
            root.addChild(cap)

            walls.append(WallNode(entity: entity, cap: cap, midXZ: mid, outwardXZ: outward))
        }

        // Openings: proud panels on the inner face of their nearest wall.
        for opening in room.openings {
            guard let panel = makeOpening(opening, walls: room.walls, ceiling: height) else { continue }
            root.addChild(panel.entity)
            openings.append((panel.entity, panel.pane, panel.trims, panel.wallIndex))
        }

        // Dimension labels (shown while the measurements overlay is on): wall
        // length, laid flat near each wall's midpoint like a floor-plan annotation.
        for wall in room.walls {
            guard let label = makeDimensionLabel(for: wall) else { continue }
            label.isEnabled = false
            labels.append(label)
            root.addChild(label)
        }

        // Phase 2: detected existing furniture, rendered as true-color identity
        // boxes (collision + tap-target tagged) so it appears in the diorama. Y is
        // floor-relative (the box center is half its height above this y=0 floor),
        // so it sits ON the floor regardless of the AR session's altitude. In
        // editing mode this static pass is skipped — `syncFurniture` (driven by the
        // placement tray) owns the entities so they can update live.
        if !editingFurniture {
            for footprint in room.detectedFurniture where !footprint.isCleared {
                let entity = FurnitureEntityBuilder.entity(for: footprint)
                root.addChild(entity)
                furnitureEntities[footprint.id] = entity
                furnitureSnapshots[footprint.id] = footprint
            }
        }
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

    /// A soft baked drop shadow grounding the floating cube on the void backdrop.
    /// A horizontal contact-shadow plane, larger than the base and tucked just
    /// beneath it, so from the isometric angle it reads as a soft blob under the
    /// model rather than a hard cast shadow. Frame detailing — it darkens the
    /// backdrop, never an in-room surface.
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
    /// one rather than a flat colored slab: a trim frame around the perimeter,
    /// a recessed inner pane (returned so the palette can drive it), and
    /// kind-specific dividers (a cross mullion for
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
        // them via the returned list.
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

    /// Apply the single truthful palette (with the room's chosen surface colors
    /// overlaid) to every surface, plus the fixed neutral lighting rig. Materials
    /// only — no geometry is touched, so it's safe to re-run on a live surface
    /// change.
    private func applyPalette() {
        let palette = RoomPalette.palette(style: surfaceStyle)

        // One shared material instance per surface (don't allocate per entity).
        let floorMat = RoomMaterials.floor(palette)
        let wallMat = RoomMaterials.wall(palette)
        let openingMat = RoomMaterials.opening(palette)
        let trimMat = RoomMaterials.openingTrim(palette)
        let baseMat = RoomMaterials.base(palette)
        let capMat = RoomMaterials.wallCap(palette)

        setMaterial(floorMat, on: floorEntity)
        setMaterial(baseMat, on: baseEntity)
        for wall in walls {
            setMaterial(wallMat, on: wall.entity)
            setMaterial(capMat, on: wall.cap)
        }
        for opening in openings {
            setMaterial(openingMat, on: opening.pane)
            for trim in opening.trims { setMaterial(trimMat, on: trim) }
        }

        // Neutral lighting — white tints so no perceived color ever shifts.
        keyLight.light.color = palette.keyTint
        keyLight.light.intensity = palette.keyIntensity
        fillA.light.color = palette.fillTint
        fillA.light.intensity = palette.fillIntensity
        fillB.light.color = palette.backTint
        fillB.light.intensity = palette.backIntensity

        // Soft cast shadow from the key light. Shadows are honest (they change
        // luminance where an object blocks light, not hue); a large
        // maximumDistance + depth bias keeps it gentle rather than hard-edged.
        keyLight.shadow = DirectionalLightComponent.Shadow(maximumDistance: 8, depthBias: 2.0)
    }

    private func setMaterial(_ material: any RealityKit.Material, on entity: ModelEntity?) {
        guard let entity, var model = entity.model else { return }
        model.materials = [material]
        entity.model = model
    }

    // MARK: - Snapshot

    /// Render the current scene offscreen into a `UIImage`, composited over the
    /// backdrop colour. Clones the live scene + camera (the renderer must not be
    /// handed live, parented entities).
    private func captureSnapshot(pixelSize: CGSize) async -> UIImage? {
        let sceneClone = root.clone(recursive: true)
        let cameraClone = camera.clone(recursive: false)
        cameraClone.transform = Transform(matrix: camera.transformMatrix(relativeTo: nil))

        guard let raw = await OffscreenSnapshotRenderer.image(
            scene: sceneClone, camera: cameraClone, pixelSize: pixelSize) else { return nil }
        return Self.composite(raw, over: RoomPalette.palette(style: surfaceStyle).background)
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

    func applyExternalState(showsDimensions: Bool, resetToken: Int,
                            perspective newPerspective: CameraPerspective, vantage: WalkthroughVantage?) {
        if self.showsDimensions != showsDimensions {
            self.showsDimensions = showsDimensions
            // Purely additive info overlay — label visibility only, never a material.
            for label in labels { label.isEnabled = showsDimensions }
        }

        // Perspective transitions. Enter/exit set `perspective`, so the reset-token
        // block below sees the up-to-date value.
        if perspective != newPerspective {
            if newPerspective == .walkthrough {
                if let vantage { enterWalkthrough(vantage) }
            } else {
                exitToDiorama()
            }
        } else if newPerspective == .walkthrough, let vantage, vantage.id != currentVantageID {
            moveToVantage(vantage, animated: true)
        }

        if lastResetToken != resetToken {
            lastResetToken = resetToken
            if perspective == .walkthrough, let vantage {
                // "Reset view" while inside re-aims at the current vantage (recenters
                // the look) rather than framing the whole room.
                moveToVantage(vantage, animated: true)
            } else {
                resetCamera(animated: true)
            }
        }
    }

    // MARK: - Walkthrough (first-person) camera

    /// Drop into first-person at `vantage`: eye height, wide FOV, look aimed as the
    /// vantage specifies. Widening the FOV only mutates the existing
    /// `PerspectiveCameraComponent`, so it stays perspective (and gesture hit-testing
    /// stays valid); `exitToDiorama` restores the narrow iso lens.
    func enterWalkthrough(_ vantage: WalkthroughVantage) {
        perspective = .walkthrough
        currentVantageID = vantage.id
        cameraAnim = nil
        walkAnim = nil
        walkPositionXZ = vantage.position
        walkEyeHeight = vantage.eyeHeight
        lookYaw = vantage.initialYaw
        lookPitch = 0
        walkFOV = Self.walkthroughDefaultFOV
        setCameraFOV(walkFOV)
        updateWalkthroughCamera()
    }

    /// Glide (or snap) to another preset vantage while staying inside.
    func moveToVantage(_ vantage: WalkthroughVantage, animated: Bool) {
        currentVantageID = vantage.id
        if animated {
            // Glide the short way around: the drag-accumulated `lookYaw` is
            // unbounded, so a raw lerp to the vantage's atan2 yaw can whip the
            // camera through full extra turns. Wrap the delta to [-π, π].
            var yawDelta = (vantage.initialYaw - lookYaw).truncatingRemainder(dividingBy: 2 * .pi)
            if yawDelta > .pi { yawDelta -= 2 * .pi }
            if yawDelta < -.pi { yawDelta += 2 * .pi }
            walkAnim = WalkAnim(
                duration: 0.5,
                fromPos: walkPositionXZ, toPos: vantage.position,
                fromYaw: lookYaw, toYaw: lookYaw + yawDelta,
                fromPitch: lookPitch, toPitch: 0,
                fromEye: walkEyeHeight, toEye: vantage.eyeHeight)
        } else {
            walkPositionXZ = vantage.position
            walkEyeHeight = vantage.eyeHeight
            lookYaw = vantage.initialYaw
            lookPitch = 0
            updateWalkthroughCamera()
        }
    }

    /// Step back out to the isometric diorama, springing to the canonical iso
    /// framing (the `default*` fields set once in `frameCamera`) via `resetCamera`
    /// — a clean overhead view, NOT whatever orbit the user last had. The orbital
    /// fields are left untouched while inside, so a future "resume last orbit"
    /// would only need to swap `resetCamera` for a spring toward the live values.
    func exitToDiorama() {
        perspective = .diorama
        currentVantageID = nil
        walkAnim = nil
        setCameraFOV(Self.isoFOVDegrees)
        resetCamera(animated: true)
    }

    /// One-finger look-around: incremental screen-point deltas turn the head. Pitch
    /// is clamped so the open-top void above the walls and the floor underfoot stay
    /// out of frame. Uses the "grab the world" sign convention (drag down → look up).
    func lookAround(dx: Float, dy: Float) {
        walkAnim = nil
        lookYaw -= dx * 0.005
        lookPitch = min(max(lookPitch + dy * 0.005, -1.0), 0.45)
        updateWalkthroughCamera()
    }

    /// Look-around from the drag gesture's cumulative translation (cumulative →
    /// incremental, like `orbitContinuous`, so the view never writes `@State` per tick).
    func lookAroundContinuous(translation: CGSize) {
        lookAround(dx: Float(translation.width - lastLookTranslation.width),
                   dy: Float(translation.height - lastLookTranslation.height))
        lastLookTranslation = translation
    }

    func endLook() { lastLookTranslation = .zero }

    /// Point the camera from the eye position along the current yaw/pitch.
    private func updateWalkthroughCamera() {
        let pos = SIMD3<Float>(walkPositionXZ.x, walkEyeHeight, walkPositionXZ.y)
        let cosP = cosf(lookPitch)
        let forward = SIMD3<Float>(sinf(lookYaw) * cosP, sinf(lookPitch), cosf(lookYaw) * cosP)
        camera.look(at: pos + forward, from: pos, relativeTo: nil)
    }

    /// Change the FOV of the existing perspective camera in place (never swaps the
    /// component type — that's what re-broke gesture hit-testing historically).
    private func setCameraFOV(_ degrees: Float) {
        guard var cam = camera.components[PerspectiveCameraComponent.self] else { return }
        cam.fieldOfViewInDegrees = degrees
        camera.components.set(cam)
    }

    /// Apply a changed wall/floor choice live (the surfaces sheet is open over the
    /// diorama, so the pick previews instantly). Materials only — no geometry.
    func setSurfaceStyle(_ style: RoomSurfaceStyle) {
        guard style != surfaceStyle else { return }
        surfaceStyle = style
        applyPalette()
    }

    /// Reconcile the live furniture entities with the placement tray's footprints
    /// (editing mode only). Adds new pieces, removes cleared/deleted ones, rebuilds
    /// an entity only when its geometry changed (position/size/rotation), and
    /// re-tints each by its `PlacementState`. Keyed by `footprint.id` in a store
    /// separate from the wall/floor scene building.
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
            modelPartColors[id] = nil
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
                updateRealisticModel(for: footprint, on: entity)
            }
        }
    }

    // MARK: - Realistic model (Verified products) + Sandbox clay

    /// Show a USDZ model over the identity box, or restore the box. Two model
    /// tracks share this one path:
    /// - **Sandbox** ("digital clay"): a generic USDZ, per-axis stretched to the
    ///   sketch's size — distortion is the *feature*, so it skips the Verified
    ///   zero-scaling guard and renders a uniform clay tone so it never reads as
    ///   a real product.
    /// - **Verified product**: a real USDZ, placed 1:1 behind the guard,
    ///   keeping its own materials.
    /// The USDZ loads asynchronously; the box shows until it arrives, then its mesh
    /// is hidden beneath the model. Visual only — collision/fit/gestures stay on the box.
    private func updateRealisticModel(for footprint: FurnitureFootprint, on box: Entity) {
        let isSandbox = footprint.sandboxAssetID != nil
        let assetName: String? = isSandbox
            ? footprint.sandboxAssetID.flatMap { sandboxModelAssetName?($0) }
            : footprint.catalogItemID.flatMap { catalogModelAssetName?($0) }

        guard let assetName else {
            // Non-catalog piece / no bundled model → ensure the box shows.
            if FurnitureEntityBuilder.hasRealisticModel(box) {
                FurnitureEntityBuilder.removeRealisticModel(from: box)
                reapplyFurnitureState(for: footprint.id, on: box)
            }
            return
        }

        if FurnitureEntityBuilder.hasRealisticModel(box),
           let model = FurnitureEntityBuilder.realisticModelChild(of: box) {
            let baked = modelPartColors[footprint.id] ?? [:]
            let desired = isSandbox ? sandboxDesiredColors(footprint, model: model) : [:]
            // A part reset to its ORIGINAL color can't be un-tinted in place (the
            // flat tint overwrote the library material) → reload a fresh clone. That
            // is exactly when a previously-baked part key is no longer desired.
            let needsReload = isSandbox && !Set(baked.keys).isSubset(of: Set(desired.keys))
            if !needsReload {
                // Keep it fit to the current dimensions (covers resize)…
                FurnitureEntityBuilder.scaleRealisticModel(model, to: footprint.dimensions)
                // …and re-tint only the parts whose color was added or changed
                // (in place, no reload — smooth for a live swatch/wheel drag).
                if isSandbox {
                    for (key, rgb) in desired where baked[key] != rgb {
                        FurnitureEntityBuilder.applyPartColor(Self.uiColor(rgb), toPart: key, in: model)
                    }
                    modelPartColors[footprint.id] = desired
                }
                return
            }
            // Falls through to reload the original-colored model. Restore the box
            // mesh now (it was hidden under the tinted model) so the piece stays
            // visible as the identity box during the async reload, instead of
            // flashing invisible until the fresh model attaches.
            FurnitureEntityBuilder.removeRealisticModel(from: box)
            modelPartColors[footprint.id] = nil
            reapplyFurnitureState(for: footprint.id, on: box)
        }

        guard !modelLoadingIDs.contains(footprint.id) else { return }
        modelLoadingIDs.insert(footprint.id)
        let id = footprint.id
        Task { [weak self] in
            let model = await CatalogModelLoader.shared.model(named: assetName)
            guard let self else { return }
            self.modelLoadingIDs.remove(id)
            guard let box = self.furnitureEntities[id],
                  let model,
                  let dims = self.furnitureSnapshots[id]?.dimensions else { return }

            if isSandbox {
                // The piece may have been swapped to a real product while loading.
                guard let snapshot = self.furnitureSnapshots[id],
                      snapshot.sandboxAssetID != nil else { return }
                // Elastic clay: NO zero-scaling guard (per-axis stretch is intended).
                // Attach with the model's ORIGINAL library materials, then flatten
                // only the parts the user has recolored — others stay original, so a
                // clay bed reads frame/mattress/pillow as distinct colors like the asset.
                FurnitureEntityBuilder.attachRealisticModel(model, to: box, dimensions: dims, tint: nil)
                let desired = self.sandboxDesiredColors(snapshot, model: model)
                if !desired.isEmpty { FurnitureEntityBuilder.applyPartColors(desired, to: model) }
                self.modelPartColors[id] = desired
                // Publish the model's parts so the selection UI can offer per-part chips.
                // (Tap-to-pick uses exact ray/triangle testing — no colliders needed.)
                self.onSandboxParts?(id, FurnitureEntityBuilder.colorableParts(of: model))
                self.reapplyFurnitureState(for: id, on: box)
                return
            }

            // Approximate product mesh (photo-generated Tripo / category archetype):
            // not authored at true scale, so the Verified 1:1 guard below would
            // always refuse it. Instead the footprint (w×d) is locked exactly to the
            // catalog dims and height is 1:1 unless the mesh carries photo clutter on
            // top (then it renders taller, never squashed — see
            // CatalogModelLoader.approximateFitTransform). The fit/collision box
            // keeps the true catalog dims either way, so the honest-fit promise is
            // untouched; only the visual is approximate.
            if CatalogModelLoader.isApproximateAsset(assetName) {
                FurnitureEntityBuilder.attachRealisticModel(
                    model, to: box, dimensions: dims, tint: nil, approximate: true)
                self.reapplyFurnitureState(for: id, on: box)
                return
            }

            // Verified-track zero-scaling guard: a real product USDZ must already be
            // authored at its true catalog size (placed 1:1, never warped). Measure
            // its native extents and refuse anything off by > 1 cm — fall back to the
            // honest box rather than let fitTransform silently squash/stretch a
            // mis-authored asset. Logs loudly (Console error, all builds) and recovers
            // to the box — deliberately NOT assertionFailure, which would trap every
            // DEBUG/QA build the moment a real product deviates and make the documented
            // box fallback unreachable off-release.
            let extents = FurnitureEntityBuilder.nativeExtents(of: model)
            let deviation = CatalogModelLoader.nativeSizeDeviation(
                modelExtents: extents, targetDimensions: dims)
            guard deviation <= CatalogModelLoader.verifiedModelTolerance else {
                catalogModelLogger.error(
                    "Verified model '\(assetName, privacy: .public)' native \(extents.x)×\(extents.y)×\(extents.z) m deviates \(deviation) m from catalog dims (> \(CatalogModelLoader.verifiedModelTolerance) m). Refusing — re-author the asset to true 1:1 scale, do not patch the transform. Showing honest box.")
                return   // box stays (modelLoadingIDs already cleared above)
            }

            // Real product USDZ ship their own correct PBR materials → tint nil
            // (never recolor a verified asset). fitTransform degenerates to identity
            // here because native dims ≈ target dims within tolerance.
            FurnitureEntityBuilder.attachRealisticModel(model, to: box, dimensions: dims, tint: nil)
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
                to: box
            )
        } else if let footprint = furnitureSnapshots[id] {
            FurnitureEntityBuilder.retint(box, footprint: footprint)
        }
    }

    /// Which colorable part of a sandbox piece sits under a tap, or nil. `throughPoint`
    /// is the tapped surface point in `root` space; we cast the camera ray through it
    /// and test the model's actual triangles (exact — so a pillow inside the frame's
    /// bounding box is still picked, which AABB/convex colliders can't do). Returns nil
    /// for verified/non-clay pieces (no loaded model) or a tap through empty space.
    func sandboxPartKey(forTapThrough throughPoint: SIMD3<Float>, pieceID id: UUID) -> String? {
        // Sandbox clay only. Verified products ALSO attach a `realisticModelName`
        // child, so finding the model isn't enough to prove this is clay — a
        // re-tap on a verified product would otherwise route into part-picking and
        // swallow the re-select. Gate on the footprint carrying a `sandboxAssetID`.
        guard currentFootprints.first(where: { $0.id == id })?.sandboxAssetID != nil,
              let box = furnitureEntities[id],
              let model = box.findEntity(named: FurnitureEntityBuilder.realisticModelName)
        else { return nil }
        let originWorld = camera.position(relativeTo: nil)
        let throughWorld = root.convert(position: throughPoint, to: nil)
        let direction = throughWorld - originWorld
        guard length(direction) > 1e-5 else { return nil }
        return FurnitureEntityBuilder.partKey(
            forRayOrigin: originWorld, direction: direction, in: model)
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
            // Only rebuild/reassign the material when the placement state actually
            // changes. `applyPlacementState` allocates a fresh PhysicallyBasedMaterial
            // and reassigns `model.model` — doing that every frame is a per-tick hitch,
            // and the tint is identical across frames sharing a state. Position still
            // updates every frame for 1:1 finger tracking.
            if state != lastDragState {
                FurnitureEntityBuilder.applyPlacementState(state, selected: true, to: entity)
            }
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
            // Keep a shown realistic model fit to the new size.
            if let visual = FurnitureEntityBuilder.realisticModelChild(of: entity) {
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

    // MARK: - Live two-finger rotation (yaw)

    private var rotatingFurnitureID: UUID?
    /// Yaw captured at twist start, so the cumulative gesture angle applies to a
    /// stable base rather than compounding each callback.
    private var rotateBaseYaw: Float = 0

    func beginFurnitureRotation(_ id: UUID) {
        guard let footprint = currentFootprints.first(where: { $0.id == id }) else { return }
        rotatingFurnitureID = id
        rotateBaseYaw = footprint.yRotation
        lastDragState = nil
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    /// Rotate the piece about the vertical axis by the cumulative gesture `angle`
    /// (radians) from the twist start. Position and size are untouched; only the
    /// entity's orientation and the footprint's `yRotation` change. Re-validates fit
    /// (a rotated piece can clear or hit a wall) and re-tints. The sign is negated so
    /// a clockwise on-screen twist reads as a clockwise yaw under the top-down camera.
    func rotateFurniture(by angle: Float) {
        guard let id = rotatingFurnitureID,
              let room = editingRoom,
              let index = currentFootprints.firstIndex(where: { $0.id == id }) else { return }

        let yaw = rotateBaseYaw - angle
        currentFootprints[index].yRotation = yaw
        let footprint = currentFootprints[index]

        let state = FurniturePlacementValidator.validate(
            footprint: footprint, against: room, existingFootprints: currentFootprints)

        if let entity = furnitureEntities[id] {
            entity.orientation = simd_quatf(angle: yaw, axis: [0, 1, 0])
            // Orientation updates every frame for 1:1 tracking, but the fit tint only
            // when the state actually flips — `applyPlacementState` allocates a fresh
            // material and rebuilds the selection border, a per-tick hitch across the
            // (nearly always) identical-state frames of a twist. Mirrors `dragFurniture`.
            if state != lastDragState {
                FurnitureEntityBuilder.applyPlacementState(state, selected: true, to: entity)
            }
            furnitureSnapshots[id] = footprint
        }

        if state == .invalid && lastDragState != .invalid {
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
        }
        lastDragState = state
    }

    func endFurnitureRotation() -> [FurnitureFootprint] {
        // Wrap the accumulated twist into [0, 2π) before persisting, matching the
        // discrete quarter-turn path. Without this a big pinch-twist leaves yRotation
        // at e.g. 7.8 rad, and FineTuneSheet's rotation slider (−180…180°) clamps it,
        // snapping the piece to a different angle than the one on screen.
        if let id = rotatingFurnitureID,
           let index = currentFootprints.firstIndex(where: { $0.id == id }) {
            let twoPi = Float.pi * 2
            let wrapped = currentFootprints[index].yRotation.truncatingRemainder(dividingBy: twoPi)
            currentFootprints[index].yRotation = wrapped < 0 ? wrapped + twoPi : wrapped
        }
        rotatingFurnitureID = nil
        lastDragState = nil
        return currentFootprints
    }

    // MARK: - Snap-to-wall pick mode

    /// Toggle the floor's tappability for "snap to wall": with an
    /// `InputTargetComponent` + collision the base hit-tests, so a tap can be
    /// unprojected to a floor point. Removed when picking ends, so normal tap/drag
    /// behavior (deselect on empty, orbit) is byte-identical outside the mode.
    func setWallPicking(_ picking: Bool) {
        guard let base = baseEntity else { return }
        if picking {
            if base.collision == nil { base.generateCollisionShapes(recursive: false) }
            base.components.set(InputTargetComponent())
        } else {
            base.components.remove(InputTargetComponent.self)
        }
    }

    // MARK: - Per-frame loop

    func onSceneUpdate(deltaTime: TimeInterval) {
        advanceCameraAnim(deltaTime: deltaTime)
        advanceWalkAnim(deltaTime: deltaTime)
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

    /// Advance an in-flight vantage glide. Uses a smootherstep ease (no overshoot —
    /// a camera flying past a standing spot and snapping back reads as a glitch).
    private func advanceWalkAnim(deltaTime: TimeInterval) {
        guard var anim = walkAnim else { return }
        anim.elapsed += deltaTime
        let t = Float(min(1, anim.elapsed / anim.duration))
        let e = t * t * t * (t * (t * 6 - 15) + 10)   // smootherstep
        walkPositionXZ = anim.fromPos + (anim.toPos - anim.fromPos) * e
        lookYaw = anim.fromYaw + (anim.toYaw - anim.fromYaw) * e
        lookPitch = anim.fromPitch + (anim.toPitch - anim.fromPitch) * e
        walkEyeHeight = anim.fromEye + (anim.toEye - anim.fromEye) * e
        updateWalkthroughCamera()
        walkAnim = (t >= 1) ? nil : anim
    }

    /// Hide walls between the camera and the room interior — the open-dollhouse
    /// view. A wall is hidden when the camera is on its outward side.
    private func cullWalls() {
        // Inside the room (walkthrough) you WANT the walls around you — never cull.
        // Show every wall, cap, and opening and skip the dollhouse test entirely.
        if perspective == .walkthrough {
            for wall in walls {
                wall.entity.isEnabled = true
                wall.cap?.isEnabled = true
            }
            for opening in openings { opening.entity.isEnabled = true }
            return
        }
        let cam = camera.position(relativeTo: nil)
        let camXZ = SIMD2(cam.x, cam.z)
        var hidden = [Bool](repeating: false, count: walls.count)
        for (i, wall) in walls.enumerated() {
            let toCam = camXZ - wall.midXZ
            let isHidden = simd_dot(wall.outwardXZ, toCam) > 0.05
            hidden[i] = isHidden
            wall.entity.isEnabled = !isHidden
            wall.cap?.isEnabled = !isHidden
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
        // Don't snapshot while realistic furniture models are still loading: the
        // pieces are translucent identity boxes until their async USDZ attaches, and
        // a thumbnail taken now would show those boxes instead of the real furniture.
        // Wait for all pending loads to finish, then a few more frames so the
        // freshly-attached models actually render. A hard frame cap (~4s at 60fps)
        // is the safety valve so a hung load can never block the thumbnail forever.
        if !modelLoadingIDs.isEmpty && frameCount < 240 {
            framesSinceModelsLoaded = 0
            return
        }
        framesSinceModelsLoaded += 1
        guard framesSinceModelsLoaded >= 3 || frameCount >= 240 else { return }
        let size = pixelSize
        guard size.width > 0, size.height > 0 else { return }
        didSnapshot = true
        Task { @MainActor in
            guard let image = await self.captureSnapshot(pixelSize: size),
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

    /// Zoom from the magnify gesture's cumulative magnification. In the diorama this
    /// is dolly distance (`pinch`); in the walkthrough it changes the eye-level FOV
    /// (`zoomWalkFOV`) — you can't dolly a first-person camera without free-roam, so
    /// pinch adjusts how wide the lens is instead.
    func zoomContinuous(magnification: CGFloat) {
        guard lastZoomMagnification > 0 else { return }
        let scale = Float(magnification / lastZoomMagnification)
        if perspective == .walkthrough { zoomWalkFOV(scale: scale) } else { pinch(scale: scale) }
        lastZoomMagnification = magnification
    }

    /// Adjust the walkthrough FOV by the pinch's incremental scale. Spreading fingers
    /// (scale > 1) narrows the lens (zoom in); pinching together widens it (more room
    /// around you). Dividing by `scale` mirrors the diorama's dolly feel.
    func zoomWalkFOV(scale: Float) {
        guard scale > 0 else { return }
        walkFOV = min(max(walkFOV / scale, Self.walkFOVRange.lowerBound), Self.walkFOVRange.upperBound)
        setCameraFOV(walkFOV)
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
