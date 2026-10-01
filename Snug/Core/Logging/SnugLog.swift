import os

/// The app's structured loggers, one per area.
///
/// Use these instead of `print`: entries carry a level, show up in Console.app
/// filtered by category, and cost almost nothing when nobody is reading them.
/// Error descriptions are logged as public because they never contain user data.
enum SnugLog {
    static let subsystem = "com.helaly.Snug"

    /// SwiftData store setup and room persistence.
    static let persistence = Logger(subsystem: subsystem, category: "Persistence")
    /// The AR capture session and its camera recovery.
    static let capture = Logger(subsystem: subsystem, category: "Capture")
    /// The Vision/CoreML furniture detector.
    static let detection = Logger(subsystem: subsystem, category: "Detection")
    /// Offscreen rendering, thumbnails, and snapshots.
    static let rendering = Logger(subsystem: subsystem, category: "Rendering")
}
