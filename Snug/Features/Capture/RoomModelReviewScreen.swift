import SwiftUI

/// Post-capture review for any `RoomModel`: a top-down floor plan plus a
/// dimensions panel, the ground-truth logger, and a fixture export. Rendered in
/// 2D (SwiftUI Canvas) so it's reliable on every device with no AR/RealityKit
/// dependency — the manual-AR flow lands here.
struct RoomModelReviewScreen: View {
    let room: RoomModel
    let onDone: () -> Void
    let onRecapture: () -> Void
    /// Re-opens the drag-to-correct editor on this room. Provided only for
    /// capture methods that go through it (manual AR); nil hides the control so
    /// Confirm is never a one-way door.
    var onEditShape: (() -> Void)? = nil

    @State private var shareItem: ShareItem?
    @State private var exportErrorMessage: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                FloorPlanView(room: room)
                    .frame(height: 280)
                    .padding()
                    .accessibilityLabel("Top-down floor plan of your room")

                detailList
            }
            .navigationTitle("Your room")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Recapture", action: onRecapture)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done", action: onDone).fontWeight(.semibold)
                }
            }
            .exportPresentation(shareItem: $shareItem, errorMessage: $exportErrorMessage)
        }
    }

    private var detailList: some View {
        List {
            if let onEditShape {
                Section {
                    Button(action: onEditShape) {
                        Label("Review layout", systemImage: "hand.draw")
                    }
                    .accessibilityHint("Reopens the floor plan so you can drag corners and adjust the ceiling height")
                }
            }

            Section("Room") {
                LabeledContent("Ceiling height", value: SnugFormat.meters(room.ceilingHeight))
                LabeledContent("Diagonal", value: SnugFormat.meters(room.longestDiagonal))
                LabeledContent("Floor area", value: String(format: "%.1f m²", room.floorArea))
                LabeledContent("Perimeter", value: SnugFormat.meters(room.perimeter))
            }

            Section("Walls") {
                ForEach(room.walls) { wall in
                    LabeledContent("Wall \(wall.id + 1)", value: SnugFormat.meters(wall.length))
                }
            }

            if !room.openings.isEmpty {
                Section("Openings") {
                    ForEach(room.openings) { opening in
                        LabeledContent(opening.kind.label, value: "\(SnugFormat.meters(opening.width)) wide")
                    }
                }
            }

            Section("Export & ground truth") {
                Button {
                    do { shareItem = ShareItem(url: try FixtureExporter.exportFixture(for: room)) }
                    catch { exportErrorMessage = error.localizedDescription }
                } label: {
                    Label("Export room (JSON)", systemImage: "doc.badge.gearshape")
                }
                NavigationLink {
                    GroundTruthView(room: room)
                } label: {
                    Label("Log ground truth", systemImage: "ruler")
                }
                NavigationLink {
                    FitDebugView(room: room)
                } label: {
                    Label("Fit harness (debug)", systemImage: "shippingbox")
                }
            }
        }
        .listStyle(.insetGrouped)
    }
}

/// Draws a `RoomModel`'s floor outline top-down, auto-scaled to fit, with edge
/// lengths and openings highlighted.
private struct FloorPlanView: View {
    let room: RoomModel

    var body: some View {
        Canvas { context, size in
            let points = room.floorCorners.map(\.simd2)
            guard points.count >= 2 else { return }

            // Fit the room bounds into the canvas with padding, preserving
            // aspect ratio. World Z grows "into" the screen, so flip Y.
            let xs = points.map(\.x), zs = points.map(\.y)
            let minX = xs.min()!, maxX = xs.max()!
            let minZ = zs.min()!, maxZ = zs.max()!
            let worldW = max(maxX - minX, 0.01)
            let worldH = max(maxZ - minZ, 0.01)
            let padding: CGFloat = 32
            let scale = min((size.width - 2 * padding) / CGFloat(worldW),
                            (size.height - 2 * padding) / CGFloat(worldH))

            func project(_ p: SIMD2<Float>) -> CGPoint {
                let x = padding + CGFloat(p.x - minX) * scale
                let y = padding + CGFloat(p.y - minZ) * scale
                return CGPoint(x: x, y: y)
            }

            // Floor polygon.
            var path = Path()
            path.addLines(points.map(project))
            path.closeSubpath()
            context.fill(path, with: .color(.gray.opacity(0.15)))
            context.stroke(path, with: .color(.gray), lineWidth: 2)

            // Edge length labels at each wall midpoint.
            for wall in room.walls {
                let a = wall.start.simd2, b = wall.end.simd2
                let mid = project((a + b) / 2)
                let text = Text(SnugFormat.meters(wall.length)).font(.caption2)
                context.draw(text, at: mid)
            }

            // Corner dots.
            for p in points {
                let c = project(p)
                let dot = CGRect(x: c.x - 4, y: c.y - 4, width: 8, height: 8)
                context.fill(Path(ellipseIn: dot), with: .color(.orange))
            }

            // Openings as thick colored segments.
            for opening in room.openings {
                var seg = Path()
                seg.move(to: project(opening.start.simd2))
                seg.addLine(to: project(opening.end.simd2))
                let color: Color = opening.kind == .window ? .blue : .green
                context.stroke(seg, with: .color(color), lineWidth: 5)
            }
        }
    }
}
