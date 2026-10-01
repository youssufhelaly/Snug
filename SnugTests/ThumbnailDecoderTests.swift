import Testing
import UIKit
@testable import Snug

/// `ThumbnailDecoder` decodes room thumbnails at tile size without distortion.
struct ThumbnailDecoderTests {

    private func imageData(width: CGFloat, height: CGFloat) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).pngData { context in
            UIColor.orange.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    @Test func downsamplesTheLongestSideAndKeepsTheAspectRatio() throws {
        let image = try #require(ThumbnailDecoder.downsample(imageData(width: 1290, height: 2796), maxPixelSize: 720))
        let pixels = CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
        #expect(pixels.height == 720)
        #expect(abs(pixels.width - 332) <= 1)   // 1290 × 720 / 2796 ≈ 332
    }

    @Test func returnsNilForUnreadableData() {
        #expect(ThumbnailDecoder.downsample(Data([0x00, 0x01, 0x02]), maxPixelSize: 720) == nil)
    }

    @Test func cachesDecodedImagesByKey() async throws {
        let key = "test-\(UUID().uuidString)"
        #expect(ThumbnailDecoder.cachedImage(forKey: key) == nil)
        let decoded = await ThumbnailDecoder.image(forKey: key, data: imageData(width: 400, height: 300))
        _ = try #require(decoded)
        #expect(ThumbnailDecoder.cachedImage(forKey: key) != nil)
    }
}
