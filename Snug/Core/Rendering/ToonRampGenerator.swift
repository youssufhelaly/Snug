import CoreGraphics
import Foundation

/// Generates a 4×1 px image encoding four discrete warm luminance steps
/// (shadow → midtone → highlight → specular), the RealityKit-safe stand-in for a
/// toon shader.
///
/// ## Why this isn't wired into the walls/floor
/// True toon shading needs to quantize the *lighting* response, which iOS 17
/// RealityKit will not let us do (the surface shader runs after the lighting
/// pass; there is no lighting hook). The documented approximation is to feed this
/// ramp as a base-color texture — but on a large flat wall a 4-pixel ramp sampled
/// across the UVs reads as visible banding stripes, not stepped lighting, so per
/// the Phase-3 prompt's own Step 2 the walls/floor/furniture use solid-color matte
/// PBM under warm light instead. This generator is provided as a ready utility for
/// a future furniture `CustomMaterial` surface shader (where a ramp lookup *can*
/// be sampled by surface luminance) and is intentionally not force-fit where it
/// would look wrong.
enum ToonRampGenerator {

    /// The four steps, left → right, as 8-bit RGB.
    static let steps: [(r: UInt8, g: UInt8, b: UInt8)] = [
        (102, 82, 72),    // shadow — warm dark brown
        (180, 150, 130),  // midtone
        (230, 210, 195),  // highlight
        (245, 237, 227),  // near-white specular
    ]

    /// A 4 px wide, 1 px tall opaque RGBA ramp. Built by writing pixels directly
    /// so the encoded values are exact (no rasterizer rounding). Returns `nil`
    /// only if the image provider can't be created.
    static func make() -> CGImage? {
        let width = steps.count
        let height = 1
        var bytes = [UInt8]()
        bytes.reserveCapacity(width * 4)
        for step in steps {
            bytes.append(contentsOf: [step.r, step.g, step.b, 255])
        }

        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }
}
