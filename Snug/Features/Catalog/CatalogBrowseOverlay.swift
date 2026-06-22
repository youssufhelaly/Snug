import SwiftUI
import UIKit

/// The shop: a bottom overlay the room view's `+ Add` button raises, listing real
/// catalog products to drop into the room. Replaces the old generic-category
/// carousel — picking a product places it at its TRUE size, and the diorama runs
/// the fit check (CLAUDE.md core loop: scan → redesign → buy with an honest fit).
///
/// Category chips filter the grid; an empty / failed catalog shows a friendly
/// message rather than a blank sheet (CLAUDE.md: errors are never blank).
struct CatalogBrowseOverlay: View {
    @Environment(CatalogService.self) private var catalog

    let onSelect: (CatalogItem) -> Void
    let onClose: () -> Void

    @State private var category: FurnitureCategory?

    private var visibleItems: [CatalogItem] {
        catalog.items(in: category)
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(alignment: .leading, spacing: 14) {
                header
                if catalog.items.isEmpty {
                    emptyState
                } else {
                    categoryChips
                    productScroller
                }
                disclosure
            }
            .padding(20)
            .padding(.bottom, 12)
            .frame(maxWidth: .infinity)
            .background(.regularMaterial, in: UnevenRoundedRectangle(topLeadingRadius: 24, topTrailingRadius: 24))
        }
        .ignoresSafeArea(edges: .bottom)
        .task { await catalog.load() }
    }

    private var header: some View {
        HStack {
            Text("Add furniture")
                .font(.system(.title3, design: .rounded).weight(.bold))
                .foregroundStyle(SnugTheme.ink)
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(SnugTheme.subtle)
            }
            .accessibilityLabel("Close")
        }
    }

    private var categoryChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip(title: "All", isOn: category == nil) { category = nil }
                ForEach(catalog.availableCategories, id: \.self) { c in
                    chip(title: c.displayName, isOn: category == c) { category = c }
                }
            }
        }
    }

    private func chip(title: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(isOn ? .white : SnugTheme.ink)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(isOn ? SnugTheme.clay : SnugTheme.surface, in: Capsule())
        }
        .accessibilityAddTraits(isOn ? [.isSelected, .isButton] : .isButton)
    }

    private var productScroller: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(visibleItems) { item in
                    productCard(item)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func productCard(_ item: CatalogItem) -> some View {
        Button { onSelect(item) } label: {
            VStack(alignment: .leading, spacing: 8) {
                thumbnail(item)
                    .frame(width: 132, height: 92)
                    .clipShape(RoundedRectangle(cornerRadius: 12))

                Text(item.name)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(SnugTheme.ink)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(item.brand)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(SnugTheme.subtle)
                    Spacer(minLength: 4)
                    Text(item.formattedPrice)
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(SnugTheme.ink)
                }
                .frame(width: 132)
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.name) by \(item.brand), \(item.formattedPrice)")
        .accessibilityHint("Adds it to your room")
    }

    /// Bundled product art when `thumbnailAssetName` resolves to a real asset;
    /// otherwise the product's true color as a swatch with its category glyph. The
    /// `UIImage(named:)` guard means a missing/placeholder asset name degrades to
    /// the swatch instead of an empty box — so the catalog works before art lands
    /// and lights up automatically once thumbnails are added to the asset catalog.
    @ViewBuilder private func thumbnail(_ item: CatalogItem) -> some View {
        if let name = item.thumbnailAssetName, UIImage(named: name) != nil {
            Image(name)
                .resizable()
                .scaledToFill()
        } else {
            ZStack {
                swatchColor(item)
                Image(systemName: item.category.symbolName)
                    .font(.system(size: 26))
                    .foregroundStyle(.white.opacity(0.9))
                    .shadow(radius: 1)
            }
        }
    }

    /// The product's true color as a swatch (BUY-mode color category).
    private func swatchColor(_ item: CatalogItem) -> Color {
        Color(red: Double(item.trueColorRGB.x),
              green: Double(item.trueColorRGB.y),
              blue: Double(item.trueColorRGB.z))
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "shippingbox")
                .font(.system(size: 28))
                .foregroundStyle(SnugTheme.subtle)
            Text(catalog.loadError ?? "No furniture available yet.")
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .foregroundStyle(SnugTheme.subtle)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }

    /// Affiliate / out-link disclosure (CLAUDE.md hard rule: relationships are
    /// disclosed in UI copy, no hidden costs).
    private var disclosure: some View {
        Text("Prices and links go to the retailer. Snug may earn a commission, at no extra cost to you.")
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(SnugTheme.subtle)
            .fixedSize(horizontal: false, vertical: true)
    }
}

extension CatalogItem {
    /// Display price, e.g. "$1,199". Whole dollars — we never imply cent-level
    /// precision on a retailer price that can shift. Main-actor isolated: it's
    /// only ever read from SwiftUI view bodies and uses a shared formatter cache.
    @MainActor var formattedPrice: String {
        let formatter = CatalogItem.priceFormatter(for: currencyCode)
        let dollars = NSNumber(value: Double(priceCents) / 100.0)
        return formatter.string(from: dollars) ?? "$\(priceCents / 100)"
    }

    /// Cached currency formatters keyed by currency code. `NumberFormatter` is
    /// costly to build (it initializes locale state), and `formattedPrice` runs
    /// once per product card on every render pass — so we reuse one per code
    /// instead of allocating each call. Accessed on the main thread (SwiftUI
    /// rendering), so the plain dictionary needs no extra synchronization.
    @MainActor private static var priceFormatters: [String: NumberFormatter] = [:]

    @MainActor private static func priceFormatter(for currencyCode: String) -> NumberFormatter {
        if let cached = priceFormatters[currencyCode] { return cached }
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = currencyCode
        formatter.maximumFractionDigits = 0
        priceFormatters[currencyCode] = formatter
        return formatter
    }
}
