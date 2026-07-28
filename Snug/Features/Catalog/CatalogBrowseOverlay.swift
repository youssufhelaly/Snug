import SwiftUI
import UIKit

/// The shop: a resizable bottom sheet the room view's `+ Add` button presents,
/// listing real catalog products to drop into the room. Cards fill the sheet as
/// a three-column vertically scrolling grid; the user drags the sheet grabber to
/// grow it to full height or shrink it back to half. Picking a product places it
/// at its TRUE size, and the diorama runs the fit check (CLAUDE.md core loop:
/// scan → redesign → buy with an honest fit).
///
/// Category chips filter the grid; an empty / failed catalog shows a friendly
/// message rather than a blank sheet (CLAUDE.md: errors are never blank).
struct CatalogBrowseOverlay: View {
    @Environment(CatalogService.self) private var catalog
    @Environment(SandboxLibrary.self) private var sandbox

    /// Pick a real, buyable product (Shop tab).
    let onSelect: (CatalogItem) -> Void
    /// Pick a generic "digital clay" shape to sketch with (Ideas tab).
    let onSelectSandbox: (SandboxAsset) -> Void
    let onClose: () -> Void

    /// The two isolated tracks, surfaced as one picker. "Shop" = Verified products
    /// (price, fit, buy); "Ideas" = elastic sandbox shapes (sketch, then find real
    /// matches). The split makes "real & buyable" vs "ideation" unmistakable.
    private enum BrowseTab: String, CaseIterable, Identifiable {
        case shop, ideas
        var id: String { rawValue }
        var title: String { self == .shop ? "Shop" : "Ideas" }
    }

    @State private var tab: BrowseTab = .shop
    @State private var category: FurnitureCategory?

    private var visibleItems: [CatalogItem] { catalog.items(in: category) }
    private var visibleAssets: [SandboxAsset] { sandbox.assets(in: category) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            tabPicker
            switch tab {
            case .shop:  shopContent
            case .ideas: ideasContent
            }
            disclosure
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // Half-height by default so the room stays visible; the grabber lets the
        // user drag the sheet taller or shorter, and the room stays interactive
        // underneath at the half detent.
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(.regularMaterial)
        .presentationBackgroundInteraction(.enabled(upThrough: .medium))
        .task { await catalog.load() }
        .task { await sandbox.load() }
        // A category chosen on one tab may not exist on the other; reset on switch.
        .onChange(of: tab) { category = nil }
    }

    private var tabPicker: some View {
        Picker("Browse", selection: $tab) {
            ForEach(BrowseTab.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
    }

    @ViewBuilder private var shopContent: some View {
        if catalog.items.isEmpty {
            emptyState
        } else {
            categoryChips(catalog.availableCategories)
            productScroller
        }
    }

    @ViewBuilder private var ideasContent: some View {
        if sandbox.assets.isEmpty {
            sandboxEmptyState
        } else {
            categoryChips(sandbox.availableCategories)
            sandboxScroller
        }
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

    private func categoryChips(_ categories: [FurnitureCategory]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip(title: "All", isOn: category == nil) { category = nil }
                ForEach(categories, id: \.self) { c in
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

    /// Three equal columns; the grid is lazy so 180 cards don't all fetch their
    /// photo the moment the sheet opens — only the visible rows load.
    private var gridColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 12), count: 3)
    }

    private var productScroller: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVGrid(columns: gridColumns, spacing: 16) {
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
                    .frame(maxWidth: .infinity)
                    .frame(height: 92)
                    .clipShape(RoundedRectangle(cornerRadius: 12))

                // Width-pinned to the column so long Amazon titles truncate
                // instead of stretching the card; two reserved lines keep every
                // card the same height.
                Text(item.name)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(SnugTheme.ink)
                    .lineLimit(2, reservesSpace: true)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 6) {
                    Text(item.brand)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(SnugTheme.subtle)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(item.formattedPrice)
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(SnugTheme.ink)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.name) by \(item.brand), \(item.formattedPrice)")
        .accessibilityHint("Adds it to your room")
    }

    // MARK: - Ideas tab (sandbox shapes)

    private var sandboxScroller: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVGrid(columns: gridColumns, spacing: 16) {
                ForEach(visibleAssets) { asset in
                    sandboxCard(asset)
                }
            }
            .padding(.vertical, 4)
        }
    }

    /// A clay-shape card: stylized swatch + glyph and the STYLE name, with a
    /// "Sketch" tag instead of a price — it makes no purchase claim.
    private func sandboxCard(_ asset: SandboxAsset) -> some View {
        Button { onSelectSandbox(asset) } label: {
            VStack(alignment: .leading, spacing: 8) {
                ZStack {
                    swatch(asset.colorCategory)
                    Image(systemName: asset.category.symbolName)
                        .font(.system(size: 26))
                        .foregroundStyle(.white.opacity(0.9))
                        .shadow(radius: 1)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 92)
                .clipShape(RoundedRectangle(cornerRadius: 12))

                Text(asset.name)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(SnugTheme.ink)
                    .lineLimit(2, reservesSpace: true)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 6) {
                    Text(asset.style.displayName)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(SnugTheme.subtle)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text("Sketch")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(SnugTheme.subtle)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(SnugTheme.surface, in: Capsule())
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(asset.name), \(asset.style.displayName) sketch shape")
        .accessibilityHint("Adds an elastic shape you can resize to fit your space")
    }

    /// A perceptual-category swatch (no true color — sandbox makes no color claim).
    private func swatch(_ category: FurnitureColorCategory) -> Color {
        let rgb = category.representativeRGB
        return Color(red: Double(rgb.x), green: Double(rgb.y), blue: Double(rgb.z))
    }

    private var sandboxEmptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "scribble.variable")
                .font(.system(size: 28))
                .foregroundStyle(SnugTheme.subtle)
            Text(sandbox.loadError ?? "No design shapes available yet.")
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .foregroundStyle(SnugTheme.subtle)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }

    /// Bundled product art when `thumbnailAssetName` resolves to a real asset;
    /// then the remote Amazon photo when the item carries an `imageURL`; otherwise
    /// the product's true color as a swatch with its category glyph. The
    /// `UIImage(named:)` guard means a missing/placeholder asset name degrades to
    /// the next step instead of an empty box, and the remote path shows the
    /// swatch while loading and whenever the fetch fails (e.g. offline) — so the
    /// catalog stays fully browsable with no network.
    @ViewBuilder private func thumbnail(_ item: CatalogItem) -> some View {
        if let name = item.thumbnailAssetName, UIImage(named: name) != nil {
            Image(name)
                .resizable()
                .scaledToFit()
                .padding(4)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.white)
        } else if let url = item.imageURL {
            // Product shots come on white backgrounds, so show them whole on a
            // white tile (`.fit`) — filling zooms/crops wide images (L-shaped
            // sofas) until they bleed past the card.
            CachedThumbnailImage(
                url: Self.thumbnailSizedURL(url),
                targetSize: CGSize(width: 132, height: 92),
                contentMode: .fit
            ) {
                swatchThumbnail(item)
            }
            .padding(4)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.white)
        } else {
            swatchThumbnail(item)
        }
    }

    /// Amazon media URLs serve any size via a filename suffix. Card art renders
    /// at 132×92pt, so ask for a ~300px edge instead of the multi-megapixel
    /// original — an order of magnitude less to download and decode per card.
    /// Non-Amazon or already-sized URLs pass through untouched.
    static func thumbnailSizedURL(_ url: URL) -> URL {
        guard url.host()?.hasSuffix("media-amazon.com") == true,
              url.path().hasSuffix(".jpg"),
              !url.lastPathComponent.contains("._"),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return url }
        // `url.path()` returns the percent-ENCODED path; assign it via
        // `percentEncodedPath` so an escape like `%2B` isn't re-encoded to
        // `%252B` (a 404 on the CDN).
        components.percentEncodedPath = String(url.path().dropLast(4)) + "._AC_SX300_.jpg"
        return components.url ?? url
    }

    /// The no-art fallback: true-color swatch + category glyph.
    private func swatchThumbnail(_ item: CatalogItem) -> some View {
        ZStack {
            swatchColor(item)
            Image(systemName: item.category.symbolName)
                .font(.system(size: 26))
                .foregroundStyle(.white.opacity(0.9))
                .shadow(radius: 1)
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
    @ViewBuilder private var disclosure: some View {
        let copy = tab == .shop
            ? "Prices and links go to the retailer. Snug may earn a commission, at no extra cost to you."
            : "Sketch shapes are for planning only — resize one to fit your space, then find real, buyable furniture that matches."
        Text(copy)
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
