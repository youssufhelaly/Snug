import SwiftUI

/// Post-capture furniture step: arrange existing + added furniture over the live
/// PLAY diorama. The persistent `FurniturePlacementTray` handles both adding
/// (carousel) and transforming (sliders); furniture entities tint red/amber/green
/// from `FurniturePlacementValidator` as they move. "Done" commits the kept,
/// non-cleared furniture into the room (which then feeds `FitService`).
///
/// There is no modal sheet — the tray IS the UI (per the Phase 2 placement spec).
struct DeclutterView: View {
    let room: RoomModel
    /// Called with the room whose `detectedFurniture` reflects the user's
    /// placements/removals. The caller persists it (via `RoomStore`).
    let onCommit: (RoomModel) -> Void

    @State private var footprints: [FurnitureFootprint]
    @State private var selectedFootprintID: UUID?

    init(room: RoomModel, onCommit: @escaping (RoomModel) -> Void) {
        self.room = room
        self.onCommit = onCommit
        _footprints = State(initialValue: room.detectedFurniture)
    }

    /// Live fit classification per footprint, recomputed whenever a footprint
    /// changes (on edits — not per frame). Drives the entity tinting.
    private var placementStates: [UUID: PlacementState] {
        var states: [UUID: PlacementState] = [:]
        for footprint in footprints where !footprint.isCleared {
            states[footprint.id] = FurniturePlacementValidator.validate(
                footprint: footprint,
                against: room,
                existingFootprints: footprints
            )
        }
        return states
    }

    var body: some View {
        RoomSceneView(
            room: room,
            mode: .play,
            editableFurniture: footprints,
            placementStates: placementStates
        )
        .ignoresSafeArea()
        .overlay(alignment: .top) { topBar }
        .safeAreaInset(edge: .bottom) {
            FurniturePlacementTray(
                footprints: $footprints,
                room: room,
                selectedFootprintID: $selectedFootprintID
            )
        }
    }

    private var topBar: some View {
        HStack {
            Spacer()
            Button(action: commit) {
                Text("Done")
                    .font(.system(size: 16, weight: .semibold))
                    .padding(.horizontal, 22).padding(.vertical, 10)
                    .background(SnugTheme.clay, in: Capsule())
                    .foregroundStyle(.white)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private func commit() {
        var updated = room
        // Anything left in the room (not cleared) is kept, so it feeds FitService
        // as an obstacle. Cleared pieces stay in the array (isCleared) but hidden.
        updated.detectedFurniture = footprints.map { footprint in
            var f = footprint
            if !f.isCleared { f.isKept = true }
            return f
        }
        onCommit(updated)
    }
}
