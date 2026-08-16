import SwiftUI

/// The room-surfaces picker: three curated swatch rows (walls, floor, and the
/// frame's backdrop) that set the room's `RoomSurfaceStyle`. Presented as a
/// short sheet with the diorama live behind it, so every pick previews
/// instantly.
///
/// "Not set" is a first-class option, not an error state: until the user tells
/// us their colors, the room stays neutral —
/// claiming a color we don't know would be false precision.
struct RoomSurfacesSheet: View {
    let style: RoomSurfaceStyle
    let onChange: (RoomSurfaceStyle) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            header
            section(title: "Walls") {
                notSetSwatch(isOn: style.wall == nil, label: "Walls not set") {
                    update { $0.wall = nil }
                }
                ForEach(WallColorChoice.allCases) { choice in
                    swatch(
                        color: Color(choice.color),
                        name: choice.displayName,
                        isOn: style.wall == choice
                    ) {
                        update { $0.wall = choice }
                    }
                }
            }
            section(title: "Floor") {
                notSetSwatch(isOn: style.floor == nil, label: "Floor not set") {
                    update { $0.floor = nil }
                }
                ForEach(FloorMaterialChoice.allCases) { choice in
                    swatch(
                        color: Color(choice.color),
                        name: choice.displayName,
                        isOn: style.floor == choice
                    ) {
                        update { $0.floor = choice }
                    }
                }
            }
            // The backdrop is the frame around the room, not a real surface, so
            // there is no "not set" honesty state — the first swatch IS the
            // default terracotta, and playful picks are fair game here.
            section(title: "Background") {
                swatch(
                    color: Color(RoomPalette.standard.background),
                    name: "Terracotta",
                    isOn: style.backdrop == nil
                ) {
                    update { $0.backdrop = nil }
                }
                ForEach(BackdropColorChoice.allCases) { choice in
                    swatch(
                        color: Color(choice.color),
                        name: choice.displayName,
                        isOn: style.backdrop == choice
                    ) {
                        update { $0.backdrop = choice }
                    }
                }
            }
            Text("Your room shows these colors exactly as picked — never stylized.")
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(SnugTheme.subtle)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(SnugTheme.background)
        .presentationDetents([.height(440)])
        .presentationCornerRadius(24)
        // Keep the diorama interactive/visible behind the sheet — the whole point
        // is watching the room change as you tap.
        .presentationBackgroundInteraction(.enabled(upThrough: .height(440)))
    }

    private var header: some View {
        HStack {
            Text("Room surfaces")
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundStyle(SnugTheme.ink)
            Spacer()
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(SnugTheme.subtle)
                    .frame(width: 30, height: 30)
                    .background(SnugTheme.ink.opacity(0.06), in: Circle())
            }
            .accessibilityLabel("Close room surfaces")
        }
    }

    private func section(title: String, @ViewBuilder swatches: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(SnugTheme.subtle)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) { swatches() }
                    .padding(.horizontal, 2)
                    .padding(.vertical, 2)
            }
        }
    }

    /// One tappable color disc with its name beneath and a clay selection ring.
    private func swatch(color: Color, name: String, isOn: Bool,
                        action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Circle()
                    .fill(color)
                    .frame(width: 44, height: 44)
                    .overlay(Circle().stroke(SnugTheme.ink.opacity(0.12), lineWidth: 1))
                    .overlay(Circle().stroke(SnugTheme.clay, lineWidth: isOn ? 3 : 0))
                Text(name)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(isOn ? SnugTheme.ink : SnugTheme.subtle)
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(name)
        .accessibilityAddTraits(isOn ? [.isSelected, .isButton] : .isButton)
    }

    /// The honest "we don't know" option: a slashed disc that clears the choice.
    private func notSetSwatch(isOn: Bool, label: String,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Circle()
                    .fill(SnugTheme.surface)
                    .frame(width: 44, height: 44)
                    .overlay {
                        Image(systemName: "circle.slash")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundStyle(SnugTheme.subtle)
                    }
                    .overlay(Circle().stroke(SnugTheme.ink.opacity(0.12), lineWidth: 1))
                    .overlay(Circle().stroke(SnugTheme.clay, lineWidth: isOn ? 3 : 0))
                Text("Not set")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(isOn ? SnugTheme.ink : SnugTheme.subtle)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityHint("Keeps the default look until you choose a color")
        .accessibilityAddTraits(isOn ? [.isSelected, .isButton] : .isButton)
    }

    private func update(_ mutate: (inout RoomSurfaceStyle) -> Void) {
        var next = style
        mutate(&next)
        guard next != style else { return }
        onChange(next)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }
}
