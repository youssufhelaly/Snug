import SwiftUI

/// The category carousel, surfaced as a half-height bottom overlay by the room
/// view's `+ Add` button. Tapping a category creates that piece; the host places
/// it inside the room, selects it, and dismisses the carousel.
struct FurnitureCarouselOverlay: View {
    let onSelect: (FurnitureCategory) -> Void
    let onClose: () -> Void

    private static let categories: [FurnitureCategory] =
        [.sofa, .chair, .diningChair, .bed, .desk, .diningTable, .coffeeTable, .dresser, .bookshelf, .tvStand]

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Add furniture")
                        .font(.system(.headline, design: .rounded))
                        .foregroundStyle(SnugTheme.ink)
                    Spacer()
                    Button(action: onClose) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 22))
                            .foregroundStyle(SnugTheme.subtle)
                    }
                    .accessibilityLabel("Close")
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(Self.categories, id: \.self) { category in
                            card(category)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            .padding(20)
            .padding(.bottom, 12)
            .frame(maxWidth: .infinity)
            .background(.regularMaterial, in: UnevenRoundedRectangle(topLeadingRadius: 20, topTrailingRadius: 20))
        }
        .ignoresSafeArea(edges: .bottom)
    }

    private func card(_ category: FurnitureCategory) -> some View {
        Button { onSelect(category) } label: {
            VStack(spacing: 6) {
                Image(systemName: category.symbolName)
                    .font(.system(size: 24))
                    .foregroundStyle(SnugTheme.clay)
                Text(category.displayName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(SnugTheme.ink)
                    .lineLimit(1)
            }
            .frame(width: 80, height: 80)
            .background(SnugTheme.surface, in: RoundedRectangle(cornerRadius: 16))
        }
        .accessibilityLabel("Add \(category.displayName)")
    }
}
