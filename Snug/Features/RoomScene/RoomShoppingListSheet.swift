import SwiftUI

/// "Shop this room": every real product placed in the room, each with its
/// honest fit verdict and a link to the retailer.
///
/// Buying the whole room is the moment Snug exists for, and the commission
/// on a full basket is the business (FounderPivot.md). The fit verdict sits on
/// every row so a piece that won't fit can't sneak into a basket unnoticed.
struct RoomShoppingListSheet: View {
    let list: RoomShoppingList

    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(list.entries) { entry in
                        row(entry)
                    }
                } header: {
                    summary
                } footer: {
                    Text("Links open the retailer, where you'll see the current price. Snug may earn a commission, at no extra cost to you.")
                        .font(.footnote)
                }
            }
            .listStyle(.insetGrouped)
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
    }

    /// One honest line about the whole basket.
    private var summary: some View {
        let problems = list.entries.count - list.fittingCount
        let text = problems == 0
            ? "Everything here fits your room."
            : "\(problems) \(problems == 1 ? "product needs" : "products need") a closer look before you buy."
        return Text(text)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(problems == 0 ? SnugTheme.sage : FitResult.State.tooCloseToCall.tint)
            .textCase(nil)
            .padding(.bottom, 4)
    }

    private func row(_ entry: RoomShoppingList.Entry) -> some View {
        HStack(alignment: .top, spacing: 12) {
            thumbnail(entry.item)
                .frame(width: 60, height: 60)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(entry.item.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(SnugTheme.ink)
                    .lineLimit(2)
                Text(entry.quantity > 1
                     ? "\(entry.item.brand) · \(entry.item.footprintLabel) · ×\(entry.quantity)"
                     : "\(entry.item.brand) · \(entry.item.footprintLabel)")
                    .font(.caption)
                    .foregroundStyle(SnugTheme.subtle)
                    .lineLimit(1)
                Label(entry.fit.headline, systemImage: entry.fit.symbol)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(entry.fit.tint)
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    openURL(entry.item.outboundURL)
                } label: {
                    Label("See price at \(entry.item.retailerName)", systemImage: "arrow.up.right")
                        .font(.footnote.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .tint(SnugTheme.clay)
                .padding(.top, 2)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(entry.item.name), \(entry.quantity > 1 ? "\(entry.quantity) pieces, " : "")\(entry.fit.headline)")
        .accessibilityHint("Opens the product at \(entry.item.retailerName)")
    }

    @ViewBuilder private func thumbnail(_ item: CatalogItem) -> some View {
        if let url = item.imageURL {
            CachedThumbnailImage(
                url: CatalogBrowseOverlay.thumbnailSizedURL(url),
                targetSize: CGSize(width: 60, height: 60),
                contentMode: .fit
            ) {
                placeholderIcon(item)
            }
            .padding(4)
        } else {
            placeholderIcon(item)
        }
    }

    private func placeholderIcon(_ item: CatalogItem) -> some View {
        Image(systemName: item.category.symbolName)
            .font(.system(size: 22, weight: .semibold))
            .foregroundStyle(SnugTheme.clay)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
