import Testing
import CoreGraphics
@testable import Snug

/// Tests the pure CoreGraphics half of the renderer — the contact-shadow
/// texture generator — which needs no Metal device and so runs anywhere. The
/// RealityKit entity factories are validated on device per the task's manual
/// test script, since their look depends on lighting and culling that the
/// simulator doesn't reproduce.
struct RenderingTests {

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
