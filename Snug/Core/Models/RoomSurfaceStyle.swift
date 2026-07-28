import Foundation

/// The user's curated wall-color choice for a room. `RoomSurfaceStyle` stores it
/// per room so the diorama can show the apartment's real surfaces —
/// renters can't repaint, so representing the walls they actually have is a
/// trust feature, not decoration. The concrete color values live in
/// `Theme.swift` (the single source of truth for colors).
enum WallColorChoice: String, Codable, CaseIterable, Identifiable {
    case white
    case cream
    case greige
    case sage
    case dustyBlue
    case blush

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .white: "White"
        case .cream: "Cream"
        case .greige: "Greige"
        case .sage: "Sage"
        case .dustyBlue: "Dusty blue"
        case .blush: "Blush"
        }
    }
}

/// The user's curated floor-material choice. V1 is color-driven (no textures);
/// each choice reads as a common rental floor. Values live in `Theme.swift`.
enum FloorMaterialChoice: String, Codable, CaseIterable, Identifiable {
    case lightOak
    case warmOak
    case walnut
    case greyLaminate
    case beigeCarpet
    case concrete

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .lightOak: "Light oak"
        case .warmOak: "Warm oak"
        case .walnut: "Walnut"
        case .greyLaminate: "Grey laminate"
        case .beigeCarpet: "Beige carpet"
        case .concrete: "Concrete"
        }
    }
}

/// The diorama's backdrop ("void") color behind the room. Unlike walls and
/// floor this is FRAME, not room — it represents nothing real, so playful
/// choices are allowed here and "not set" honesty doesn't apply: `nil` simply
/// means the default brand terracotta. Values live in `Theme.swift`.
enum BackdropColorChoice: String, Codable, CaseIterable, Identifiable {
    case sage
    case dustyBlue
    case sand
    case lavender
    case blush
    case charcoal

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .sage: "Sage"
        case .dustyBlue: "Dusty blue"
        case .sand: "Sand"
        case .lavender: "Lavender"
        case .blush: "Blush"
        case .charcoal: "Charcoal"
        }
    }
}

/// A room's chosen surface colors. For wall/floor, `nil` means the user hasn't
/// told us — the room keeps its neutral greige default, because claiming a
/// color we don't know would be false precision. Once set, the choice renders
/// faithfully, never stylized. `backdrop` is the frame around the room:
/// `nil` there just means the default terracotta, not "unknown".
struct RoomSurfaceStyle: Codable, Equatable {
    var wall: WallColorChoice?
    var floor: FloorMaterialChoice?
    var backdrop: BackdropColorChoice?

    init(wall: WallColorChoice? = nil,
         floor: FloorMaterialChoice? = nil,
         backdrop: BackdropColorChoice? = nil) {
        self.wall = wall
        self.floor = floor
        self.backdrop = backdrop
    }

    /// No choices made — the neutral pre-feature default look.
    static let unset = RoomSurfaceStyle()
}
