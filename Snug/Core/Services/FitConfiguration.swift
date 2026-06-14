import Foundation

/// Global tuning for the fit system.
///
/// V1 uses ONE global error-margin constant (CLAUDE.md: per-room,
/// confidence-weighted margins are a V2 idea). The value is seeded from
/// Phase 0's measured AR corner-tapping accuracy — the mean absolute wall
/// error against tape-measure ground truth — so the four-state fit badge is
/// calibrated to how wrong the geometry can actually be.
///
/// It is a `var` on purpose: the debug harness and tests can override it, and
/// a future settings/remote-config layer can replace the seed without touching
/// `FitService`, which always reads the margin from its parameter.
enum FitConfiguration {
    /// The fit system's error margin, in meters.
    ///
    /// Phase 0 seed: 5 cm. This is the band within which we refuse to claim a
    /// confident yes/no and instead tell the user to grab a tape measure.
    static var errorMargin: Float = 0.05
}
