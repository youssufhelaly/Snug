import SwiftUI
import UIKit
import simd

/// The bridge UI: given the size a user sculpted an Ideation-Sandbox piece to,
/// list real Verified products of a similar footprint and let them swap one in.
///
/// This is the LOCAL, offline half of the reverse-search (IDEAS.md):
/// `SpatialRecommendationEngine` does a pure dimensional match over the bundled
/// catalog. Crucially, each candidate also gets the HONEST four-state fit check —
/// run on the *real product's true dimensions* at the sketch's spot in the real
/// room — so the user sees "matches this footprint AND actually fits", never a
/// look-alike that jams the wall. Picking one re-runs nothing fake: the placed
/// Verified piece carries its own true size from here on.
struct SandboxMatchSheet: View {
    @Environment(CatalogService.self) private var catalog
    @Environment(\.dismiss) private var dismiss

    /// The sketched `(width, depth, height)` in meters the user resized to.
    let target: SIMD3<Float>
    let category: FurnitureCategory
    let room: RoomModel
    /// Where the sketch sits on the floor (x = world X, y = world Z) and its yaw —
    /// so a swapped product lands in the same place and its fit is checked there.
    let floorXZ: SIMD2<Float>
    let yRotation: Float
    /// The sandbox piece being replaced — excluded from the obstacle set so it
    /// isn't treated as blocking its own replacement.
    let replacingID: UUID
    let onPick: (CatalogItem) -> Void

    private var matches: [SpatialRecommendationEngine.Match] {
        SpatialRecommendationEngine.matches(
            forTarget: target, category: category, in: catalog.items)
    }

    var body: some View {
        NavigationStack {
            Group {
                if matches.isEmpty {
                    emptyState
                } else {
                    List(matches) { match in
                        row(match)
                            .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Real matches")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .principal) { titleBlock }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var titleBlock: some View {
        VStack(spacing: 1) {
            Text("Real matches")
                .font(.system(size: 16, weight: .bold, design: .rounded))
                .foregroundStyle(SnugTheme.ink)
            Text("for your \(dimensionString) sketch")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(SnugTheme.subtle)
        }
    }

    /// Sketched size in centimeters — rounded, never false precision.
    private var dimensionString: String {
        let cm: (Float) -> Int = { Int(($0 * 100).rounded()) }
        return "\(cm(target.x)) × \(cm(target.y)) × \(cm(target.z)) cm"
    }

    private func row(_ match: SpatialRecommendationEngine.Match) -> some View {
        let item = match.item
        return Button {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            onPick(item)
            dismiss()
        } label: {
            HStack(spacing: 12) {
                swatch(item)
                    .frame(width: 56, height: 56)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.name)
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(SnugTheme.ink)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        Text(item.brand).font(.system(size: 12, weight: .medium))
                            .foregroundStyle(SnugTheme.subtle)
                        Text("·").foregroundStyle(SnugTheme.subtle)
                        Text(item.formattedPrice)
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                            .foregroundStyle(SnugTheme.ink)
                    }
                    FitBadge(state: fitState(for: item))
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(SnugTheme.subtle)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.name) by \(item.brand), \(item.formattedPrice). \(fitState(for: item).headline)")
        .accessibilityHint("Replaces your sketch with this real product")
    }

    /// The honest fit this real product gets at the sketch's spot — its TRUE size
    /// against the real room and other kept pieces.
    private func fitState(for item: CatalogItem) -> FitResult.State {
        let placed = item.makeFootprint(at: floorXZ, yRotation: yRotation)
        return room.fitResult(for: placed, excluding: replacingID).state
    }

    private func swatch(_ item: CatalogItem) -> some View {
        ZStack {
            Color(red: Double(item.trueColorRGB.x),
                  green: Double(item.trueColorRGB.y),
                  blue: Double(item.trueColorRGB.z))
            Image(systemName: item.category.symbolName)
                .font(.system(size: 18))
                .foregroundStyle(.white.opacity(0.9))
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No real matches yet", systemImage: "ruler")
        } description: {
            Text("Nothing in the catalog is close to your \(dimensionString) sketch. Try resizing it, or check back as the catalog grows.")
        }
    }
}
