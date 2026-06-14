import SwiftUI
import UIKit

/// Drag-to-correct overhead floor-plan editor — Solution 1 for the
/// furniture-in-the-corner bug. When AR raycasts hit a bed or desk instead of
/// the wall behind it, the closed polygon bulges around the furniture. Here the
/// user drags any corner to where the wall actually is before confirming.
///
/// Pure 2D (SwiftUI `Canvas` + overlaid handle views), so it's reliable on
/// every device with no AR/RealityKit dependency. It operates ONLY on the
/// floor-corner array; `FitService`, `RoomModel`, and the capture methods are
/// untouched.
struct RoomShapeEditorView: View {
    /// The room as captured. Held verbatim so "Reset" can return to it and so
    /// everything except `floorCorners` (id, ceiling height, openings…) passes
    /// straight through to the committed model.
    let room: RoomModel
    /// Commits the corrected room (same room, repositioned corners).
    let onConfirm: (RoomModel) -> Void
    /// Throws this capture away and restarts the sweep.
    let onRecapture: () -> Void

    /// Working copy of the corners, each tagged with a stable id so a drag
    /// handle keeps its identity across SwiftUI updates. We deliberately do NOT
    /// add an id to the shared `PlanePoint` value type (it would break the
    /// Codable/Equatable contract relied on by openings and the Phase-0 JSON
    /// fixtures); the count and order are fixed for a session, so a wrapper
    /// built once at open is enough.
    @State private var editable: [EditableCorner]

    /// World-space bounds of the ORIGINAL corners, captured once. The render
    /// transform is derived from these (never from the live, dragged corners) so
    /// the scale can't drift mid-drag and warp the room.
    private let bounds: PlanBounds

    private let coordinateSpaceName = "roomPlanEditor"

    init(
        room: RoomModel,
        onConfirm: @escaping (RoomModel) -> Void,
        onRecapture: @escaping () -> Void
    ) {
        self.room = room
        self.onConfirm = onConfirm
        self.onRecapture = onRecapture
        _editable = State(initialValue: room.floorCorners.map { EditableCorner(point: $0) })
        bounds = PlanBounds(corners: room.floorCorners)
    }

    /// True once any corner has moved from where it was captured.
    private var hasEdits: Bool {
        zip(editable, room.floorCorners).contains { $0.point != $1 }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                instructions
                planCanvas
                footer
            }
            .navigationTitle("Fix the shape")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Recapture", action: onRecapture)
                        .accessibilityHint("Throws this capture away and starts a new one")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Reset", action: resetEdits)
                        .disabled(!hasEdits)
                        .accessibilityHint("Moves every corner back to where it was captured")
                }
            }
        }
    }

    // MARK: - Chrome

    private var instructions: some View {
        Text("Furniture can push a corner out of place. Drag any corner to where the wall really is.")
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal)
            .padding(.top, 8)
    }

    private var footer: some View {
        Button(action: confirm) {
            Text("Confirm room shape")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
        }
        .buttonStyle(.borderedProminent)
        .tint(.orange)
        .clipShape(Capsule())
        .padding()
        .accessibilityHint("Saves the room with these corner positions")
    }

    // MARK: - Plan

    private var planCanvas: some View {
        GeometryReader { geo in
            let t = PlanTransform(bounds: bounds, size: geo.size)

            ZStack {
                // Polygon fill, edges, and live wall-length labels. Redraws
                // whenever `editable` changes, so labels track the drag.
                Canvas { context, _ in
                    drawPlan(in: context, transform: t)
                }

                // One draggable handle per corner. Handles are real views (not
                // Canvas hit-testing) so each gets a 24pt target, its own
                // gesture, and a VoiceOver label.
                ForEach(Array(editable.enumerated()), id: \.element.id) { index, corner in
                    cornerHandle(index: index, transform: t, size: geo.size)
                        .position(t.project(corner.point))
                }
            }
            .coordinateSpace(name: coordinateSpaceName)
        }
        .padding()
        .frame(maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Top-down floor plan. Drag corners to correct the room shape.")
    }

    private func drawPlan(in context: GraphicsContext, transform t: PlanTransform) {
        let projected = editable.map { t.project($0.point) }
        guard projected.count >= 2 else { return }

        var path = Path()
        path.addLines(projected)
        path.closeSubpath()
        context.fill(path, with: .color(.orange.opacity(0.12)))
        context.stroke(path, with: .color(.orange), lineWidth: 2)

        // Wall-length label at each edge midpoint, computed from the live
        // corner positions so it updates as the user drags.
        for i in editable.indices {
            let a = editable[i].point
            let b = editable[(i + 1) % editable.count].point
            let mid = CGPoint(
                x: (t.project(a).x + t.project(b).x) / 2,
                y: (t.project(a).y + t.project(b).y) / 2
            )
            let label = Text(SnugFormat.meters(a.distance(to: b)))
                .font(.caption2.weight(.medium))
            context.draw(label, at: mid)
        }
    }

    private func cornerHandle(index: Int, transform t: PlanTransform, size: CGSize) -> some View {
        Circle()
            .fill(.orange)
            .overlay(Circle().stroke(.white, lineWidth: 2))
            .frame(width: 24, height: 24)
            .contentShape(Circle())
            .shadow(radius: 1, y: 1)
            .gesture(
                DragGesture(coordinateSpace: .named(coordinateSpaceName))
                    .onChanged { value in
                        // Clamp the finger to the inset region FIRST, then map
                        // back to world meters — a corner can never escape the
                        // canvas, and clamping in canvas space keeps the inset
                        // uniform regardless of zoom.
                        let clamped = t.clampToInset(value.location, in: size)
                        let world = t.world(at: clamped)
                        // Only x/z move. (There is no per-corner y in this model.)
                        editable[index].point.x = world.x
                        editable[index].point.z = world.z
                    }
            )
            .accessibilityLabel("Corner \(index + 1)")
            .accessibilityValue(
                "\(SnugFormat.meters(editable[index].point.x)) by \(SnugFormat.meters(editable[index].point.z))"
            )
    }

    // MARK: - Actions

    private func resetEdits() {
        editable = room.floorCorners.map { EditableCorner(point: $0) }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    private func confirm() {
        var corrected = room
        corrected.floorCorners = editable.map(\.point)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        onConfirm(corrected)
    }
}

// MARK: - Editing model

/// A floor corner plus a stable identity for drag-handle tracking. Local to the
/// editor on purpose — the shared `PlanePoint` stays id-free.
private struct EditableCorner: Identifiable {
    let id = UUID()
    var point: PlanePoint
}

// MARK: - Geometry

/// World-space bounding box of the original corners, captured once so the render
/// transform never derives from the live (dragged) geometry.
private struct PlanBounds {
    let minX: Float
    let minZ: Float
    let width: Float
    let depth: Float

    init(corners: [PlanePoint]) {
        let xs = corners.map(\.x)
        let zs = corners.map(\.z)
        minX = xs.min() ?? 0
        minZ = zs.min() ?? 0
        width = max((xs.max() ?? 0) - minX, 0.01)
        depth = max((zs.max() ?? 0) - minZ, 0.01)
    }
}

/// Maps world-floor coordinates (meters) to canvas points and back. A single
/// uniform `scale` is applied to BOTH axes, so a 20pt horizontal drag and a 20pt
/// vertical drag move the corner the same real-world distance — anything else
/// would shear the room diagonally.
private struct PlanTransform {
    /// Fraction of the canvas reserved as an untouchable margin on each edge.
    static let insetFraction: CGFloat = 0.1

    let scale: CGFloat
    let offset: CGSize
    let bounds: PlanBounds
    let insetX: CGFloat
    let insetY: CGFloat

    init(bounds: PlanBounds, size: CGSize) {
        self.bounds = bounds
        insetX = size.width * Self.insetFraction
        insetY = size.height * Self.insetFraction
        let availableW = max(size.width - 2 * insetX, 1)
        let availableH = max(size.height - 2 * insetY, 1)
        // ONE scale for both axes.
        scale = min(availableW / CGFloat(bounds.width), availableH / CGFloat(bounds.depth))
        let renderedW = CGFloat(bounds.width) * scale
        let renderedH = CGFloat(bounds.depth) * scale
        offset = CGSize(
            width: (size.width - renderedW) / 2,
            height: (size.height - renderedH) / 2
        )
    }

    func project(_ p: PlanePoint) -> CGPoint {
        CGPoint(
            x: offset.width + CGFloat(p.x - bounds.minX) * scale,
            y: offset.height + CGFloat(p.z - bounds.minZ) * scale
        )
    }

    func world(at point: CGPoint) -> (x: Float, z: Float) {
        let x = Float((point.x - offset.width) / scale) + bounds.minX
        let z = Float((point.y - offset.height) / scale) + bounds.minZ
        return (x, z)
    }

    /// Clamps a canvas point into the inset region so a dragged corner can never
    /// leave the visible plan.
    func clampToInset(_ point: CGPoint, in size: CGSize) -> CGPoint {
        CGPoint(
            x: min(max(point.x, insetX), size.width - insetX),
            y: min(max(point.y, insetY), size.height - insetY)
        )
    }
}
