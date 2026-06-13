import SwiftUI
import RealityKit
import RoomPlan
import UIKit
import simd

/// Plain-gray, orbitable render of a CapturedRoom. Phase 0 scope: verify the
/// geometry looks sane, not make it pretty — drag to orbit, pinch to zoom,
/// flat gray materials only.
struct RoomModelView: UIViewRepresentable {
    let room: CapturedRoom

    func makeCoordinator() -> OrbitController {
        OrbitController()
    }

    func makeUIView(context: Context) -> ARView {
        // .nonAR: we render the captured geometry with our own camera; no
        // live AR session is involved in reviewing a finished scan.
        let view = ARView(frame: .zero, cameraMode: .nonAR, automaticallyConfigureSession: false)
        view.environment.background = .color(.secondarySystemBackground)
        context.coordinator.attach(to: view, room: room)
        return view
    }

    func updateUIView(_ uiView: ARView, context: Context) {}
}

/// Owns the camera rig, the gray room geometry, and the orbit/zoom gestures
/// for RoomModelView.
final class OrbitController: NSObject {
    private let camera = PerspectiveCamera()
    private var target = SIMD3<Float>.zero
    private var azimuth: Float = .pi / 4
    /// Clamped above the horizon so the camera never goes below the floor.
    private var elevation: Float = .pi / 5
    private var radius: Float = 5
    private var radiusRange: ClosedRange<Float> = 1...20

    func attach(to view: ARView, room: CapturedRoom) {
        let root = AnchorEntity(world: .zero)
        addGeometry(for: room, to: root)

        // One key light from above; position is irrelevant for a
        // directional light, only the orientation set by look(at:) matters.
        let sun = DirectionalLight()
        sun.light.intensity = 2500
        sun.look(at: .zero, from: [1, 2, 1.5], relativeTo: nil)
        root.addChild(sun)

        view.scene.addAnchor(root)

        let cameraAnchor = AnchorEntity(world: .zero)
        cameraAnchor.addChild(camera)
        view.scene.addAnchor(cameraAnchor)

        frame(room: room)
        updateCamera()
        addGestures(to: view)
    }

    // MARK: - Geometry

    private func addGeometry(for room: CapturedRoom, to root: Entity) {
        let wallMaterial = SimpleMaterial(color: .systemGray, isMetallic: false)
        let floorMaterial = SimpleMaterial(color: .systemGray2, isMetallic: false)
        let openingMaterial = SimpleMaterial(color: .systemGray3, isMetallic: false)
        let objectMaterial = SimpleMaterial(color: .darkGray, isMetallic: false)

        for wall in room.walls {
            root.addChild(surfaceEntity(wall, thickness: 0.02, material: wallMaterial))
        }
        for floor in room.floors {
            root.addChild(surfaceEntity(floor, thickness: 0.02, material: floorMaterial))
        }
        // Doors/windows/openings get a little extra thickness so they stand
        // proud of the wall plane instead of z-fighting with it.
        for door in room.doors {
            root.addChild(surfaceEntity(door, thickness: 0.05, material: openingMaterial))
        }
        for window in room.windows {
            root.addChild(surfaceEntity(window, thickness: 0.05, material: openingMaterial))
        }
        for opening in room.openings {
            root.addChild(surfaceEntity(opening, thickness: 0.05, material: openingMaterial))
        }
        for object in room.objects {
            let mesh = MeshResource.generateBox(
                width: object.dimensions.x,
                height: object.dimensions.y,
                depth: object.dimensions.z
            )
            let entity = ModelEntity(mesh: mesh, materials: [objectMaterial])
            entity.transform = Transform(matrix: object.transform)
            root.addChild(entity)
        }
    }

    /// Surfaces are planes (near-zero depth); give them a minimum thickness
    /// so they render as slabs.
    private func surfaceEntity(
        _ surface: CapturedRoom.Surface,
        thickness: Float,
        material: SimpleMaterial
    ) -> ModelEntity {
        let mesh = MeshResource.generateBox(
            width: surface.dimensions.x,
            height: surface.dimensions.y,
            depth: max(surface.dimensions.z, thickness)
        )
        let entity = ModelEntity(mesh: mesh, materials: [material])
        entity.transform = Transform(matrix: surface.transform)
        return entity
    }

    /// Aims the orbit at the room's center and picks a starting distance
    /// that fits the whole room in view.
    private func frame(room: CapturedRoom) {
        var points: [SIMD3<Float>] = []
        let surfaces = room.walls + room.floors + room.doors + room.windows + room.openings
        for surface in surfaces {
            points.append(surface.transform.translation)
        }
        for object in room.objects {
            points.append(object.transform.translation)
        }
        guard let first = points.first else { return }

        let minPoint = points.reduce(first, simd_min)
        let maxPoint = points.reduce(first, simd_max)
        target = (minPoint + maxPoint) / 2

        let extent = simd_length(maxPoint - minPoint)
        radius = max(extent * 1.4, 3)
        radiusRange = max(extent * 0.3, 0.5)...max(extent * 4, 8)
    }

    // MARK: - Gestures

    private func addGestures(to view: ARView) {
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.maximumNumberOfTouches = 1
        view.addGestureRecognizer(pan)

        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        view.addGestureRecognizer(pinch)
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard let view = gesture.view else { return }
        let translation = gesture.translation(in: view)
        azimuth -= Float(translation.x) * 0.008
        // Dragging up raises the camera; clamp between just above the floor
        // and just short of straight overhead.
        elevation = min(max(elevation - Float(translation.y) * 0.008, 0.05), .pi / 2 - 0.05)
        gesture.setTranslation(.zero, in: view)
        updateCamera()
    }

    @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        radius = min(
            max(radius / Float(gesture.scale), radiusRange.lowerBound),
            radiusRange.upperBound
        )
        gesture.scale = 1
        updateCamera()
    }

    private func updateCamera() {
        let position = target + SIMD3<Float>(
            radius * cosf(elevation) * sinf(azimuth),
            radius * sinf(elevation),
            radius * cosf(elevation) * cosf(azimuth)
        )
        camera.look(at: target, from: position, relativeTo: nil)
    }
}

private extension simd_float4x4 {
    var translation: SIMD3<Float> {
        SIMD3(columns.3.x, columns.3.y, columns.3.z)
    }
}
