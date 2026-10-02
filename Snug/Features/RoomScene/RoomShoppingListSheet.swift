import SwiftUI

/// "Shop this room": every real product placed in the room, each with its
/// honest fit verdict and a link to the retailer.
///
/// Buying the whole room is the moment Snug exists for, and the commission
/// on a full basket is the business (FounderPivot.md). The fit verdict sits on
/// every card so a piece that won't fit can't sneak into a basket unnoticed.
struct RoomShoppingListSheet: View {
    let list: RoomShoppingList

    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss
    /// Toggled on each retailer tap purely to drive its haptic.
    @State private var openedRetailer = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    summaryCard
                    ForEach(list.entries) { entry in
                        productCard(entry)
                    }
                    Text("Links open the retailer, where you'll see the current price. Snug may earn a commission, at no extra cost to you.")
                        .font(.footnote)
                        .foregroundStyle(SnugTheme.subtle)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 12)
                        .padding(.top, 4)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
            }
            .background(SnugTheme.background)
            .navigationTitle("Shop this room")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(SnugTheme.background)
        .sensoryFeedback(.impact(weight: .light), trigger: openedRetailer)
    }

    // MARK: - Summary

    private var problemCount: Int { list.entries.count - list.fittingCount }

    /// The basket at a glance: how many pieces, and one honest line on fit.
    private var summaryCard: some View {
        HStack(spacing: 14) {
            Image(systemName: problemCount == 0 ? "checkmark.seal.fill" : "ruler.fill")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(problemCount == 0 ? SnugTheme.sage : FitResult.State.tooCloseToCall.tint)
                .frame(width: 52, height: 52)
                .background((problemCount == 0 ? SnugTheme.sage : FitResult.State.tooCloseToCall.tint).opacity(0.14), in: .circle)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text("\(list.pieceCount) \(list.pieceCount == 1 ? "piece" : "pieces") in this room")
                    .font(.system(.title3, design: .rounded).weight(.bold))
                    .foregroundStyle(SnugTheme.ink)
                Text(problemCount == 0
                     ? "Everything here fits your room."
                     : "\(problemCount) \(problemCount == 1 ? "product needs" : "products need") a closer look before you buy.")
                    .font(.subheadline)
                    .foregroundStyle(SnugTheme.subtle)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .background(SnugTheme.surface, in: .rect(cornerRadius: 20))
        .accessibilityElement(children: .combine)
    }

    // MARK: - Product card

    private func productCard(_ entry: RoomShoppingList.Entry) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                thumbnail(entry.item)
                    .frame(width: 76, height: 76)
                    .background(Color.white)
                    .clipShape(.rect(cornerRadius: 14))
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 6) {
                    Text(entry.item.name)
                        .font(.system(.subheadline, design: .rounded).weight(.semibold))
                        .foregroundStyle(SnugTheme.ink)
                        .lineLimit(2)
                    Text(entry.quantity > 1
                         ? "\(entry.item.brand) · \(entry.item.footprintLabel) · ×\(entry.quantity)"
                         : "\(entry.item.brand) · \(entry.item.footprintLabel)")
                        .font(.caption)
                        .foregroundStyle(SnugTheme.subtle)
                        .lineLimit(1)
                    fitChip(entry.fit)
                }
                Spacer(minLength: 0)
            }

            Button {
                openedRetailer.toggle()
                openURL(entry.item.outboundURL)
            } label: {
                Label("See price at \(entry.item.retailerName)", systemImage: "arrow.up.right")
                    .font(.system(.subheadline, design: .rounded).weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
            .tint(SnugTheme.clay)
            .clipShape(.capsule)
            .accessibilityHint("Opens the product at \(entry.item.retailerName)")
        }
        .padding(16)
        .background(SnugTheme.surface, in: .rect(cornerRadius: 20))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(entry.item.name), \(entry.quantity > 1 ? "\(entry.quantity) pieces, " : "")\(entry.fit.headline)")
    }

    private func fitChip(_ state: FitResult.State) -> some View {
        Label(state.headline, systemImage: state.symbol)
            .font(.caption.weight(.semibold))
            .foregroundStyle(state.tint)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(state.tint.opacity(0.12), in: .capsule)
    }

    @ViewBuilder private func thumbnail(_ item: CatalogItem) -> some View {
        if let url = item.imageURL {
            CachedThumbnailImage(
                url: CatalogBrowseOverlay.thumbnailSizedURL(url),
                targetSize: CGSize(width: 76, height: 76),
                contentMode: .fit
            ) {
                placeholderIcon(item)
            }
            .padding(6)
        } else {
            placeholderIcon(item)
        }
    }

    private func placeholderIcon(_ item: CatalogItem) -> some View {
        Image(systemName: item.category.symbolName)
            .font(.system(size: 24, weight: .semibold))
            .foregroundStyle(SnugTheme.clay)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
