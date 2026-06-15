import RealityKit
import CoreGraphics
import UIKit

/// Generates the warm "studio" environment that drives the PLAY diorama's soft
/// look: a single equirectangular gradient used as BOTH the image-based lighting
/// source (the soft global-illumination wrap that replaces a hard directional-only
/// rig) AND the visible skybox background gradient — exactly how the reference
/// render gets its unified warm glow and backdrop from one source.
///
/// ## iOS 26 capability note
/// The rest of `Core/Rendering` was written defensively against iOS 17, where
/// RealityKit exposed no image-based lighting hook. The app's real deployment
/// target is iOS 26, where `EnvironmentResource` can be built from a procedural
/// image. Since the `RealityView` migration the diorama consumes this resource via
/// an `ImageBasedLightComponent` (see `RoomSceneController.applyEnvironmentLighting`)
/// rather than the old `ARView.environment.lighting`. We generate the IBL at runtime
/// instead of shipping an HDR asset.
///
/// ## No graceful fallback (deliberate)
/// `makeResource()` does not invent a fallback if the runtime API differs from the
/// assumed `EnvironmentResource(equirectangular:)` initializer — a compile error
/// surfaces the correct signature, and the caller surfaces a runtime failure
/// loudly. The pure-CoreGraphics `makeImage()` half is unit-testable with no Metal
/// device, like the other generators here.
enum StudioEnvironment {

    enum StudioEnvironmentError: Error {
        /// The CoreGraphics gradient couldn't be rasterized (out of memory / bad context).
        case imageGenerationFailed
    }

    // MARK: - Image (pure CoreGraphics, testable)

    /// A warm vertical equirectangular gradient: bright warm light at the zenith
    /// (top), a peach "window glow" band through the horizon, and a terracotta
    /// floor-bounce at the nadir (bottom). Sampled as an environment map this reads
    /// as soft, warm, top-down room light with no harsh shadows.
    ///
    /// Default size is a modest 1024×512 — plenty for soft IBL and a blurred
    /// backdrop, cheap to build once at scene setup.
    static func makeImage(width: Int = 1024, height: Int = 512) -> CGImage? {
        let space = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        let zenith = UIColor(rgb: 0xFFF8EC)   // bright warm key light from above
        let horizon = UIColor(rgb: 0xFFE6C2)  // luminous peach window glow
        let nadir = UIColor(rgb: 0xC98A55)    // lifted terracotta floor bounce
        let colors = [zenith.cgColor, horizon.cgColor, nadir.cgColor] as CFArray
        guard let gradient = CGGradient(colorsSpace: space, colors: colors,
                                        locations: [0, 0.55, 1]) else { return nil }

        // CoreGraphics' origin is bottom-left, so the zenith (start) sits at the
        // top edge (y == height) and the nadir (end) at the bottom (y == 0).
        ctx.drawLinearGradient(
            gradient,
            start: CGPoint(x: 0, y: CGFloat(height)),
            end: CGPoint(x: 0, y: 0),
            options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
        )
        return ctx.makeImage()
    }

    // MARK: - RealityKit resource

    /// Build the `EnvironmentResource` for image-based lighting + skybox from the
    /// generated gradient. Async because environment processing is GPU work.
    ///
    /// NOTE: this commits to the assumed iOS 26 initializer
    /// `EnvironmentResource(equirectangular:)`. If the real signature differs the
    /// build fails here (by design) so the correct call can be substituted.
    ///
    /// `@MainActor` so the non-`Sendable` `EnvironmentResource` is produced and
    /// consumed in one actor context (no cross-actor transfer warning). The async
    /// initializer still yields, so the main thread isn't blocked during the work.
    @MainActor
    static func makeResource() async throws -> EnvironmentResource {
        guard let image = makeImage() else { throw StudioEnvironmentError.imageGenerationFailed }
        return try await EnvironmentResource(equirectangular: image)
    }
}
