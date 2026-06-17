import SwiftUI

/// A small floating pill shown in the lower screen when a furniture piece is
/// selected: its category, a "Fine Tune" button (opens the precision sheet), and
/// a trash button. It's a 2D overlay, not anchored to the entity in 3D. The host
/// positions it and animates its appear/disappear.
struct FurnitureMicroPill: View {
    let category: FurnitureCategory
    let onFineTune: () -> Void
    let onTrash: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Label(category.displayName, systemImage: category.symbolName)
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .foregroundStyle(SnugTheme.ink)

            Divider().frame(height: 22)

            Button(action: onFineTune) {
                Text("Fine Tune")
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .foregroundStyle(SnugTheme.clay)
            }

            Divider().frame(height: 22)

            Button(action: onTrash) {
                Image(systemName: "trash")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(SnugTheme.subtle)
            }
            .accessibilityLabel("Remove \(category.displayName)")
        }
        .padding(.horizontal, 18)
        .frame(height: 48)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
        .accessibilityElement(children: .contain)
    }
}
