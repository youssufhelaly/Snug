import SwiftUI
import UIKit
import simd

/// Phase 0.5 debug harness for `FitService` — exercise the trust layer before
/// any catalog or styling exists.
///
/// Top-down (2D) on purpose: the fit math IS 2D floor-plane geometry, so an
/// overhead view shows exactly what `FitService` sees — no hidden 3D transform
/// between what you drag and what gets evaluated, and none of the RealityKit
/// gesture fragility CLAUDE.md warns about. Drag the box, resize and rotate it
/// with the controls, and watch the four-state badge and clearances update live.
struct FitDebugView: View {
    let room: RoomModel

    @State private var widthCm: Double = 100
    @State private var depthCm: Double = 60
    @State private var heightCm: Double = 75
    @State private var rotationDegrees: Double = 0
    /// Box center in world coordinates (x = world X, y = world Z), meters.
    @State private var center: SIMD2<Float>
    /// Live override of the global margin so you can feel the bands move.
    @State private var marginCm: Double = Double(FitConfiguration.errorMargin * 100)
    /// Box center captured at the start of a drag, so we can apply the gesture's
    /// translation as a pure world-space delta (no absolute mapping → no
    /// constant offset between finger and box).
    @State private var dragStartCenter: SIMD2<Float>?

    private let service = FitService()

    init(room: RoomModel) {
        self.room = room
        _center = State(initialValue: Self.centroid(of: room))
    }

    private var roomCentroid: SIMD2<Float> { Self.centroid(of: room) }

    private static func centroid(of room: RoomModel) -> SIMD2<Float> {
        let pts = room.floorCorners.map(\.simd2)
        guard !pts.isEmpty else { return SIMD2(0, 0) }
        return pts.reduce(SIMD2<Float>.zero, +) / Float(pts.count)
    }

    private var item: OrientedFootprint {
        OrientedFootprint(
            center: center,
            size: SIMD2(Float(widthCm / 100), Float(depthCm / 100)),
            rotation: Float(rotationDegrees * .pi / 180)
        )
    }

    private var margin: Float { Float(marginCm / 100) }

    private var result: FitResult {
        service.evaluate(item: item, in: room.fitGeometry(), errorMargin: margin)
    }

    var body: some View {
        VStack(spacing: 0) {
            plan
                .frame(maxWidth: .infinity)
                .frame(height: 320)
                .background(Color(.secondarySystemBackground))

            badge

            controls
        }
        .navigationTitle("Fit harness")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Top-down plan + draggable box

    private var plan: some View {
        GeometryReader { geo in
            let projection = FloorProjection(corners: room.floorCorners.map(\.simd2), size: geo.size)
            ZStack {
                Canvas { context, _ in
                    drawRoom(in: context, projection: projection)
                    drawBox(in: context, projection: projection)
                }
                // Drag the box by translation only: screen delta ÷ scale = world
                // delta. This can't accumulate any padding/safe-area offset, so
                // the box tracks the finger 1:1 and reaches the walls exactly.
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                let start = dragStartCenter ?? center
                                if dragStartCenter == nil { dragStartCenter = start }
                                let worldDelta = SIMD2(
                                    Float(value.translation.width),
                                    Float(value.translation.height)
                                ) / Float(projection.scale)
                                center = start + worldDelta
                            }
                            .onEnded { _ in dragStartCenter = nil }
                    )
            }
        }
    }

    private func drawRoom(in context: GraphicsContext, projection: FloorProjection) {
        let pts = room.floorCorners.map(\.simd2)
        guard pts.count >= 2 else { return }
        var path = Path()
        path.addLines(pts.map(projection.project))
        path.closeSubpath()
        context.fill(path, with: .color(.gray.opacity(0.15)))
        context.stroke(path, with: .color(.gray), lineWidth: 2)

        for opening in room.openings {
            var seg = Path()
            seg.move(to: projection.project(opening.start.simd2))
            seg.addLine(to: projection.project(opening.end.simd2))
            context.stroke(seg, with: .color(opening.kind == .window ? .blue : .green), lineWidth: 5)
        }
    }

    private func drawBox(in context: GraphicsContext, projection: FloorProjection) {
        let corners = item.corners.map(projection.project)
        guard corners.count == 4 else { return }
        var path = Path()
        path.addLines(corners)
        path.closeSubpath()
        let tint = color(for: result.state)
        context.fill(path, with: .color(tint.opacity(0.35)))
        context.stroke(path, with: .color(tint), lineWidth: 2)

        // A short tick on the front edge so rotation is legible.
        let front = CGPoint(x: (corners[0].x + corners[1].x) / 2,
                            y: (corners[0].y + corners[1].y) / 2)
        let dot = CGRect(x: front.x - 3, y: front.y - 3, width: 6, height: 6)
        context.fill(Path(ellipseIn: dot), with: .color(tint))
    }

    // MARK: - Fit badge

    private var badge: some View {
        let r = result
        return VStack(spacing: 4) {
            Label(headline(for: r.state), systemImage: symbol(for: r.state))
                .font(.headline)
                .foregroundStyle(color(for: r.state))
            Text(clearanceSummary(r))
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
    }

    private func clearanceSummary(_ r: FitResult) -> String {
        var parts = ["nearest gap \(cm(r.clearance))"]
        if case .wall(let i) = r.limit { parts.append("wall \(i + 1)") }
        if case .obstacle(_, let kind) = r.limit { parts.append("\(kind)") }
        if let oc = r.obstacleClearance { parts.append("obstacle \(cm(oc))") }
        parts.append(String(format: "box @ (%.2f, %.2f) m", center.x, center.y))
        return parts.joined(separator: " · ")
    }

    private func cm(_ meters: Float) -> String {
        String(format: "%+.0f cm", meters * 100)
    }

    // MARK: - Controls

    private var controls: some View {
        Form {
            Section("Test box") {
                Button("Recenter box") { center = roomCentroid }
                stepperRow("Width", $widthCm, range: 10...500, unit: "cm")
                stepperRow("Depth", $depthCm, range: 10...500, unit: "cm")
                stepperRow("Height", $heightCm, range: 10...300, unit: "cm")
                HStack {
                    Text("Rotation")
                    Slider(value: $rotationDegrees, in: 0...360, step: 5)
                    Text("\(Int(rotationDegrees))°").monospacedDigit().frame(width: 44, alignment: .trailing)
                }
            }
            Section {
                HStack {
                    Text("Error margin")
                    Slider(value: $marginCm, in: 1...15, step: 1)
                    Text("\(Int(marginCm)) cm").monospacedDigit().frame(width: 44, alignment: .trailing)
                }
            } header: {
                Text("Margin")
            } footer: {
                Text("Phase 0 seed is \(Int(FitConfiguration.errorMargin * 100)) cm. Height is shown for reference; V1 fit is floor-plane only.")
            }
        }
    }

    private func stepperRow(_ title: String, _ value: Binding<Double>, range: ClosedRange<Double>, unit: String) -> some View {
        Stepper(value: value, in: range, step: 5) {
            HStack {
                Text(title)
                Spacer()
                Text("\(Int(value.wrappedValue)) \(unit)").foregroundStyle(.secondary).monospacedDigit()
            }
        }
    }

    // MARK: - State → UI copy (kept out of FitService, which stays pure)

    private func headline(for state: FitResult.State) -> String {
        switch state {
        case .fitsWithRoom: "Fits with room to spare"
        case .fits: "Fits"
        case .tooCloseToCall: "Too close to call — measure this wall"
        case .wontFit: "Won't fit"
        }
    }

    private func symbol(for state: FitResult.State) -> String {
        switch state {
        case .fitsWithRoom: "checkmark.circle.fill"
        case .fits: "checkmark.circle"
        case .tooCloseToCall: "ruler.fill"
        case .wontFit: "xmark.circle.fill"
        }
    }

    private func color(for state: FitResult.State) -> Color {
        switch state {
        case .fitsWithRoom: .green
        case .fits: .mint
        case .tooCloseToCall: .orange
        case .wontFit: .red
        }
    }
}

/// Shared world↔screen mapping for the harness so drawing and the drag gesture
/// agree exactly. World Z grows into the screen, so screen Y is not flipped
/// (matches the existing review floor plan).
private struct FloorProjection {
    let scale: CGFloat
    let minX: Float
    let minZ: Float
    let padding: CGFloat

    init(corners: [SIMD2<Float>], size: CGSize, padding: CGFloat = 32) {
        self.padding = padding
        let xs = corners.map(\.x), zs = corners.map(\.y)
        let loX = xs.min() ?? 0, hiX = xs.max() ?? 1
        let loZ = zs.min() ?? 0, hiZ = zs.max() ?? 1
        minX = loX
        minZ = loZ
        let worldW = max(hiX - loX, 0.01)
        let worldH = max(hiZ - loZ, 0.01)
        scale = min((size.width - 2 * padding) / CGFloat(worldW),
                    (size.height - 2 * padding) / CGFloat(worldH))
    }

    func project(_ p: SIMD2<Float>) -> CGPoint {
        CGPoint(x: padding + CGFloat(p.x - minX) * scale,
                y: padding + CGFloat(p.y - minZ) * scale)
    }
}

#Preview {
    NavigationStack {
        FitDebugView(room: RoomModel(
            provenance: .manualAR,
            floorCorners: [
                PlanePoint(x: -1.8, z: -1.5),
                PlanePoint(x: 1.8, z: -1.5),
                PlanePoint(x: 1.8, z: 1.5),
                PlanePoint(x: -1.8, z: 1.5),
            ],
            ceilingHeight: 2.5
        ))
    }
}
