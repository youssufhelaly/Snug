import SwiftUI
import RealityKit
import Combine
import UIKit
import simd

/// The Phase 1 diorama: a `RoomModel` rendered in RealityKit as a cozy, stylized
/// "play mode" world, with an instant PLAY/BUY material toggle, orbit/zoom/pan
/// camera, and a soft grounding base.
///
/// The hard product rule lives here: **geometry is identical between modes.**
/// Switching PLAY↔BUY only swaps materials and lighting — never a vertex moves.
/// The cross-fade is done by snapshotting the live frame, swapping materials
/// underneath, and fading the snapshot out (< 400 ms), which avoids any fragile
/// offscreen rendering.
struct RoomSceneView: UIViewRepresentable {
    let room: RoomModel
    let mode: RoomRenderMode
    /// Incremented by the parent to request a spring camera reset.
    var resetToken: Int = 0
    /// Called once with PNG data after the first frames render, for the room's
    /// list thumbnail. Optional.
    var onThumbnail: ((Data) -> Void)? = nil

    func makeCoordinator() -> RoomSceneController {
        RoomSceneController()
    }

    func makeUIView(context: Context) -> ARView {
        // .nonAR: we render captured geometry with our own camera; there is no
        // live AR session when reviewing a finished room.
        let view = ARView(frame: .zero, cameraMode: .nonAR, automaticallyConfigureSession: false)
        context.coordinator.onThumbnail = onThumbnail
        context.coordinator.attach(to: view, room: room, mode: mode)
        return view
    }

    func updateUIView(_ uiView: ARView, context: Context) {
        let controller = context.coordinator
        if controller.mode != mode {
            controller.setMode(mode, animated: true)
        }
        if controller.lastResetToken != resetToken {
            controller.lastResetToken = resetToken
            controller.resetCamera(animated: true)
        }
    }

    static func dismantleUIView(_ uiView: ARView, coordinator: RoomSceneController) {
        coordinator.tearDown()
    }
}

/// Owns the RealityKit scene, camera rig, gesture handling, per-mode materials,
/// dollhouse wall culling, the cross-fade, and the thumbnail snapshot for one
/// `RoomSceneView`.
final class RoomSceneController: NSObject {

    // MARK: Scene
    private weak var arView: ARView?
    private let root = AnchorEntity(world: .zero)
    private let camera = Entity()
    private let keyLight = DirectionalLight()
    private let fillA = DirectionalLight()
    private let fillB = DirectionalLight()
    /// The warm studio environment for PLAY image-based lighting + skybox. Built
    /// asynchronously (GPU work) after the scene attaches; nil until ready and in
    /// BUY, where lighting stays neutral.
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

    // MARK: Camera state

    /// Calibration for the orthographic view-volume. The diorama now uses a TRUE
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
    static let demoFurniture = true
    /// Bumped on every `setMode`; a snapshot callback applies its palette only if
    /// it's still the latest generation, so rapid toggles can't flash a stale one.
    private var modeGeneration = 0
    var lastResetToken = 0
    var onThumbnail: ((Data) -> Void)?
    private var didSnapshot = false
    private var frameCount = 0
    private var updateSub: Cancellable?

    // MARK: - Setup

    func attach(to view: ARView, room: RoomModel, mode: RoomRenderMode) {
        self.arView = view
        self.mode = mode

        buildLights()
        root.addChild(keyLight)
        root.addChild(fillA)
        root.addChild(fillB)
        buildGeometry(room: room)
        view.scene.addAnchor(root)

        // True orthographic projection — the canonical isometric-diorama camera.
        // The ortho `scale` (view-volume height) is set every frame in `updateCamera`,
        // derived from `radius`, so the existing orbit / pinch-zoom / reset machinery
        // keeps driving a single value and needs no other change.
        //
        // VERIFY ON DEVICE: that `OrthographicCameraComponent` is honored as the
        // active camera in a `.nonAR ARView`. RealityKit's perspective camera works
        // here; the ortho component is the one piece we can't compile-check off-device
        // (no Xcode on this Mac). If the scene renders black/empty, RealityKit isn't
        // picking up the ortho camera in ARView and this view should migrate to
        // `RealityView` (iOS 18+), which supports it cleanly — a larger change to
        // weigh separately. To fall back fast meanwhile: restore `PerspectiveCamera()`
        // above and `camera.camera.fieldOfViewInDegrees = Self.isoFOVDegrees` here.
        camera.components.set(OrthographicCameraComponent())

        let cameraAnchor = AnchorEntity(world: .zero)
        cameraAnchor.addChild(camera)
        view.scene.addAnchor(cameraAnchor)

        frameCamera(room: room)
        applyPalette(for: mode)
        updateCamera()
        addGestures(to: view)
        loadEnvironment()

        // Drive culling, label facing, the reset spring, and the one-time
        // thumbnail off the render loop.
        updateSub = view.scene.subscribe(to: SceneEvents.Update.self) { [weak self] event in
            self?.onSceneUpdate(deltaTime: event.deltaTime)
        }
    }

    func tearDown() {
        updateSub = nil
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

        // TEMPORARY furniture preview — delete with `placeDemoFurniture`.
        if Self.demoFurniture { placeDemoFurniture(at: centroidXZ) }
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

        // Warm skybox + image-based lighting in PLAY (once `environment` is built);
        // flat neutral color in BUY. Kept last so the directional rig is in place
        // regardless of whether the async environment has loaded yet.
        applyEnvironmentLighting()
    }

    /// Apply the warm studio environment as PLAY image-based lighting over a solid
    /// "void" backdrop, or a flat neutral color in BUY. Called from `applyPalette`
    /// on every mode change and again from `loadEnvironment` once the async
    /// resource is ready. Uses `self.mode`, which callers set before invoking.
    private func applyEnvironmentLighting() {
        guard let arView else { return }
        if mode == .play, let environment {
            // Keep the warm IBL wrap for soft global illumination, but show a flat
            // solid backdrop instead of the skybox gradient, so the room reads as a
            // model floating in a clean void — the defining diorama composition.
            arView.environment.lighting.resource = environment
            arView.environment.background = .color(RoomPalette.palette(for: .play).background)
        } else {
            arView.environment.lighting.resource = nil
            arView.environment.background = .color(RoomPalette.palette(for: mode).background)
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

    /// Cross-fade to a new render mode: snapshot the current frame, swap
    /// materials beneath it, then fade the snapshot out in < 400 ms.
    func setMode(_ newMode: RoomRenderMode, animated: Bool) {
        guard newMode != mode else { return }
        mode = newMode
        modeGeneration += 1
        let generation = modeGeneration
        guard animated, let view = arView else {
            applyPalette(for: newMode)
            return
        }
        view.snapshot(saveToHDR: false) { [weak self] image in
            DispatchQueue.main.async {
                guard let self, let view = self.arView else { return }
                // A newer toggle has superseded this one; let its callback apply
                // the correct palette and cross-fade rather than flashing a stale
                // frame on top of it.
                guard self.modeGeneration == generation else { return }
                guard let image else {
                    self.applyPalette(for: newMode)
                    return
                }
                let overlay = UIImageView(image: image)
                overlay.frame = view.bounds
                overlay.contentMode = .scaleAspectFill
                overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                view.addSubview(overlay)
                self.applyPalette(for: newMode)
                UIView.animate(withDuration: 0.35, animations: {
                    overlay.alpha = 0
                }, completion: { _ in
                    overlay.removeFromSuperview()
                })
            }
        }
    }

    // MARK: - Camera

    private func frameCamera(room: RoomModel) {
        let corners = room.floorCorners.map(\.simd2)
        guard !corners.isEmpty else { return }
        let xs = corners.map(\.x), zs = corners.map(\.y)
        let minX = xs.min()!, maxX = xs.max()!, minZ = zs.min()!, maxZ = zs.max()!
        let centerXZ = SIMD2((minX + maxX) / 2, (minZ + maxZ) / 2)
        target = SIMD3(centerXZ.x, room.ceilingHeight * 0.35, centerXZ.y)

        let span = simd_length(SIMD2(maxX - minX, maxZ - minZ))
        let extent = max(span, room.ceilingHeight)
        // Seed the orbit distance. With an orthographic camera the distance no
        // longer sets apparent size (the ortho `scale` does, derived from `radius`
        // in `updateCamera`), but `radius` still positions the camera for orbit and
        // must clear the geometry. We keep the original distance formula so the
        // initial ortho scale (≈ 1.2 × room extent) frames the room exactly as the
        // tuned perspective camera did. The 1.2 margin leaves breathing room.
        let halfFOV = (Self.isoFOVDegrees * .pi / 180) / 2
        let fitDistance = (extent * 0.5) / tan(halfFOV)
        radius = max(fitDistance * 1.2, 3)
        radiusRange = max(fitDistance * 0.6, 1.5)...max(fitDistance * 2.6, 12)

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

    // MARK: - Per-frame loop

    private func onSceneUpdate(deltaTime: TimeInterval) {
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
        guard !didSnapshot, let onThumbnail, let view = arView else { return }
        frameCount += 1
        // Give the scene a few frames to render before grabbing the thumbnail.
        guard frameCount >= 8 else { return }
        didSnapshot = true
        view.snapshot(saveToHDR: false) { image in
            guard let data = image?.pngData() else { return }
            DispatchQueue.main.async { onThumbnail(data) }
        }
    }

    private static func easeOutBack(_ t: Float) -> Float {
        let c1: Float = 1.70158
        let c3 = c1 + 1
        let p = t - 1
        return 1 + c3 * p * p * p + c1 * p * p
    }

    // MARK: - Gestures

    private func addGestures(to view: ARView) {
        let orbit = UIPanGestureRecognizer(target: self, action: #selector(handleOrbit(_:)))
        orbit.maximumNumberOfTouches = 1
        view.addGestureRecognizer(orbit)

        let panTarget = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        panTarget.minimumNumberOfTouches = 2
        panTarget.maximumNumberOfTouches = 2
        view.addGestureRecognizer(panTarget)

        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        view.addGestureRecognizer(pinch)
    }

    @objc private func handleOrbit(_ gesture: UIPanGestureRecognizer) {
        guard let view = gesture.view else { return }
        cameraAnim = nil
        let t = gesture.translation(in: view)
        azimuth -= Float(t.x) * 0.008
        elevation = min(max(elevation - Float(t.y) * 0.008, 0.06), .pi / 2 - 0.05)
        gesture.setTranslation(.zero, in: view)
        updateCamera()
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard let view = gesture.view else { return }
        cameraAnim = nil
        let t = gesture.translation(in: view)
        // Pan the look-at target across the floor, in the camera's screen plane.
        // Right and "forward on floor" are derived from the current azimuth.
        let right = SIMD3<Float>(cosf(azimuth), 0, -sinf(azimuth))
        let forward = SIMD3<Float>(sinf(azimuth), 0, cosf(azimuth))
        let scale = radius * 0.0016
        var newTarget = target
        newTarget -= right * Float(t.x) * scale
        newTarget += forward * Float(t.y) * scale
        // Keep the target from wandering far outside the room footprint.
        let limit: Float = radiusRange.upperBound
        newTarget.x = min(max(newTarget.x, centroidXZ.x - limit), centroidXZ.x + limit)
        newTarget.z = min(max(newTarget.z, centroidXZ.y - limit), centroidXZ.y + limit)
        target = newTarget
        gesture.setTranslation(.zero, in: view)
        updateCamera()
    }

    @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        cameraAnim = nil
        radius = min(max(radius / Float(gesture.scale), radiusRange.lowerBound), radiusRange.upperBound)
        gesture.scale = 1
        updateCamera()
    }
}

