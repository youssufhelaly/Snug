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
    private let camera = PerspectiveCamera()
    private let keyLight = DirectionalLight()
    private let fillA = DirectionalLight()
    private let fillB = DirectionalLight()

    private var floorEntity: ModelEntity?
    private var baseEntity: ModelEntity?
    /// Walls plus the data needed to cull the ones between the camera and the
    /// room interior (the open-dollhouse look).
    private var walls: [(entity: ModelEntity, midXZ: SIMD2<Float>, outwardXZ: SIMD2<Float>)] = []
    /// Opening panels, each tied to the wall it sits on so culling stays in sync.
    private var openings: [(entity: ModelEntity, wallIndex: Int)] = []
    /// BUY-mode dimension labels (lie flat on the floor like a blueprint).
    private var labels: [ModelEntity] = []

    // MARK: Camera state
    private var target = SIMD3<Float>.zero
    private var azimuth: Float = .pi / 4
    private var elevation: Float = .pi / 5
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

        let cameraAnchor = AnchorEntity(world: .zero)
        cameraAnchor.addChild(camera)
        view.scene.addAnchor(cameraAnchor)

        frameCamera(room: room)
        applyPalette(for: mode)
        updateCamera()
        addGestures(to: view)

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
        keyLight.look(at: .zero, from: [1.6, 3.0, 2.0], relativeTo: nil)
        fillA.look(at: .zero, from: [-2.0, 2.2, -1.4], relativeTo: nil)
        fillB.look(at: .zero, from: [0.4, 1.4, -2.2], relativeTo: nil)
    }

    // MARK: - Geometry (mode-independent)

    private func buildGeometry(room: RoomModel) {
        let corners = room.floorCorners.map(\.simd2)
        guard corners.count >= 3 else { return }
        centroidXZ = corners.reduce(.zero, +) / Float(corners.count)
        let height = room.ceilingHeight

        // Grounding base: a soft platform under the room so the diorama reads as
        // sitting on a surface. This is the Phase-1 "simplified contact shadow";
        // real per-item contact shadows arrive with furniture in Phase 3.
        if let base = makeBase(corners: corners) {
            baseEntity = base
            root.addChild(base)
        }

        // Floor: a thin double-sided sheet triangulated from the polygon, so any
        // room shape (rectangle, L, …) renders correctly from above regardless
        // of back-face culling.
        if let floorMesh = Self.floorMesh(corners: corners) {
            let floor = ModelEntity(mesh: floorMesh, materials: [placeholderMaterial()])
            floorEntity = floor
            root.addChild(floor)
        }

        // Walls: thin full-height boxes, one per polygon edge.
        for wall in room.walls {
            let a = wall.start.simd2, b = wall.end.simd2
            let mid = (a + b) / 2
            let dir = b - a
            let length = simd_length(dir)
            guard length > 0.01 else { continue }
            let yaw = atan2(-dir.y, dir.x)

            let mesh = MeshResource.generateBox(width: length, height: height, depth: 0.06)
            let entity = ModelEntity(mesh: mesh, materials: [placeholderMaterial()])
            entity.position = SIMD3(mid.x, height / 2, mid.y)
            entity.orientation = simd_quatf(angle: yaw, axis: [0, 1, 0])
            root.addChild(entity)

            var outward = SIMD2<Float>(dir.y, -dir.x)
            if simd_dot(outward, mid - centroidXZ) < 0 { outward = -outward }
            outward = simd_normalize(outward)
            walls.append((entity, mid, outward))
        }

        // Openings: proud panels on the inner face of their nearest wall.
        for opening in room.openings {
            guard let panel = makeOpening(opening, walls: room.walls, ceiling: height) else { continue }
            root.addChild(panel.entity)
            openings.append(panel)
        }

        // Dimension labels (shown only in BUY): wall length, laid flat near each
        // wall's midpoint like a floor-plan annotation.
        for wall in room.walls {
            guard let label = makeDimensionLabel(for: wall) else { continue }
            label.isEnabled = false
            labels.append(label)
            root.addChild(label)
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
        let mesh = MeshResource.generateBox(size: [w, 0.04, dz], cornerRadius: 0.06)
        let entity = ModelEntity(mesh: mesh, materials: [placeholderMaterial()])
        entity.position = SIMD3((minX + maxX) / 2, -0.04, (minZ + maxZ) / 2)
        return entity
    }

    private func makeOpening(_ opening: RoomOpening, walls roomWalls: [WallSegment], ceiling: Float) -> (entity: ModelEntity, wallIndex: Int)? {
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

        let mesh = MeshResource.generateBox(size: [width, panelHeight, 0.04], cornerRadius: 0.02)
        let entity = ModelEntity(mesh: mesh, materials: [placeholderMaterial()])
        // Sit proud on the inner face: nudge toward the room interior.
        let inward = walls.indices.contains(wallIndex) ? -walls[wallIndex].outwardXZ : SIMD2<Float>(0, 0)
        let offset = inward * 0.05
        entity.position = SIMD3(mid.x + offset.x, sill + panelHeight / 2, mid.y + offset.y)
        entity.orientation = simd_quatf(angle: yaw, axis: [0, 1, 0])
        return (entity, wallIndex)
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

    private func placeholderMaterial() -> SimpleMaterial {
        SimpleMaterial(color: .gray, isMetallic: false)
    }

    private func matteMaterial(_ color: UIColor) -> SimpleMaterial {
        // Matte, non-metallic: the cozy, flat-shaded diorama look.
        SimpleMaterial(color: color, roughness: 0.95, isMetallic: false)
    }

    /// Swap only materials + lighting. No geometry is touched.
    private func applyPalette(for mode: RoomRenderMode) {
        let palette = RoomPalette.palette(for: mode)
        arView?.environment.background = .color(palette.background)

        let floorMat = matteMaterial(palette.floor)
        let wallMat = matteMaterial(palette.wall)
        let openingMat = matteMaterial(palette.opening)
        let baseMat = matteMaterial(palette.floor.darkened(by: 0.12))

        setMaterial(floorMat, on: floorEntity)
        setMaterial(baseMat, on: baseEntity)
        for wall in walls { setMaterial(wallMat, on: wall.entity) }
        for opening in openings { setMaterial(openingMat, on: opening.entity) }
        for label in labels { label.isEnabled = palette.showsDimensions }

        keyLight.light.color = palette.keyLightTint
        keyLight.light.intensity = palette.keyLightIntensity
        fillA.light.intensity = palette.fillLightIntensity
        fillB.light.intensity = palette.fillLightIntensity * 0.7
    }

    private func setMaterial(_ material: SimpleMaterial, on entity: ModelEntity?) {
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
        radius = max(extent * 1.5, 3)
        radiusRange = max(extent * 0.45, 1.2)...max(extent * 4, 10)

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

private extension UIColor {
    /// A slightly darker shade, for the grounding base.
    func darkened(by fraction: CGFloat) -> UIColor {
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard getHue(&h, saturation: &s, brightness: &b, alpha: &a) else { return self }
        return UIColor(hue: h, saturation: s, brightness: max(0, b * (1 - fraction)), alpha: a)
    }
}
