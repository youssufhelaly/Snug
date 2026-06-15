import RealityKit
import UIKit
import simd

/// Builds the chunky dark "toy" outlines for the PLAY-mode diorama.
///
/// ## Technique (and its one runtime assumption)
/// RealityKit on iOS 17 exposes **no** `faceCulling` material property and no
/// reliable per-entity render-order knob, so the classic SceneKit outline tricks
/// don't translate. The production-safe approach the Phase-3 prompt points at is
/// the **inverted hull**: a slightly inflated companion mesh whose triangles are
/// wound *inward*. RealityKit's standard materials cull back faces (they are
/// single-sided, which is exactly why `faceCulling` isn't settable), so an
/// inward-wound inflated shell renders only its far faces — appearing as a dark
/// rim around the silhouette while the real, smaller, lit mesh shows through in
/// the middle.
///
/// **The assumption to verify on device:** that standard-material back-face
/// culling is on by default. If a shell ever renders as a *solid* dark blob
/// instead of a rim, culling is off for that material and the fix is to flip the
/// winding back (remove the `.reversed()` in `boxShellMesh`) — not to invent a
/// culling API. This is called out as verify-item #1 in the task summary.
///
/// Because the shells are built from `MeshDescriptor` we fully control winding;
/// nothing here depends on reading or rewriting `MeshResource.Contents`.
///
/// Outline entities are added as **siblings** of the thing they outline (parented
/// to the same parent), never as children, so the source entity's transform can't
/// double-apply the inflation. They use `UnlitMaterial`, so lighting and normals
/// are irrelevant — only winding matters.
enum OutlineEntity {

    /// Default inflation for solid forms. Kept thin — the PLAY outline is now a
    /// subtle warm rim, not a chunky toy outline, so it only peeks past the
    /// silhouette rather than framing it heavily.
    static let boxScale: Float = 1.022
    /// Flat surfaces (the floor) need only a hair of inflation to read.
    static let flatScale: Float = 1.012

    // MARK: - Box shell (walls, opening panels, box furniture parts)

    /// An inverted-hull outline shell for a box of `size`, centered on its own
    /// origin. The caller positions/orients it to match the source entity.
    /// Returns `nil` only if the mesh fails to generate.
    static func boxShell(size: SIMD3<Float>, scale: Float = boxScale, color: UIColor) -> ModelEntity? {
        guard let mesh = boxShellMesh(size: size * scale) else { return nil }
        return ModelEntity(mesh: mesh, materials: [rimMaterial(color)])
    }

    /// An `UnlitMaterial` for an outline shell that honors the outline color's
    /// alpha (so a translucent warm rim reads soft instead of as a solid block).
    /// The tint is forced opaque and the alpha drives `transparent` blending —
    /// the robust path, rather than relying on tint alpha alone.
    private static func rimMaterial(_ color: UIColor) -> UnlitMaterial {
        let opacity = Float(color.cgColor.alpha)
        var material = UnlitMaterial()
        material.color = .init(tint: color.withAlphaComponent(1))
        material.blending = .transparent(opacity: .init(floatLiteral: opacity))
        return material
    }

    /// A reversed-winding (inward-facing) box mesh. Winding is the only thing that
    /// matters for the hull; UnlitMaterial ignores normals, so we omit them.
    private static func boxShellMesh(size: SIMD3<Float>) -> MeshResource? {
        let h = size / 2
        let corners: [SIMD3<Float>] = [
            [-h.x, -h.y, -h.z], [ h.x, -h.y, -h.z], [ h.x,  h.y, -h.z], [-h.x,  h.y, -h.z],
            [-h.x, -h.y,  h.z], [ h.x, -h.y,  h.z], [ h.x,  h.y,  h.z], [-h.x,  h.y,  h.z],
        ]
        // Outward-facing (CCW-from-outside) triangles. We reverse each triple
        // below to point the front faces inward for the inverted hull.
        let outward: [UInt32] = [
            4, 5, 6,  4, 6, 7,   // +Z
            1, 0, 3,  1, 3, 2,   // -Z
            5, 1, 2,  5, 2, 6,   // +X
            0, 4, 7,  0, 7, 3,   // -X
            7, 6, 2,  7, 2, 3,   // +Y
            0, 1, 5,  0, 5, 4,   // -Y
        ]
        var indices: [UInt32] = []
        indices.reserveCapacity(outward.count)
        for t in stride(from: 0, to: outward.count, by: 3) {
            indices.append(contentsOf: [outward[t], outward[t + 2], outward[t + 1]])
        }

        var d = MeshDescriptor(name: "outlineBox")
        d.positions = MeshBuffers.Positions(corners)
        d.primitives = .triangles(indices)
        return try? MeshResource.generate(from: [d])
    }

    // MARK: - Floor shell (culling-independent under-sheet)

    /// The floor outline is a flat dark sheet slightly larger than the floor,
    /// tucked just below it, so its border peeks out as a rim. This needs no
    /// winding trick — it's robust regardless of culling — because it's offset on
    /// a single axis (down) and inflated only in the floor plane.
    ///
    /// - Parameters:
    ///   - corners: the floor polygon (XZ).
    ///   - pivot: the point to inflate about (the floor centroid).
    ///   - scale: in-plane inflation (≈1.02).
    ///   - y: vertical placement (just below the real floor).
    static func floorShell(corners: [SIMD2<Float>], pivot: SIMD2<Float>,
                           scale: Float = flatScale, y: Float, color: UIColor) -> ModelEntity? {
        guard corners.count >= 3 else { return nil }
        let inflated = corners.map { pivot + ($0 - pivot) * scale }
        let tris = PolygonTriangulator.triangulate(inflated)
        guard !tris.isEmpty else { return nil }

        let positions = inflated.map { SIMD3<Float>($0.x, y, $0.y) }
        let normals = [SIMD3<Float>](repeating: [0, 1, 0], count: positions.count)
        var d = MeshDescriptor(name: "outlineFloor")
        d.positions = MeshBuffers.Positions(positions)
        d.normals = MeshBuffers.Normals(normals)
        d.primitives = .triangles(tris)
        guard let mesh = try? MeshResource.generate(from: [d]) else { return nil }
        return ModelEntity(mesh: mesh, materials: [rimMaterial(color)])
    }
}
