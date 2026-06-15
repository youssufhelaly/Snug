import SwiftUI
import UIKit

/// A room's list thumbnail: the RealityKit diorama snapshot once it exists,
/// otherwise a friendly top-down floor-plan placeholder drawn from the geometry
/// (so a just-saved room never shows a blank tile).
struct RoomThumbnail: View {
    let stored: StoredRoom

    var body: some View {
        ZStack {
            if let data = stored.thumbnailData, let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else if let room = stored.roomModel {
                MiniFloorPlan(room: room)
                    .background(SnugTheme.surface)
            } else {
                SnugTheme.surface
                Image(systemName: "questionmark.square.dashed")
                    .foregroundStyle(SnugTheme.subtle)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityHidden(true)
    }
}

/// Compact, label-free floor outline for the thumbnail placeholder.
private struct MiniFloorPlan: View {
    let room: RoomModel

    var body: some View {
        Canvas { context, size in
            let points = room.floorCorners.map(\.simd2)
            guard points.count >= 2 else { return }
            let xs = points.map(\.x), zs = points.map(\.y)
            let minX = xs.min()!, maxX = xs.max()!
            let minZ = zs.min()!, maxZ = zs.max()!
            let worldW = max(maxX - minX, 0.01)
            let worldH = max(maxZ - minZ, 0.01)
            let padding: CGFloat = 16
            let scale = min((size.width - 2 * padding) / CGFloat(worldW),
                            (size.height - 2 * padding) / CGFloat(worldH))
            // Center the plan in the tile.
            let drawnW = CGFloat(worldW) * scale
            let drawnH = CGFloat(worldH) * scale
            let originX = (size.width - drawnW) / 2
            let originY = (size.height - drawnH) / 2

            func project(_ p: SIMD2<Float>) -> CGPoint {
                CGPoint(x: originX + CGFloat(p.x - minX) * scale,
                        y: originY + CGFloat(p.y - minZ) * scale)
            }

            var path = Path()
            path.addLines(points.map(project))
            path.closeSubpath()
            context.fill(path, with: .color(SnugTheme.sage.opacity(0.25)))
            context.stroke(path, with: .color(SnugTheme.sage), lineWidth: 2)
        }
    }
}
