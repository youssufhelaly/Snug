import Foundation
import simd

/// Pure geometry for the "snap to wall" action: the user picks a wall (by tapping
/// toward it), and a piece is placed flush against *that* wall — back to the wall,
/// front to the room — most furniture leans on a wall.
///
/// A deliberate two-step action (tap button → tap wall), never drag-time
/// magnetism — V1's interaction model is "the user nudges, the feedback guides"
/// (IDEAS.md parks auto-snap).
///
/// All points are `(x = world X, y = world Z)` — the app's floor-plan convention
/// (`PlanePoint.simd2`). A footprint's `dimensions` pack `(width, depth, height)`;
/// only `depth` matters here (how far the piece stands off the wall).
enum WallSnapService {
    /// Breathing room left between the piece's back and the wall (meters), so a
    /// snapped piece reads as "against the wall" without z-fighting the surface.
    static let wallGap: Float = 0.02

    /// Index of the wall (the edge from `corners[i]` to `corners[i+1]`) closest to
    /// `point` — i.e. the wall the user tapped toward. `nil` for a degenerate room.
    static func nearestWallIndex(to point: SIMD2<Float>, corners: [SIMD2<Float>]) -> Int? {
        guard corners.count >= 2 else { return nil }
        var best: (index: Int, distance: Float)?
        for i in corners.indices {
            let a = corners[i]
            let b = corners[(i + 1) % corners.count]
            let distance = Geometry2D.distance(from: point, toSegment: a, b)
            if best == nil || distance < best!.distance { best = (i, distance) }
        }
        return best?.index
    }

    /// Overlap-aware flush placement of a piece against the wall at `index`.
    ///
    /// The piece is rotated back-to-wall and pushed in by `depth/2 + gap`. Along the
    /// wall it starts opposite its current center, then **slides to the nearest free
    /// slot** — `isFree` reports whether a candidate `(position, yaw)` clears its
    /// neighbors and the room bounds (typically `FurniturePlacementValidator` ≠
    /// `.invalid`). If the wall is full, it returns the ideal flush spot anyway, so
    /// the piece lands where the user asked and reads red. `nil` for a bad index.
    ///
    /// After rotation the piece's WIDTH runs along the wall, so it's kept within
    /// `[width/2, wallLength − width/2]` to stay on this wall's span.
    static func snap(
        pieceCenter: SIMD2<Float>,
        width: Float,
        depth: Float,
        toWall index: Int,
        corners: [SIMD2<Float>],
        gap: Float = wallGap,
        step: Float = 0.05,
        isFree: (_ position: SIMD2<Float>, _ yRotation: Float) -> Bool = { _, _ in true }
    ) -> (position: SIMD2<Float>, yRotation: Float)? {
        guard corners.count >= 2, corners.indices.contains(index) else { return nil }
        let a = corners[index]
        let b = corners[(index + 1) % corners.count]
        let ab = b - a
        let length = simd_length(ab)
        guard length > 1e-3 else { return nil }
        let dir = ab / length

        let centroid = corners.reduce(.zero, +) / Float(corners.count)
        let mid = a + 0.5 * ab
        // Inward normal: the wall perpendicular pointing toward the room centroid.
        var normal = simd_normalize(SIMD2(-ab.y, ab.x))
        if simd_dot(normal, centroid - mid) < 0 { normal = -normal }
        let offset = depth / 2 + gap
        // At yaw 0 the depth axis runs along +Z; rotating about +Y maps +Z to
        // (sin θ, cos θ) in (x, z). Align that with the inward normal so the depth
        // axis (and the piece's back) sits perpendicular to the wall.
        let yaw = atan2(normal.x, normal.y)   // .y is world Z

        // Center of the piece for an along-wall coordinate `s` (meters from corner a).
        func position(along s: Float) -> SIMD2<Float> { a + dir * s + normal * offset }

        // Keep the piece on this wall's span (centered if it's wider than the wall).
        let halfWidth = width / 2
        let lo = min(halfWidth, length / 2)
        let hi = max(length - halfWidth, length / 2)
        let ideal = max(lo, min(hi, simd_dot(pieceCenter - a, dir)))

        if isFree(position(along: ideal), yaw) { return (position(along: ideal), yaw) }

        // Slide outward from the ideal slot, nearest-first in both directions.
        let maxSteps = Int((hi - lo) / step) + 1
        for k in 1...max(1, maxSteps) {
            let delta = Float(k) * step
            for candidate in [ideal + delta, ideal - delta] where candidate >= lo && candidate <= hi {
                if isFree(position(along: candidate), yaw) { return (position(along: candidate), yaw) }
            }
        }
        // Wall is full → land at the ideal flush spot (it'll read red).
        return (position(along: ideal), yaw)
    }
}
