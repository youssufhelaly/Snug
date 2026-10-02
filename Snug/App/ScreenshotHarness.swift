#if DEBUG
import Foundation

/// Launches the app straight into a given screen for UI review and App Store
/// screenshots, on a throwaway in-memory store seeded with the sample room.
///
///     xcrun simctl launch booted com.helaly.Snug -snugScreen room
///
/// Debug builds only; release builds never contain this.
enum ScreenshotHarness {
    enum Screen: String, CaseIterable {
        case onboarding     // first-run slides
        case emptyHome      // home with no rooms
        case home           // home with the sample room
        case room           // the sample room's 3D view
        case selected       // a piece selected, inspector card showing
        case catalog        // the "Add furniture" sheet
        case shop           // the "Shop this room" sheet
    }

    /// The requested screen, from the `-snugScreen` launch argument.
    static let screen: Screen? = UserDefaults.standard.string(forKey: "snugScreen").flatMap(Screen.init)

    static var isActive: Bool { screen != nil }

    /// `-snugHideChrome YES`: hide the room screen's controls, for clean renders
    /// (marketing images, the bundled sample-room hero).
    static let hidesChrome = UserDefaults.standard.bool(forKey: "snugHideChrome")

    /// Whether the home should create the sample room and open it.
    static var opensSampleRoom: Bool {
        guard let screen else { return false }
        return [.room, .selected, .catalog, .shop].contains(screen)
    }

    /// Whether the home should be seeded with the sample room.
    static var seedsSampleRoom: Bool {
        screen == .home || opensSampleRoom
    }
}
#endif
