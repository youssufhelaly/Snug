import Testing
import CoreGraphics
@testable import Snug

/// Tests the pure CoreGraphics halves of the Phase-3 renderer — the texture
/// generators — which need no Metal device and so run anywhere. The RealityKit
/// entity factories (outlines, furniture) are validated on device per the task's
/// manual test script, since their look depends on lighting and culling that the
/// simulator doesn't reproduce.
struct RenderingTests {

    @Test func toonRampEncodesFourWarmStepsExactly() throws {
        let image = try #require(ToonRampGenerator.make())
        #expect(image.width == 4)
        #expect(image.height == 1)

        let pixels = try #require(Self.readRGBA(image))
        for (i, step) in ToonRampGenerator.steps.enumerated() {
            #expect(pixels[i * 4 + 0] == step.r)
            #expect(pixels[i * 4 + 1] == step.g)
            #expect(pixels[i * 4 + 2] == step.b)
            #expect(pixels[i * 4 + 3] == 255)
        }
    }

    @Test func contactShadowIsDarkAtCenterAndClearAtEdge() throws {
        let size = 64
        let image = try #require(ContactShadow.makeImage(size: size))
        #expect(image.width == size)
        #expect(image.height == size)

        let pixels = try #require(Self.readRGBA(image))
        func alpha(_ x: Int, _ y: Int) -> UInt8 { pixels[(y * size + x) * 4 + 3] }

        // The center is the most opaque; the corners sit beyond the gradient's
        // end radius, so they're fully clear.
        #expect(alpha(size / 2, size / 2) > alpha(0, 0))
        #expect(alpha(0, 0) < 20)
    }

    @Test func studioEnvironmentIsAFullyOpaqueWarmGradient() throws {
        let w = 32, h = 32
        let image = try #require(StudioEnvironment.makeImage(width: w, height: h))
        #expect(image.width == w)
        #expect(image.height == h)

        let pixels = try #require(Self.readRGBA(image))
        func luminance(_ x: Int, _ y: Int) -> Int {
            let i = (y * w + x) * 4
            return Int(pixels[i]) + Int(pixels[i + 1]) + Int(pixels[i + 2])
        }

        // A real vertical gradient exists (zenith light → floor bounce), not a
        // flat fill. Orientation-independent so it can't flake on CG's flip.
        let column = (0..<h).map { luminance(w / 2, $0) }
        #expect(column.max()! - column.min()! > 60)
        // The environment must be fully opaque — a transparent hole would punch a
        // black gap into the IBL and skybox.
        for y in 0..<h { #expect(pixels[(y * w + w / 2) * 4 + 3] == 255) }
    }

    /// Render a `CGImage` into a known RGBA buffer so we can read its pixels.
    private static func readRGBA(_ image: CGImage) -> [UInt8]? {
        let w = image.width, h = image.height
        var data = [UInt8](repeating: 0, count: w * h * 4)
        let ok = data.withUnsafeMutableBytes { buffer -> Bool in
            guard let base = buffer.baseAddress,
                  let ctx = CGContext(
                    data: base, width: w, height: h,
                    bitsPerComponent: 8, bytesPerRow: w * 4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  ) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return ok ? data : nil
    }
}
