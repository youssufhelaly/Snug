import Testing
import UIKit
@testable import Snug

/// `UIImage.downscaled` keeps room thumbnails small without distorting them.
struct ImageDownscaleTests {

    private func image(width: CGFloat, height: CGFloat) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { context in
            UIColor.orange.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    @Test func shrinksTheLongestSideAndKeepsTheAspectRatio() {
        let result = image(width: 1290, height: 2796).downscaled(toMaxPixelDimension: 900)
        let pixels = CGSize(width: result.size.width * result.scale, height: result.size.height * result.scale)
        #expect(pixels.height == 900)
        #expect(abs(pixels.width - 415) <= 1)   // 1290 × 900 / 2796 ≈ 415
    }

    @Test func neverUpscalesASmallImage() {
        let small = image(width: 300, height: 200)
        let result = small.downscaled(toMaxPixelDimension: 900)
        #expect(result.size == small.size)
        #expect(result.scale == small.scale)
    }

    @Test func keepsTransparency() throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let clear = UIGraphicsImageRenderer(size: CGSize(width: 2000, height: 1000), format: format).image { _ in }
        let cg = try #require(clear.downscaled(toMaxPixelDimension: 500).cgImage)
        #expect(cg.alphaInfo != .none && cg.alphaInfo != .noneSkipLast && cg.alphaInfo != .noneSkipFirst)
    }
}
