import Foundation
import simd

/// The diorama's red/amber/green tint for a placed piece.
///
/// This is a coarser *view* of `FitService`'s four-state result, never a
/// separate rule set. An earlier version classified with its own fixed 8 cm /
/// 5 cm margins, so a piece's tint and its fit badge could disagree on the same
/// geometry, which is exactly the false precision the trust layer exists to
/// prevent. Deriving the tint from `FitResult.State` makes that impossible.
enum PlacementState: Equatable {
    /// "Fits" or "Fits with room to spare". (base color)
    case valid
    /// "Too close to call". (amber)
    case tooClose
    /// "Won't fit". (red)
    case invalid

    /// The tint for a fit result. Both confident states share the calm base
    /// color; uncertainty and failure each get their own signal.
    init(_ state: FitResult.State) {
        switch state {
        case .fitsWithRoom, .fits: self = .valid
        case .tooCloseToCall:      self = .tooClose
        case .wontFit:             self = .invalid
        }
    }
}

/// Classifies a furniture footprint for live placement feedback.
///
/// Pure and deterministic, so it can run on every drag tick. It delegates the
/// geometry entirely to `FitService` through `RoomModel.fitResult`, the same
/// call the fit badge makes, so the two can never drift apart.
enum FurniturePlacementValidator {

    /// Classify `footprint` against the room walls and the OTHER pieces in
    /// `existingFootprints`.
    ///
    /// `existingFootprints` is passed separately from `room.detectedFurniture`
    /// because during a drag the live positions differ from the persisted room.
    /// The footprint itself is excluded by id, so it is never its own obstacle,
    /// and cleared pieces never occupy floor.
    static func validate(
        footprint: FurnitureFootprint,
        against room: RoomModel,
        existingFootprints: [FurnitureFootprint]
    ) -> PlacementState {
        var live = room
        live.detectedFurniture = existingFootprints
        return PlacementState(live.fitResult(for: footprint, excluding: footprint.id).state)
    }
}
