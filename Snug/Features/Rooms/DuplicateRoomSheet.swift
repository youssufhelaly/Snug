import SwiftUI

/// The duplicate-room chooser: pick which existing furniture pieces come along
/// when you fork a room — none, some, or all. Geometry, openings, and surface
/// colors always copy; only the furniture is opt-in, so you can spin off an empty
/// shell of the same room or a full clone.
///
/// Presented from the "My rooms" grid. The furniture list is passed in already
/// filtered to active (non-cleared) pieces; confirming hands the chosen ids back
/// so `RoomStore.duplicate` can build the copy.
struct DuplicateRoomSheet: View {
    /// Active, non-cleared pieces offered for copying.
    let furniture: [FurnitureFootprint]
    /// Called with the chosen piece ids on confirm. An empty set is a valid choice
    /// (duplicate the bare room).
    let onDuplicate: (Set<UUID>) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<UUID>

    init(furniture: [FurnitureFootprint], onDuplicate: @escaping (Set<UUID>) -> Void) {
        self.furniture = furniture
        self.onDuplicate = onDuplicate
        // Default to copying everything — the most common intent when forking a
        // finished room; deselecting is one tap away.
        _selected = State(initialValue: Set(furniture.map(\.id)))
    }

    private var allSelected: Bool { !furniture.isEmpty && selected.count == furniture.count }

    var body: some View {
        NavigationStack {
            Group {
                if furniture.isEmpty {
                    emptyState
                } else {
                    list
                }
            }
            .background(SnugTheme.background.ignoresSafeArea())
            .navigationTitle("Duplicate room")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Duplicate") {
                        onDuplicate(selected)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
        .tint(SnugTheme.clay)
        .presentationDetents([.medium, .large])
        .presentationCornerRadius(24)
    }

    // MARK: - Pieces

    private var list: some View {
        List {
            Section {
                ForEach(furniture) { piece in
                    row(piece)
                }
            } header: {
                HStack {
                    Text("\(selected.count) of \(furniture.count) selected")
                        .textCase(nil)
                    Spacer()
                    Button(allSelected ? "Deselect all" : "Select all") {
                        selected = allSelected ? [] : Set(furniture.map(\.id))
                    }
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .textCase(nil)
                }
            } footer: {
                Text("The room's shape and colors always copy. Choose which furniture comes along — none, some, or all.")
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
    }

    /// One tappable furniture row: category glyph, name, an honest subtitle, and a
    /// clay check. Tapping the whole row toggles it (larger target than a trailing
    /// switch), and the row carries the selection trait for VoiceOver.
    private func row(_ piece: FurnitureFootprint) -> some View {
        let isOn = selected.contains(piece.id)
        return Button {
            toggle(piece.id)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: piece.category.symbolName)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(SnugTheme.clay)
                    .frame(width: 36, height: 36)
                    .background(SnugTheme.clay.opacity(0.14), in: Circle())
                VStack(alignment: .leading, spacing: 1) {
                    Text(piece.category.displayName)
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                        .foregroundStyle(SnugTheme.ink)
                    Text(subtitle(piece))
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(SnugTheme.subtle)
                }
                Spacer(minLength: 8)
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(isOn ? SnugTheme.clay : SnugTheme.subtle.opacity(0.5))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(SnugTheme.surface)
        .accessibilityLabel("\(piece.category.displayName), \(subtitle(piece))")
        .accessibilityAddTraits(isOn ? [.isSelected, .isButton] : .isButton)
    }

    /// Rooms with no furniture still duplicate — just the shell — so the sheet
    /// stays honest rather than blocking. Friendly, never blank (CLAUDE.md).
    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "square.on.square.dashed")
                .font(.system(size: 44))
                .foregroundStyle(SnugTheme.sage)
                .accessibilityHidden(true)
            Text("Copy this room")
                .font(.title3.weight(.bold))
                .foregroundStyle(SnugTheme.ink)
            Text("This room has no furniture yet. Duplicating makes a fresh copy of its shape and colors.")
                .font(.system(size: 15, weight: .medium, design: .rounded))
                .multilineTextAlignment(.center)
                .foregroundStyle(SnugTheme.subtle)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Helpers

    private func toggle(_ id: UUID) {
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
        UISelectionFeedbackGenerator().selectionChanged()
    }

    /// An honest one-line descriptor: a sandbox piece reads as "Sketch" (it makes
    /// no purchase claim), everything else shows its detected color category.
    private func subtitle(_ piece: FurnitureFootprint) -> String {
        piece.sandboxAssetID != nil ? "Sketch" : piece.appearance.colorCategory.displayName
    }
}
